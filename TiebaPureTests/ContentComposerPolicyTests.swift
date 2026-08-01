import XCTest
@testable import TiebaPure

final class ContentComposerPolicyTests: XCTestCase {
    func testForumResolverUsesKnownIDAndRequiresForumName() {
        let known = Forum(
            id: 42,
            name: "fixture",
            displayName: "夹具吧",
            memberCount: 0,
            threadCount: 0
        )
        XCTAssertEqual(ContentSubmissionForumResolver.resolve(known, fallbackID: nil)?.id, 42)

        let idOnly = Forum(
            id: 0,
            name: "fixture",
            displayName: "夹具吧",
            memberCount: 0,
            threadCount: 0
        )
        XCTAssertEqual(ContentSubmissionForumResolver.resolve(idOnly, fallbackID: 84)?.id, 84)
        XCTAssertNil(ContentSubmissionForumResolver.resolve(idOnly, fallbackID: nil))

        let unnamed = Forum(
            id: 42,
            name: "  ",
            displayName: "夹具吧",
            memberCount: 0,
            threadCount: 0
        )
        XCTAssertNil(ContentSubmissionForumResolver.resolve(unnamed, fallbackID: 84))
    }

    func testTitleIsOnlyShownForNewThreads() {
        XCTAssertTrue(ContentComposerPolicy.showsTitle(for: .newThread))
        XCTAssertFalse(ContentComposerPolicy.showsTitle(for: .threadReply))
        XCTAssertFalse(ContentComposerPolicy.showsTitle(for: .postReply))
        XCTAssertFalse(ContentComposerPolicy.showsTitle(for: .subpostReply))
    }

    func testRemainingImageSlotsAreClampedToPolicyRange() {
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(currentCount: -1, kind: .threadReply),
            ContentSubmissionPolicy.maximumImages
        )
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(currentCount: 3, kind: .threadReply),
            ContentSubmissionPolicy.maximumImages - 3
        )
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(
                currentCount: ContentSubmissionPolicy.maximumImages + 1,
                kind: .threadReply
            ),
            0
        )
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(currentCount: 0, kind: .newThread),
            0
        )
    }

    func testEmoticonInsertionSeparatesTokenFromExistingText() {
        XCTAssertEqual(ContentComposerPolicy.appendingEmoticon("#(滑稽)", to: ""), "#(滑稽)")
        XCTAssertEqual(ContentComposerPolicy.appendingEmoticon("#(滑稽)", to: "正文"), "正文 #(滑稽)")
        XCTAssertEqual(ContentComposerPolicy.appendingEmoticon("#(滑稽)", to: "正文\n"), "正文\n#(滑稽)")
    }

    func testValidationMessageUsesSubmissionContract() {
        var request = ContentSubmissionRequest(
            target: makeTarget(kind: .newThread),
            title: "",
            body: "正文",
            images: []
        )

        XCTAssertEqual(ContentComposerPolicy.validationMessage(for: request), "请输入帖子标题。")

        request.title = "标题"
        XCTAssertNil(ContentComposerPolicy.validationMessage(for: request))

        request.body = ""
        XCTAssertEqual(ContentComposerPolicy.validationMessage(for: request), "请输入正文或添加图片。")
    }

    func testValidationRejectsNonImageMIMEType() {
        let request = ContentSubmissionRequest(
            target: makeTarget(kind: .threadReply),
            title: "",
            body: "正文",
            images: [ContentSubmissionImage(
                data: Data([0x01]),
                pixelWidth: 1,
                pixelHeight: 1,
                mimeType: "text/plain"
            )]
        )

        XCTAssertEqual(ContentComposerPolicy.validationMessage(for: request), "所选图片无法读取，请重新选择。")
    }

    func testValidationInspectsBytesInsteadOfTrustingClaimedMetadata() throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let metadata = try ContentSubmissionImageInspector.inspect(data)
        XCTAssertEqual(metadata.pixelWidth, 1)
        XCTAssertEqual(metadata.pixelHeight, 1)
        XCTAssertEqual(metadata.mimeType, "image/png")

        let reply = ContentSubmissionRequest(
            target: makeTarget(kind: .threadReply),
            title: "",
            body: "正文",
            images: [ContentSubmissionImage(
                data: data,
                pixelWidth: 99_999,
                pixelHeight: 99_999,
                mimeType: "image/jpeg"
            )]
        )
        XCTAssertNoThrow(try ContentSubmissionPolicy.validateForNetwork(reply))

        var corrupt = reply
        corrupt.images[0].data = Data([0xff, 0xd8, 0xff])
        XCTAssertThrowsError(try ContentSubmissionPolicy.validateForNetwork(corrupt)) { error in
            XCTAssertEqual(error as? ContentSubmissionValidationError, .invalidImage)
        }
    }

    func testNewThreadRejectsImagesBeforeAnyNetworkWrite() throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let request = ContentSubmissionRequest(
            target: makeTarget(kind: .newThread),
            title: "标题",
            body: "正文",
            images: [ContentSubmissionImage(
                data: data,
                pixelWidth: 1,
                pixelHeight: 1,
                mimeType: "image/png"
            )]
        )
        XCTAssertEqual(
            ContentComposerPolicy.validationMessage(for: request),
            "当前发布新主题仅支持文字和贴吧表情。"
        )
    }

    func testRiskAcknowledgementIsExplicitAndPersistent() throws {
        let suiteName = "dev.infinityf4p.tiebapure.composer-risk-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ContentSubmissionRiskPolicy.reset(defaults: defaults)
        XCTAssertFalse(ContentSubmissionRiskPolicy.hasAcknowledged(defaults: defaults))

        ContentSubmissionRiskPolicy.acknowledge(defaults: defaults)
        XCTAssertTrue(ContentSubmissionRiskPolicy.hasAcknowledged(defaults: defaults))

        ContentSubmissionRiskPolicy.reset(defaults: defaults)
        XCTAssertFalse(ContentSubmissionRiskPolicy.hasAcknowledged(defaults: defaults))
    }

    func testImageDimensionsFollowEXIFOrientation() {
        let upright = ContentSubmissionImageInspector.displayPixelDimensions(
            width: 4_032,
            height: 3_024,
            orientation: 1
        )
        XCTAssertEqual(upright.width, 4_032)
        XCTAssertEqual(upright.height, 3_024)

        let rotated = ContentSubmissionImageInspector.displayPixelDimensions(
            width: 4_032,
            height: 3_024,
            orientation: 6
        )
        XCTAssertEqual(rotated.width, 3_024)
        XCTAssertEqual(rotated.height, 4_032)

        XCTAssertEqual(
            ContentSubmissionImageInspector.displayPixelDimensions(
                width: 4_032,
                height: 3_024,
                orientation: 8
            ).height,
            4_032
        )
    }

    private func makeTarget(kind: ContentSubmissionKind) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: kind,
            forumID: 1,
            forumName: "fixture",
            forumDisplayName: "测试吧",
            threadID: kind == .newThread ? nil : 2,
            threadTitle: "测试帖子",
            parentPostID: nil,
            parentFloor: nil,
            subpostID: nil,
            replyUserID: nil,
            replyUserDisplayName: nil
        )
    }
}
