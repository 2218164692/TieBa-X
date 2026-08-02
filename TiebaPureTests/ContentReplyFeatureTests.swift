import UIKit
import XCTest
@testable import TiebaPure

@MainActor
final class ContentReplyFeatureTests: XCTestCase {
    func testReplySettingDefaultsOffPersistsAndRemovesDefaultOverride() throws {
        let suiteName = "dev.infinityf4p.tiebapure.reply-settings-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "replies-enabled"

        let store = ContentSubmissionSettingsStore(defaults: defaults, key: key)
        XCTAssertFalse(store.repliesEnabled)
        XCTAssertNil(defaults.object(forKey: key))

        store.setRepliesEnabled(true)
        XCTAssertTrue(store.repliesEnabled)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
        XCTAssertTrue(ContentSubmissionSettingsStore(defaults: defaults, key: key).repliesEnabled)

        store.setRepliesEnabled(false)
        XCTAssertFalse(store.repliesEnabled)
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testNewThreadAndLikeSettingsDefaultOnPersistDisabledOverridesAndReset() throws {
        let suiteName = "dev.infinityf4p.tiebapure.content-action-settings-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let newThreadsKey = "new-threads-enabled"
        let likesKey = "likes-enabled"

        var store = ContentSubmissionSettingsStore(
            defaults: defaults,
            key: "replies-enabled",
            newThreadsKey: newThreadsKey,
            likesKey: likesKey
        )
        XCTAssertTrue(store.newThreadsEnabled)
        XCTAssertTrue(store.likesEnabled)
        XCTAssertNil(defaults.object(forKey: newThreadsKey))
        XCTAssertNil(defaults.object(forKey: likesKey))

        store.setNewThreadsEnabled(false)
        store.setLikesEnabled(false)
        XCTAssertFalse(store.newThreadsEnabled)
        XCTAssertFalse(store.likesEnabled)
        XCTAssertEqual(defaults.object(forKey: newThreadsKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: likesKey) as? Bool, false)

        store = ContentSubmissionSettingsStore(
            defaults: defaults,
            key: "replies-enabled",
            newThreadsKey: newThreadsKey,
            likesKey: likesKey
        )
        XCTAssertFalse(store.newThreadsEnabled)
        XCTAssertFalse(store.likesEnabled)

        store.setNewThreadsEnabled(true)
        store.setLikesEnabled(true)
        XCTAssertTrue(store.newThreadsEnabled)
        XCTAssertTrue(store.likesEnabled)
        XCTAssertNil(defaults.object(forKey: newThreadsKey))
        XCTAssertNil(defaults.object(forKey: likesKey))

        store.setNewThreadsEnabled(false)
        store.setLikesEnabled(false)
        store.reset()
        XCTAssertTrue(store.newThreadsEnabled)
        XCTAssertTrue(store.likesEnabled)
        XCTAssertNil(defaults.object(forKey: newThreadsKey))
        XCTAssertNil(defaults.object(forKey: likesKey))
    }

    func testReplySettingAllowsNewThreadsButGatesEveryReplyKind() throws {
        let defaults = try scratchDefaults()
        let store = ContentSubmissionSettingsStore(defaults: defaults, key: "replies-enabled")

        XCTAssertTrue(store.allowsSubmission(kind: .newThread))
        XCTAssertFalse(store.allowsSubmission(kind: .threadReply))
        XCTAssertFalse(store.allowsSubmission(kind: .postReply))
        XCTAssertFalse(store.allowsSubmission(kind: .subpostReply))

        store.setNewThreadsEnabled(false)
        XCTAssertFalse(store.allowsSubmission(kind: .newThread))
        store.setNewThreadsEnabled(true)

        store.setRepliesEnabled(true)
        for kind in ContentSubmissionKind.allCases {
            XCTAssertTrue(store.allowsSubmission(kind: kind))
        }
    }

    func testCoordinatorRejectsRepliesBeforeNetworkAndObservesLiveSetting() async throws {
        let defaults = try scratchDefaults()
        let store = ContentSubmissionSettingsStore(defaults: defaults, key: "replies-enabled")
        let api = FixtureTiebaAPI(scenario: .submissionFailure)
        let coordinator = ContentSubmissionCoordinator(
            api: api,
            allowsSubmission: { store.allowsSubmission(kind: $0) }
        )

        for request in replyRequests() {
            do {
                _ = try await coordinator.submit(account: FixtureTiebaAPI.account, request: request)
                XCTFail("关闭开关时不应发送 \(request.target.kind.rawValue)")
            } catch {
                XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .repliesDisabled)
            }
        }

        store.setRepliesEnabled(true)
        do {
            _ = try await coordinator.submit(
                account: FixtureTiebaAPI.account,
                request: try XCTUnwrap(replyRequests().first)
            )
            XCTFail("开启后应到达故意失败的 Fixture 网络层")
        } catch {
            XCTAssertEqual(
                error as? ContentSubmissionError,
                .business(code: 7, message: "操作频繁，请稍后再试。")
            )
        }
    }

