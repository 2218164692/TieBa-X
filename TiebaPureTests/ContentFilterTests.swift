import XCTest
@testable import TiebaPure

final class ContentFilterTests: XCTestCase {
    func testFilterDropsLiveThreadButKeepsVideoThread() {
        var live = Tieba_ThreadInfo()
        live.id = 1
        live.alaInfo = Tieba_AlaLiveInfo()

        var video = Tieba_ThreadInfo()
        video.id = 2
        var videoInfo = Tieba_VideoInfo()
        videoInfo.videoURL = "https://video.example/a.mp4"
        video.videoInfo = videoInfo

        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: live))
        XCTAssertTrue(TiebaContentFilter.shouldKeep(thread: video))
    }

    func testFilterDropsVoiceContent() {
        var voice = Tieba_PbContent()
        voice.type = 10
        voice.voiceMd5 = "voice"

        XCTAssertFalse(TiebaContentFilter.shouldKeep(content: voice))
    }

    func testFilterDropsAdAndFoldedPostsEvenWithValidFloors() {
        var ad = Tieba_Post()
        ad.advertisement = Tieba_Advertisement()
        ad.floor = 2

        var folded = Tieba_Post()
        folded.isFold = 1
        folded.floor = 3

        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: ad))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: folded))
    }

    func testFilterKeepsVoiceFloorsAndDropsAdOnlyOrEmptyFloors() {
        var voice = Tieba_PbContent()
        voice.type = 10
        voice.voiceMd5 = "voice"

        // Voice is real content: the floor stays (rendered as a placeholder)
        // even without subposts, so floor numbering never skips.
        var voiceOnly = Tieba_Post()
        voiceOnly.content = [voice]
        voiceOnly.floor = 5
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: voiceOnly))

        var adOnly = Tieba_Post()
        var ad = Tieba_PbContent()
        ad.type = 10
        adOnly.content = [ad]
        adOnly.floor = 5
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: adOnly))

        var adOnlyWithSubposts = adOnly
        adOnlyWithSubposts.subPostNumber = 3
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: adOnlyWithSubposts))

        var emptyContent = Tieba_Post()
        emptyContent.floor = 6
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: emptyContent))

        var emptyContentWithSubposts = emptyContent
        emptyContentWithSubposts.subPostList.subPostList = [Tieba_SubPostList()]
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: emptyContentWithSubposts))
    }
}
