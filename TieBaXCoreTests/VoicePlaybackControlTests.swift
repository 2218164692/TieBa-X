import XCTest
@testable import TieBaX

final class VoicePlaybackControlTests: XCTestCase {
    func testIdlePresentationUsesFixtureDurationAndRequiresExplicitTap() {
        let presentation = VoicePlaybackControlPolicy.presentation(
            state: .idle,
            fallbackDurationMilliseconds: 3_500
        )

        XCTAssertEqual(presentation.title, "语音")
        XCTAssertEqual(presentation.detail, "0:04")
        XCTAssertEqual(presentation.accessibilityLabel, "播放语音")
        XCTAssertEqual(presentation.accessibilityValue, "时长4秒")
        XCTAssertEqual(presentation.action, .toggle)
        XCTAssertNil(presentation.progress)
    }

    func testLoadingPresentationExposesBoundedPercentageAndDisablesDuplicateTap() {
        let presentation = VoicePlaybackControlPolicy.presentation(
            state: .loading(key: String(repeating: "a", count: 32), progress: 1.4),
            fallbackDurationMilliseconds: 800
        )

        XCTAssertEqual(presentation.title, "加载中 100%")
        XCTAssertEqual(presentation.accessibilityLabel, "正在加载语音")
        XCTAssertEqual(presentation.accessibilityValue, "已加载100%")
        XCTAssertEqual(presentation.progress, 1)
        XCTAssertEqual(presentation.action, .none)
    }

    func testPlayingAndPausedPresentationUseLoadedDurationAndProgress() {
        let key = String(repeating: "a", count: 32)
        let playing = VoicePlaybackControlPolicy.presentation(
            state: .playback(key: key, phase: .playing, currentTime: 2.5, duration: 10),
            fallbackDurationMilliseconds: 800
        )
        let paused = VoicePlaybackControlPolicy.presentation(
            state: .playback(key: key, phase: .paused, currentTime: 2.5, duration: 10),
            fallbackDurationMilliseconds: 800
        )

        XCTAssertEqual(playing.accessibilityLabel, "暂停语音")
        XCTAssertEqual(playing.progress, 0.25)
        XCTAssertEqual(playing.detail, "0:03 / 0:10")
        XCTAssertEqual(paused.accessibilityLabel, "继续播放语音")
        XCTAssertEqual(paused.progress, 0.25)
        XCTAssertEqual(paused.action, .toggle)
    }

    func testFailurePresentationOffersRetryAndKeepsReadableError() {
        let presentation = VoicePlaybackControlPolicy.presentation(
            state: .failed(
                key: String(repeating: "b", count: 32),
                message: "无法解析语音内容"
            ),
            fallbackDurationMilliseconds: 2_500
        )

        XCTAssertEqual(presentation.title, "加载失败，点击重试")
        XCTAssertEqual(presentation.accessibilityLabel, "重新加载语音")
        XCTAssertEqual(presentation.accessibilityValue, "无法解析语音内容")
        XCTAssertEqual(presentation.action, .retry)
        XCTAssertTrue(presentation.isFailure)
    }

    func testVoiceFixtureSeparatesSummaryAndDetailBlocks() async throws {
        let api = FixtureTiebaAPI(scenario: .voicePlayback)
        let summaries = try await api.personalizedThreads(account: nil, page: 1, loadType: 1)
        let summary = try XCTUnwrap(summaries.first)

        XCTAssertEqual(summary.title, "语音播放确定性夹具")
        XCTAssertTrue(summary.textPreview.hasPrefix("[语音]"))
        XCTAssertTrue(summary.blocks.contains(.voice(FixtureTiebaAPI.playableVoice)))

        let page = try await api.threadPage(
            account: nil,
            threadID: summary.id,
            page: 1,
            forumID: summary.forumID,
            postID: nil,
            seeLz: false,
            sortType: .hot
        )
        let mainPost = try XCTUnwrap(page.mainPost)
        XCTAssertTrue(mainPost.blocks.contains(.voice(FixtureTiebaAPI.playableVoice)))
        XCTAssertTrue(page.posts.dropFirst().contains { post in
            post.blocks.contains(.voice(FixtureTiebaAPI.failingVoice))
        })
    }

    func testClockAndPercentageFormattingAreStable() {
        XCTAssertEqual(VoicePlaybackControlPolicy.clockText(0), "0:00")
        XCTAssertEqual(VoicePlaybackControlPolicy.clockText(61.1), "1:02")
        XCTAssertEqual(VoicePlaybackControlPolicy.percentageText(-1), "0%")
        XCTAssertEqual(VoicePlaybackControlPolicy.percentageText(0.504), "50%")
        XCTAssertEqual(VoicePlaybackControlPolicy.percentageText(3), "100%")
    }
}