    func testCoordinatorNeverBlocksNewThreadWhenRepliesAreDisabled() async throws {
        let defaults = try scratchDefaults()
        let store = ContentSubmissionSettingsStore(defaults: defaults, key: "replies-enabled")
        let coordinator = ContentSubmissionCoordinator(
            api: FixtureTiebaAPI(scenario: .submissionFailure),
            allowsSubmission: { store.allowsSubmission(kind: $0) }
        )
        let request = ContentSubmissionRequest(
            target: .newThread(in: FixtureTiebaAPI.forum),
            title: "新主题不受回帖开关影响",
            body: "用于证明请求已经到达 Fixture 网络层。",
            images: []
        )

        do {
            _ = try await coordinator.submit(account: FixtureTiebaAPI.account, request: request)
            XCTFail("Fixture 应返回预设业务错误")
        } catch {
            XCTAssertEqual(
                error as? ContentSubmissionError,
                .business(code: 7, message: "操作频繁，请稍后再试。")
            )
        }
    }

    func testCoordinatorRejectsNewThreadBeforeNetworkWhenPostingIsDisabled() async throws {
        let defaults = try scratchDefaults()
        let store = ContentSubmissionSettingsStore(defaults: defaults, key: "replies-enabled")
        store.setNewThreadsEnabled(false)
        let coordinator = ContentSubmissionCoordinator(
            api: FixtureTiebaAPI(scenario: .submissionFailure),
            allowsSubmission: { store.allowsSubmission(kind: $0) }
        )
        let request = ContentSubmissionRequest(
            target: .newThread(in: FixtureTiebaAPI.forum),
            title: "关闭发帖开关",
            body: "协调器必须在进入 Fixture 网络层前拒绝。",
            images: []
        )

        do {
            _ = try await coordinator.submit(account: FixtureTiebaAPI.account, request: request)
            XCTFail("关闭发帖开关后不应提交请求")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .newThreadsDisabled)
        }
    }

    func testInlineTextTapTargetDistinguishesPlainGlyphLinkAndWhitespace() {
        let textView = InlineContentTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 260, height: 120)
        let text = NSMutableAttributedString(
            string: "普通文字  用户链接",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )
        text.addAttribute(
            .link,
            value: URL(string: "https://tieba.baidu.com/home/main?id=1")!,
            range: (text.string as NSString).range(of: "用户链接")
        )
        textView.apply(
            attributedText: text,
            maximumNumberOfLines: 0,
            lineBreakMode: .byWordWrapping
        )
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.tapTarget(at: point(forCharacter: 1, in: textView)), .plainText)
        let linkIndex = (text.string as NSString).range(of: "用户链接").location
        XCTAssertEqual(textView.tapTarget(at: point(forCharacter: linkIndex, in: textView)), .link)
        XCTAssertEqual(
            textView.tapTarget(at: CGPoint(x: textView.bounds.maxX - 2, y: textView.bounds.maxY - 2)),
            .outsideText
        )
    }

    private func replyRequests() -> [ContentSubmissionRequest] {
        let thread = FixtureTiebaAPI.threads[0]
        let post = Post(
            id: 2_002,
            threadID: thread.id,
            floor: 2,
            author: FixtureTiebaAPI.author,
            blocks: [.text("楼层正文")],
            subpostCount: 1,
            likeCount: 0,
            previewSubposts: []
        )
        let subpost = Subpost(
            id: 3_051,
            floor: 1,
            author: FixtureTiebaAPI.replyTarget,
            blocks: [.text("楼中楼正文")],
            likeCount: 0
        )
        return [
            ContentSubmissionRequest(
                target: .threadReply(thread: thread, forum: FixtureTiebaAPI.forum),
                title: "",
                body: "普通回帖",
                images: []
            ),
            ContentSubmissionRequest(
                target: .postReply(thread: thread, forum: FixtureTiebaAPI.forum, post: post),
                title: "",
                body: "回复楼层",
                images: []
            ),
            ContentSubmissionRequest(
                target: .subpostReply(
                    thread: thread,
                    forum: FixtureTiebaAPI.forum,
                    parentPost: post,
                    subpost: subpost
                ),
                title: "",
                body: "回复楼中楼",
                images: []
            )
        ]
    }

    private func point(
        forCharacter characterIndex: Int,
        in textView: InlineContentTextView
    ) -> CGPoint {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let glyphIndex = textView.layoutManager.glyphIndexForCharacter(at: characterIndex)
        let rect = textView.layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textView.textContainer
        )
        return CGPoint(
            x: rect.midX + textView.textContainerInset.left - textView.contentOffset.x,
            y: rect.midY + textView.textContainerInset.top - textView.contentOffset.y
        )
    }

    private func scratchDefaults() throws -> UserDefaults {
        let suiteName = "dev.infinityf4p.tiebapure.reply-feature-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
