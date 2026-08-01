import Foundation
import SwiftProtobuf
import XCTest
@testable import TiebaPure

final class ContentSubmissionRequestFactoryTests: XCTestCase {
    func testThreadReplyOmitsEveryFloorTargetAndCarriesImageTag() throws {
        let request = try TiebaContentSubmissionRequestFactory.addPost(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: Self.target(kind: .threadReply)),
            uploadedImages: [TiebaAppUploadedImage(
                picID: "fixture_pic_1",
                pixelWidth: 640,
                pixelHeight: 480
            )],
            bootstrap: Self.bootstrap,
            requestBuilder: Self.requestBuilder,
            now: Self.now
        )
        let data = request.data

        XCTAssertTrue(request.hasData)
        XCTAssertEqual(data.content, "正文\n#(pic,fixture_pic_1,640,480)")
        XCTAssertEqual(data.takephotoNum, "1")
        XCTAssertEqual(data.isPictxt, "1")
        XCTAssertTrue(data.hasBarrageTime)
        XCTAssertEqual(data.barrageTime, "0")
        XCTAssertTrue(data.hasPostFrom)
        XCTAssertEqual(data.postFrom, "3")
        XCTAssertFalse(data.hasQuoteID)
        XCTAssertFalse(data.hasRepostid)
        XCTAssertFalse(data.hasReplyUid)
        XCTAssertFalse(data.hasSubPostID)
        XCTAssertEqual(data.common.tbs, "fresh-tbs")
    }

    func testPostReplySetsParentAndReplyUserButOmitsSubpostTarget() throws {
        let request = try TiebaContentSubmissionRequestFactory.addPost(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: Self.target(
                kind: .postReply,
                parentPostID: 2002,
                replyUserID: 42
            )),
            uploadedImages: [],
            bootstrap: Self.bootstrap,
            requestBuilder: Self.requestBuilder,
            now: Self.now
        )
        let data = request.data

        XCTAssertTrue(data.hasQuoteID)
        XCTAssertEqual(data.quoteID, "2002")
        XCTAssertTrue(data.hasRepostid)
        XCTAssertEqual(data.repostid, "2002")
        XCTAssertTrue(data.hasReplyUid)
        XCTAssertEqual(data.replyUid, "42")
        XCTAssertTrue(data.hasPostFrom)
        XCTAssertEqual(data.postFrom, "0")
        XCTAssertFalse(data.hasSubPostID)
        XCTAssertFalse(data.hasBarrageTime)
    }

    func testSubpostReplyEncodesGoldenReplyTargetAndRoundTripsWireFields() throws {
        let request = try TiebaContentSubmissionRequestFactory.addPost(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: Self.target(
                kind: .subpostReply,
                parentPostID: 2002,
                subpostID: 3002,
                replyUserID: 43
            )),
            uploadedImages: [],
            bootstrap: Self.bootstrap,
            requestBuilder: Self.requestBuilder,
            now: Self.now
        )
        let data = request.data

        XCTAssertTrue(data.hasQuoteID)
        XCTAssertEqual(data.quoteID, "2002")
        XCTAssertTrue(data.hasRepostid)
        XCTAssertEqual(data.repostid, "2002")
        XCTAssertTrue(data.hasReplyUid)
        XCTAssertEqual(data.replyUid, "43")
        XCTAssertTrue(data.hasSubPostID)
        XCTAssertEqual(data.subPostID, "3002")
        XCTAssertFalse(data.hasPostFrom)
        XCTAssertFalse(data.hasBarrageTime)
        XCTAssertEqual(data.content, "回复 #(reply, tb.1.reply-target, 被回复用户) :正文")

        let decoded = try Tieba_AddPostRequest(serializedBytes: request.serializedData())
        XCTAssertEqual(decoded.data.content, data.content)
        XCTAssertEqual(decoded.data.replyUid, "43")
        XCTAssertEqual(decoded.data.subPostID, "3002")

        var prefix = Tieba_PbContent()
        prefix.type = 0
        prefix.text = "回复 "
        var replyTarget = Tieba_PbContent()
        replyTarget.type = 4
        replyTarget.uid = 43
        replyTarget.text = "被回复用户"
        var suffix = Tieba_PbContent()
        suffix.type = 0
        suffix.text = " :正文"
        XCTAssertEqual(
            PostMapper.subpostBlocks(from: [prefix, replyTarget, suffix], usersByID: [:]),
            [
                .text("回复 "),
                .mention(userID: 43, text: "被回复用户"),
                .text(" :正文")
            ]
        )
    }

    func testNewThreadCarriesExplicitPublishingFieldsAndPreservesTextExactly() throws {
        let protobuf = try TiebaContentSubmissionRequestFactory.addThread(
            account: Self.account,
            tbs: "fresh-tbs",
            request: ContentSubmissionRequest(
                target: Self.target(kind: .newThread),
                title: "  新主题\n副标题  ",
                body: "  新主题正文\n第二行  ",
                images: []
            ),
            bootstrap: Self.bootstrap,
            requestBuilder: Self.requestBuilder,
            now: Self.now
        )
        let data = protobuf.data

        XCTAssertTrue(protobuf.hasData)
        XCTAssertEqual(data.title, "  新主题\n副标题  ")
        XCTAssertEqual(data.content, "  新主题正文\n第二行  ")
        XCTAssertEqual(data.fid, "100")
        XCTAssertEqual(data.kw, "fixture")
        XCTAssertEqual(data.nameShow, "夹具账号")
        XCTAssertTrue(data.hasEntranceType)
        XCTAssertEqual(data.entranceType, "1")
        XCTAssertTrue(data.hasCallFrom)
        XCTAssertEqual(data.callFrom, "2")
        XCTAssertTrue(data.hasTakephotoNum)
        XCTAssertEqual(data.takephotoNum, "0")
        XCTAssertTrue(data.hasIsHide)
        XCTAssertTrue(data.hasIsRepostToDynamic)
        XCTAssertTrue(data.hasIsNtitle)
        XCTAssertTrue(data.hasIsLinkThread)
        XCTAssertTrue(data.hasIsForumBusinessAccount)
        XCTAssertTrue(data.hasIsPictxt)
        XCTAssertTrue(data.hasIsArticle)
        XCTAssertTrue(data.hasShowCustomFigure)
        XCTAssertTrue(data.hasIsQuestion)
        XCTAssertTrue(data.hasIsXiuxiuThread)
        XCTAssertTrue(data.hasIsShowBless)
        XCTAssertTrue(data.hasExt)
        XCTAssertEqual(data.ext, #"{"need_image":0,"is_hide":0,"need_follow_forum":0}"#)
        XCTAssertEqual(data.common.tbs, "fresh-tbs")
    }

    func testReplyBodyPreservesLeadingTrailingWhitespaceAndLineBreaks() throws {
        let body = "  第一行\n\n第二行  "
        let request = try TiebaContentSubmissionRequestFactory.addPost(
            account: Self.account,
            tbs: "fresh-tbs",
            request: ContentSubmissionRequest(
                target: Self.target(kind: .threadReply),
                title: "",
                body: body,
                images: []
            ),
            uploadedImages: [],
            bootstrap: Self.bootstrap,
            requestBuilder: Self.requestBuilder,
            now: Self.now
        )

        XCTAssertEqual(request.data.content, body)
    }

    func testLegacySubpostTargetWithoutPortraitKeepsReplyAttribution() throws {
        let legacyJSON = Data(#"""
        {
          "kind":"subpostReply",
          "forumID":100,
          "forumName":"fixture",
          "forumDisplayName":"夹具吧",
          "threadID":1001,
          "threadTitle":"夹具帖子",
          "parentPostID":2002,
          "parentFloor":2,
          "subpostID":3002,
          "replyUserID":43,
          "replyUserDisplayName":"被回复用户"
        }
        """#.utf8)
        let target = try JSONDecoder().decode(ContentSubmissionTarget.self, from: legacyJSON)
        XCTAssertNil(target.replyUserPortrait)

        let request = try TiebaContentSubmissionRequestFactory.addPost(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: target),
            uploadedImages: [],
            bootstrap: Self.bootstrap,
            requestBuilder: Self.requestBuilder,
            now: Self.now
        )

        XCTAssertEqual(request.data.replyUid, "43")
        XCTAssertEqual(request.data.content, "回复 #(reply, , 被回复用户) :正文")
    }

    func testUploadResponseRequiresExplicitSuccessCode() throws {
        let response = try decodeUpload(#"{"picId":"fixture_pic_1"}"#)
        XCTAssertThrowsError(try response.validatedPicID()) { error in
            XCTAssertEqual(
                error as? ContentSubmissionError,
                .business(code: -1, message: "图片上传响应缺少状态码。")
            )
        }
    }

    func testUploadResponseRejectsPicIDInjectionEvenWithSuccessCode() throws {
        for value in ["fixture|second", "fixture\r\nCookie: injected", "../fixture", "fixture pic"] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "picId": value
            ])
            let response = try JSONDecoder().decode(TiebaImageUploadResponseDTO.self, from: payload)
            XCTAssertThrowsError(try response.validatedPicID(), "Unexpectedly accepted \(value)") { error in
                XCTAssertEqual(
                    error as? ContentSubmissionError,
                    .business(code: -1, message: "贴吧没有返回有效的图片标识。")
                )
            }
        }
    }

    func testUploadResponseRejectsNonzeroCodeEvenWhenPicIDExists() throws {
        let response = try decodeUpload(
            #"{"error_code":7,"error_msg":"上传被拒绝","picId":"fixture_pic_1"}"#
        )
        XCTAssertThrowsError(try response.validatedPicID()) { error in
            XCTAssertEqual(
                error as? ContentSubmissionError,
                .business(code: 7, message: "上传被拒绝")
            )
        }
    }

    private static let account = Account(
        uid: "42",
        name: "fixture_account",
        displayName: "夹具账号",
        portrait: "fixture",
        bduss: "bduss",
        stoken: "stoken",
        baiduID: "baiduid",
        tbs: "tbs"
    )

    private static let requestBuilder = TiebaRequestBuilder(
        screenScale: 3,
        screenWidth: 1179,
        screenHeight: 2556,
        clientID: "request-builder-client"
    )

    private static let bootstrap = TiebaPostingBootstrapResult(
        identity: TiebaPostingIdentity(
            androidID: "0123456789abcdef",
            uuid: "00112233-4455-4677-8899-aabbccddeeff",
            cuidGalaxy2: "fixture-cuid-galaxy2",
            c3AID: "fixture-c3-aid"
        ),
        clientID: "fixture-client-id",
        sampleID: "fixture-sample-id",
        zID: "fixture-z-id"
    )

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func target(
        kind: ContentSubmissionKind,
        parentPostID: UInt64? = nil,
        subpostID: UInt64? = nil,
        replyUserID: Int64? = nil
    ) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: kind,
            forumID: 100,
            forumName: "fixture",
            forumDisplayName: "夹具吧",
            threadID: kind == .newThread ? nil : 1001,
            threadTitle: kind == .newThread ? nil : "夹具帖子",
            parentPostID: parentPostID,
            parentFloor: parentPostID == nil ? nil : 2,
            subpostID: subpostID,
            replyUserID: replyUserID,
            replyUserDisplayName: replyUserID == nil ? nil : "被回复用户",
            replyUserPortrait: replyUserID == nil ? nil : "tb.1.reply-target"
        )
    }

    private static func request(target: ContentSubmissionTarget) -> ContentSubmissionRequest {
        ContentSubmissionRequest(target: target, title: "", body: "正文", images: [])
    }

    private func decodeUpload(_ json: String) throws -> TiebaImageUploadResponseDTO {
        try JSONDecoder().decode(TiebaImageUploadResponseDTO.self, from: Data(json.utf8))
    }
}

#if DEBUG
final class FixtureContentSubmissionTests: XCTestCase {
    func testSuccessfulSubmissionsAreVisibleInSubsequentFixtureReads() async throws {
        let api = FixtureTiebaAPI()
        let account = FixtureTiebaAPI.account

        let newThread = ContentSubmissionRequest(
            target: .newThread(in: FixtureTiebaAPI.forum),
            title: "发布后可见的夹具主题",
            body: "新主题正文",
            images: []
        )
        let threadReceipt = try await api.submitContent(account: account, request: newThread)
        let forumThreads = try await api.forumThreads(
            account: account,
            forumName: FixtureTiebaAPI.forum.name,
            page: 1,
            category: .replyTime
        )
        let submittedThread = try XCTUnwrap(forumThreads.first(where: { $0.id == threadReceipt.threadID }))
        XCTAssertEqual(submittedThread.title, newThread.title)
        XCTAssertEqual(submittedThread.textPreview, newThread.body)
        let submittedThreadPage = try await api.threadPage(
            account: account,
            threadID: threadReceipt.threadID,
            page: 1,
            forumID: FixtureTiebaAPI.forum.id,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
        XCTAssertEqual(submittedThreadPage.mainPost?.author.id, Int64(account.uid))
        XCTAssertEqual(submittedThreadPage.mainPost?.contentPreview, newThread.body)

        let threadReply = ContentSubmissionRequest(
            target: Self.target(kind: .threadReply),
            title: "",
            body: "发布后可见的帖子回复",
            images: []
        )
        let postReceipt = try await api.submitContent(account: account, request: threadReply)
        let page = try await api.threadPage(
            account: account,
            threadID: 1001,
            page: 1,
            forumID: FixtureTiebaAPI.forum.id,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
        let submittedPost = try XCTUnwrap(page.posts.first(where: { $0.id == postReceipt.postID }))
        XCTAssertEqual(submittedPost.contentPreview, threadReply.body)

        let floorReply = ContentSubmissionRequest(
            target: Self.target(
                kind: .postReply,
                parentPostID: 2002,
                replyUserID: 1
            ),
            title: "",
            body: "发布后可见的楼层回复",
            images: []
        )
        let floorReplyReceipt = try await api.submitContent(account: account, request: floorReply)
        let pageAfterFloorReply = try await api.threadPage(
            account: account,
            threadID: 1001,
            page: 1,
            forumID: FixtureTiebaAPI.forum.id,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
        XCTAssertFalse(
            pageAfterFloorReply.posts.contains(where: { $0.id == floorReplyReceipt.postID }),
            "回复楼层必须进入楼中楼，不能伪装成新的帖子楼层"
        )
        let floorSubposts = try await api.subposts(
            account: account,
            threadID: 1001,
            postID: 2002,
            forumID: FixtureTiebaAPI.forum.id,
            page: 1,
            subpostID: floorReplyReceipt.postID ?? 0
        )
        let submittedFloorReply = try XCTUnwrap(
            floorSubposts.first(where: { $0.id == floorReplyReceipt.postID })
        )
        XCTAssertEqual(submittedFloorReply.blocks.compactMap(\.plainText).joined(), floorReply.body)

        let subpostReply = ContentSubmissionRequest(
            target: Self.target(
                kind: .subpostReply,
                parentPostID: 2002,
                subpostID: 3001,
                replyUserID: 1
            ),
            title: "",
            body: "发布后可见的楼中楼回复",
            images: []
        )
        let subpostReceipt = try await api.submitContent(account: account, request: subpostReply)
        let subposts = try await api.subposts(
            account: account,
            threadID: 1001,
            postID: 2002,
            forumID: FixtureTiebaAPI.forum.id,
            page: 1,
            subpostID: 0
        )
        let submittedSubpost = try XCTUnwrap(subposts.first(where: { $0.id == subpostReceipt.postID }))
        XCTAssertEqual(
            submittedSubpost.blocks,
            [
                .text("回复 "),
                .mention(userID: 1, text: "被回复用户"),
                .text("："),
                .text(subpostReply.body)
            ]
        )
    }

    func testFixtureBusinessFailureIsTypedAndDoesNotMutateState() async throws {
        let api = FixtureTiebaAPI(scenario: .submissionFailure)
        let request = Self.validThreadReply()

        await assertSubmissionError(
            from: api,
            request: request,
            equals: .business(code: 7, message: "操作频繁，请稍后再试。")
        )
        let page = try await api.threadPage(
            account: FixtureTiebaAPI.account,
            threadID: 1001,
            page: 1,
            forumID: FixtureTiebaAPI.forum.id,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
        XCTAssertFalse(page.posts.contains(where: { $0.contentPreview == request.body }))
    }

    func testFixtureVerificationFailureIsTyped() async {
        await assertSubmissionError(
            from: FixtureTiebaAPI(scenario: .submissionVerification),
            request: Self.validThreadReply(),
            equals: .verificationRequired(message: "贴吧要求完成安全验证。")
        )
    }

    func testFixtureUnknownOutcomeIsTyped() async {
        await assertSubmissionError(
            from: FixtureTiebaAPI(scenario: .submissionUnknown),
            request: Self.validThreadReply(),
            equals: .outcomeUnknown
        )
    }

    private func assertSubmissionError(
        from api: FixtureTiebaAPI,
        request: ContentSubmissionRequest,
        equals expected: ContentSubmissionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await api.submitContent(account: FixtureTiebaAPI.account, request: request)
            XCTFail("Expected submission to fail", file: file, line: line)
        } catch let error as ContentSubmissionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private static func validThreadReply() -> ContentSubmissionRequest {
        ContentSubmissionRequest(
            target: target(kind: .threadReply),
            title: "",
            body: "失败请求不能写入状态",
            images: []
        )
    }

    private static func target(
        kind: ContentSubmissionKind,
        parentPostID: UInt64? = nil,
        subpostID: UInt64? = nil,
        replyUserID: Int64? = nil
    ) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: kind,
            forumID: FixtureTiebaAPI.forum.id,
            forumName: FixtureTiebaAPI.forum.name,
            forumDisplayName: FixtureTiebaAPI.forum.displayName,
            threadID: 1001,
            threadTitle: "夹具帖子",
            parentPostID: parentPostID,
            parentFloor: parentPostID == nil ? nil : 2,
            subpostID: subpostID,
            replyUserID: replyUserID,
            replyUserDisplayName: replyUserID == nil ? nil : "被回复用户"
        )
    }
}
#endif

final class ContentSubmissionNetworkIntegrationTests: XCTestCase {
    func testProtobufSuccessReturnsReceipt() async throws {
        let response = try Self.addPostResponse(tid: "1001", pid: "9001")
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        let receipt = try await harness.api.submitContent(
            account: Self.account,
            request: Self.textReply
        )

        XCTAssertEqual(receipt, ContentSubmissionReceipt(threadID: 1001, postID: 9001))
        XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), [
            "/c/s/login",
            "/c/c/post/add"
        ])
    }

    func testNewThreadProtobufSuccessReturnsReceipt() async throws {
        let response = try Self.addThreadResponse(tid: "7001", pid: "7002")
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }
        let request = ContentSubmissionRequest(
            target: ContentSubmissionTarget(
                kind: .newThread,
                forumID: 100,
                forumName: "fixture",
                forumDisplayName: "夹具吧",
                threadID: nil,
                threadTitle: nil,
                parentPostID: nil,
                parentFloor: nil,
                subpostID: nil,
                replyUserID: nil,
                replyUserDisplayName: nil
            ),
            title: "新主题",
            body: "新主题正文",
            images: []
        )

        let receipt = try await harness.api.submitContent(account: Self.account, request: request)

        XCTAssertEqual(receipt, ContentSubmissionReceipt(threadID: 7001, postID: 7002))
        XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), [
            "/c/s/login",
            "/c/c/thread/add"
        ])
    }

    func testProtobufBusinessErrorIsTyped() async throws {
        let response = try Self.addPostResponse(errorCode: 7, userMessage: "操作频繁")
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        await assertSubmissionError(
            from: harness.api,
            request: Self.textReply,
            equals: .business(code: 7, message: "操作频繁")
        )
    }

    func testProtobufSessionErrorIsTyped() async throws {
        let response = try Self.addPostResponse(errorCode: 4, userMessage: "登录已失效")
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        await assertSubmissionError(
            from: harness.api,
            request: Self.textReply,
            equals: .sessionExpired
        )
    }

    func testProtobufVerificationResponseIsTyped() async throws {
        let response = try Self.addPostResponse(
            message: "请完成安全验证",
            needsVerification: true
        )
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        await assertSubmissionError(
            from: harness.api,
            request: Self.textReply,
            equals: .verificationRequired(message: "请完成安全验证")
        )
    }

    func testEmptyProtobufResponseHasUnknownOutcome() async throws {
        let response = try Tieba_AddPostResponse().serializedData()
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        await assertSubmissionError(
            from: harness.api,
            request: Self.textReply,
            equals: .outcomeUnknown
        )
    }

    func testExplicitZeroErrorWithoutDataIsMinimalSuccess() async throws {
        let response = try Self.addPostResponse()
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        let receipt = try await harness.api.submitContent(
            account: Self.account,
            request: Self.textReply
        )

        XCTAssertEqual(receipt, ContentSubmissionReceipt(threadID: 1001, postID: nil))
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 1)
    }

    func testUploadThenStrictTBSRefreshThenMutationUsesActualImageDimensions() async throws {
        let response = try Self.addPostResponse(tid: "1001", pid: "9001")
        let harness = makeAPI(mode: .finalResponse(response))
        defer { SubmissionURLProtocol.remove(id: harness.id) }
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let request = ContentSubmissionRequest(
            target: Self.target,
            title: "",
            body: "带图回复",
            images: [ContentSubmissionImage(
                data: imageData,
                pixelWidth: 999,
                pixelHeight: 777,
                mimeType: "application/octet-stream"
            )]
        )

        let receipt = try await harness.api.submitContent(account: Self.account, request: request)

        XCTAssertEqual(receipt, ContentSubmissionReceipt(threadID: 1001, postID: 9001))
        let records = SubmissionURLProtocol.records(id: harness.id)
        XCTAssertEqual(records.map(\.path), [
            "/c/s/uploadPicture",
            "/c/s/login",
            "/c/c/post/add"
        ])

        let upload = try XCTUnwrap(records.first)
        let uploadParts = try Self.multipartParts(from: upload)
        XCTAssertEqual(try Self.textPart(named: "width", in: uploadParts), "1")
        XCTAssertEqual(try Self.textPart(named: "height", in: uploadParts), "1")
        XCTAssertEqual(try XCTUnwrap(uploadParts.first(where: { $0.name == "chunk" })).body, imageData)

        let login = try XCTUnwrap(records.first(where: { $0.path == "/c/s/login" }))
        let loginFields = try Self.formFields(from: login)
        XCTAssertEqual(loginFields["bdusstoken"], "fixture-bduss|")
        XCTAssertEqual(loginFields["stoken"], "fixture-stoken")

        let mutation = try XCTUnwrap(records.first(where: { $0.path == "/c/c/post/add" }))
        let mutationParts = try Self.multipartParts(from: mutation)
        XCTAssertEqual(mutationParts.map(\.name), ["data"])
        let protobufData = try XCTUnwrap(mutationParts.first?.body)
        let protobuf = try Tieba_AddPostRequest(serializedBytes: protobufData)
        XCTAssertEqual(protobuf.data.common.tbs, "fresh-tbs")
        XCTAssertNotEqual(protobuf.data.common.tbs, Self.account.tbs)
        XCTAssertEqual(protobuf.data.content, "带图回复\n#(pic,fixture_pic_1,1,1)")
        XCTAssertEqual(protobuf.data.takephotoNum, "1")
        XCTAssertEqual(protobuf.data.isPictxt, "1")

        XCTAssertNil(mutation.header(named: "Cookie"))
        for record in records where record.path != "/c/s/login" {
            let cookie = record.header(named: "Cookie") ?? ""
            XCTAssertFalse(cookie.localizedCaseInsensitiveContains("BDUSS="))
            XCTAssertFalse(cookie.localizedCaseInsensitiveContains("STOKEN="))
            XCTAssertFalse(cookie.localizedCaseInsensitiveContains("BAIDUID="))
        }
        let loginCookie = login.header(named: "Cookie") ?? ""
        XCTAssertFalse(loginCookie.localizedCaseInsensitiveContains("BDUSS="))
        XCTAssertFalse(loginCookie.localizedCaseInsensitiveContains("STOKEN="))
    }

    func testMalformedFloorTargetsAreRejectedBeforeBootstrapOrNetwork() async throws {
        let response = try Self.addPostResponse(tid: "1001", pid: "9001")
        let bootstrap = CountingSubmissionPostingBootstrap(result: Self.bootstrap)
        let harness = makeAPI(mode: .finalResponse(response), postingBootstrap: bootstrap)
        defer { SubmissionURLProtocol.remove(id: harness.id) }
        let malformedTargets = [
            ContentSubmissionTarget(
                kind: .postReply,
                forumID: 100,
                forumName: "fixture",
                forumDisplayName: "夹具吧",
                threadID: 1001,
                threadTitle: "夹具主题",
                parentPostID: nil,
                parentFloor: 2,
                subpostID: nil,
                replyUserID: 42,
                replyUserDisplayName: "用户"
            ),
            ContentSubmissionTarget(
                kind: .subpostReply,
                forumID: 100,
                forumName: "fixture",
                forumDisplayName: "夹具吧",
                threadID: 1001,
                threadTitle: "夹具主题",
                parentPostID: 2002,
                parentFloor: 2,
                subpostID: nil,
                replyUserID: 42,
                replyUserDisplayName: "用户"
            )
        ]

        for target in malformedTargets {
            let request = ContentSubmissionRequest(
                target: target,
                title: "",
                body: "不应发出的回复",
                images: []
            )
            do {
                _ = try await harness.api.submitContent(account: Self.account, request: request)
                XCTFail("Expected malformed \(target.kind) target to be rejected")
            } catch let error as ContentSubmissionValidationError {
                XCTAssertEqual(error, .invalidThread)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        let bootstrapCalls = await bootstrap.callCount()
        XCTAssertEqual(bootstrapCalls, 0)
        XCTAssertTrue(SubmissionURLProtocol.records(id: harness.id).isEmpty)
    }

    func testBootstrapSessionErrorsAreTypedAndNeverUploadOrMutate() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let request = ContentSubmissionRequest(
            target: Self.target,
            title: "",
            body: "bootstrap 失败后不得继续",
            images: [ContentSubmissionImage(
                data: imageData,
                pixelWidth: 1,
                pixelHeight: 1,
                mimeType: "image/png"
            )]
        )
        let errors: [TiebaPostingBootstrapError] = [
            .invalidCredential,
            .server(code: 4, message: "登录失效"),
            .server(code: 110001, message: "登录失效"),
            .server(code: 110002, message: "登录失效"),
            .server(code: 110003, message: "登录失效"),
            .server(code: 110004, message: "登录失效")
        ]

        for error in errors {
            let harness = makeAPI(
                mode: .finalResponse(try Self.addPostResponse(tid: "1001", pid: "9001")),
                postingBootstrap: FailingSubmissionPostingBootstrap(error: error)
            )
            defer { SubmissionURLProtocol.remove(id: harness.id) }

            await assertSubmissionError(
                from: harness.api,
                request: request,
                equals: .sessionExpired
            )
            XCTAssertTrue(
                SubmissionURLProtocol.records(id: harness.id).isEmpty,
                "Bootstrap error \(error) must stop before upload, TBS refresh, and mutation"
            )
        }
    }

    func testUnrelatedBootstrapServerErrorRemainsRetryableAndNeverMutates() async throws {
        let error = TiebaPostingBootstrapError.server(code: 340006, message: "sync rejected")
        let harness = makeAPI(
            mode: .finalResponse(try Self.addPostResponse(tid: "1001", pid: "9001")),
            postingBootstrap: FailingSubmissionPostingBootstrap(error: error)
        )
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        do {
            _ = try await harness.api.submitContent(account: Self.account, request: Self.textReply)
            XCTFail("Expected bootstrap failure")
        } catch let actual as TiebaPostingBootstrapError {
            XCTAssertEqual(actual, error)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(SubmissionURLProtocol.records(id: harness.id).isEmpty)
    }

    func testStrictTBSRefreshFailureNeverSendsFinalMutation() async {
        let harness = makeAPI(mode: .tbsRefreshFailure)
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        do {
            _ = try await harness.api.submitContent(account: Self.account, request: Self.textReply)
            XCTFail("Expected strict TBS refresh to fail")
        } catch {
            XCTAssertNotEqual(error as? ContentSubmissionError, .outcomeUnknown)
        }

        XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), [
            "/c/s/login",
            "/mo/q/newmoindex"
        ])
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
    }

    func testFinalTransportFailureHasUnknownOutcomeAndIsNotRetried() async {
        let harness = makeAPI(mode: .finalTransportFailure)
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        await assertSubmissionError(
            from: harness.api,
            request: Self.textReply,
            equals: .outcomeUnknown
        )
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 1)
    }

    func testFinalDecodeFailureHasUnknownOutcomeAndIsNotRetried() async {
        let harness = makeAPI(mode: .finalDecodeFailure)
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        await assertSubmissionError(
            from: harness.api,
            request: Self.textReply,
            equals: .outcomeUnknown
        )
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 1)
    }

    func testCancellationAfterFinalDispatchHasUnknownOutcomeAndIsNotRetried() async throws {
        let harness = makeAPI(mode: .holdFinalRequestUntilCancellation)
        defer { SubmissionURLProtocol.remove(id: harness.id) }
        let submission = Task {
            try await harness.api.submitContent(account: Self.account, request: Self.textReply)
        }

        try await waitForRequest(path: "/c/c/post/add", id: harness.id)
        submission.cancel()

        do {
            _ = try await submission.value
            XCTFail("Expected cancellation after dispatch to have an unknown outcome")
        } catch let error as ContentSubmissionError {
            XCTAssertEqual(error, .outcomeUnknown)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 1)
    }

    private func makeAPI(mode: SubmissionStubMode) -> (api: TiebaAPI, id: String) {
        makeAPI(
            mode: mode,
            postingBootstrap: SubmissionPostingBootstrapStub(result: Self.bootstrap)
        )
    }

    private func makeAPI(
        mode: SubmissionStubMode,
        postingBootstrap: any TiebaPostingBootstrapping
    ) -> (api: TiebaAPI, id: String) {
        let id = UUID().uuidString
        SubmissionURLProtocol.register(mode: mode, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubmissionURLProtocol.self]
        configuration.httpAdditionalHeaders = [SubmissionURLProtocol.testIDHeader: id]
        let session = URLSession(configuration: configuration)
        return (
            TiebaAPI(
                client: TiebaHTTPClient(session: session),
                requestBuilder: Self.requestBuilder,
                postingBootstrap: postingBootstrap
            ),
            id
        )
    }

    private func waitForRequest(path: String, id: String) async throws {
        for _ in 0..<200 {
            if SubmissionURLProtocol.count(path: path, id: id) == 1 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(path)")
    }

    private func assertSubmissionError(
        from api: TiebaAPI,
        request: ContentSubmissionRequest,
        equals expected: ContentSubmissionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await api.submitContent(account: Self.account, request: request)
            XCTFail("Expected submission to fail", file: file, line: line)
        } catch let error as ContentSubmissionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private static func addPostResponse(
        errorCode: Int32 = 0,
        userMessage: String = "",
        tid: String? = nil,
        pid: String? = nil,
        message: String = "",
        needsVerification: Bool = false
    ) throws -> Data {
        var response = Tieba_AddPostResponse()
        var error = Tieba_Error()
        error.errorCode = errorCode
        error.userMsg = userMessage
        response.error = error
        if tid != nil || pid != nil || message.isEmpty == false || needsVerification {
            var data = Tieba_AddPostResponse.DataMessage()
            data.tid = tid ?? ""
            data.pid = pid ?? ""
            data.msg = message
            if needsVerification {
                var info = Tieba_SubmissionVerificationInfo()
                info.needVcode = "1"
                info.vcodeMd5 = "fixture-md5"
                info.vcodeType = "2"
                data.info = info
            }
            response.data = data
        }
        return try response.serializedData()
    }

    private static func addThreadResponse(tid: String, pid: String) throws -> Data {
        var response = Tieba_AddThreadResponse()
        response.error = Tieba_Error()
        var data = Tieba_AddThreadResponse.DataMessage()
        data.tid = tid
        data.pid = pid
        response.data = data
        return try response.serializedData()
    }

    private static func multipartParts(from request: SubmissionRecordedRequest) throws -> [MultipartPart] {
        let contentType = try XCTUnwrap(request.header(named: "Content-Type"))
        let boundaryPrefix = "boundary="
        let boundary = try XCTUnwrap(
            contentType.components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.hasPrefix(boundaryPrefix) }
                .map { String($0.dropFirst(boundaryPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        )
        let body = try XCTUnwrap(request.body)
        let delimiter = Data("--\(boundary)".utf8)
        let headerTerminator = Data("\r\n\r\n".utf8)
        let contentTerminator = Data("\r\n--\(boundary)".utf8)
        var parts: [MultipartPart] = []
        var searchStart = body.startIndex

        while let delimiterRange = body.range(
            of: delimiter,
            options: [],
            in: searchStart..<body.endIndex
        ) {
            let suffixStart = delimiterRange.upperBound
            guard suffixStart + 2 <= body.endIndex else { break }
            if body[suffixStart..<(suffixStart + 2)].elementsEqual(Data("--".utf8)) {
                break
            }
            guard body[suffixStart..<(suffixStart + 2)].elementsEqual(Data("\r\n".utf8)) else {
                throw MultipartTestError.malformed
            }
            let headerStart = suffixStart + 2
            guard let headerRange = body.range(
                of: headerTerminator,
                options: [],
                in: headerStart..<body.endIndex
            ) else {
                throw MultipartTestError.malformed
            }
            let contentStart = headerRange.upperBound
            guard let contentRange = body.range(
                of: contentTerminator,
                options: [],
                in: contentStart..<body.endIndex
            ) else {
                throw MultipartTestError.malformed
            }
            guard let headers = String(data: body[headerStart..<headerRange.lowerBound], encoding: .utf8),
                  let disposition = headers.components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-disposition:") }),
                  let name = Self.dispositionValue(named: "name", in: disposition) else {
                throw MultipartTestError.malformed
            }
            parts.append(MultipartPart(
                name: name,
                filename: Self.dispositionValue(named: "filename", in: disposition),
                body: Data(body[contentStart..<contentRange.lowerBound])
            ))
            searchStart = contentRange.lowerBound + 2
        }
        return parts
    }

    private static func dispositionValue(named key: String, in disposition: String) -> String? {
        let prefix = "\(key)=\""
        guard let startRange = disposition.range(of: prefix) else { return nil }
        let valueStart = startRange.upperBound
        guard let valueEnd = disposition[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(disposition[valueStart..<valueEnd])
    }

    private static func textPart(named name: String, in parts: [MultipartPart]) throws -> String {
        let part = try XCTUnwrap(parts.first(where: { $0.name == name }))
        return try XCTUnwrap(String(data: part.body, encoding: .utf8))
    }

    private static func formFields(from request: SubmissionRecordedRequest) throws -> [String: String] {
        let body = try XCTUnwrap(request.body)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static let account = Account(
        uid: "42",
        name: "fixture_account",
        displayName: "夹具账号",
        portrait: "fixture",
        bduss: "fixture-bduss",
        stoken: "fixture-stoken",
        baiduID: "fixture-baiduid",
        tbs: "stale-tbs"
    )

    private static let target = ContentSubmissionTarget(
        kind: .threadReply,
        forumID: 100,
        forumName: "fixture",
        forumDisplayName: "夹具吧",
        threadID: 1001,
        threadTitle: "夹具主题",
        parentPostID: nil,
        parentFloor: nil,
        subpostID: nil,
        replyUserID: nil,
        replyUserDisplayName: nil
    )

    private static let textReply = ContentSubmissionRequest(
        target: target,
        title: "",
        body: "离线提交测试",
        images: []
    )

    private static let requestBuilder = TiebaRequestBuilder(
        screenScale: 3,
        screenWidth: 1179,
        screenHeight: 2556,
        clientID: "submission-network-test"
    )

    private static let bootstrap = TiebaPostingBootstrapResult(
        identity: TiebaPostingIdentity(
            androidID: "0123456789abcdef",
            uuid: "00112233-4455-4677-8899-aabbccddeeff",
            cuidGalaxy2: "submission-network-test",
            c3AID: "fixture-c3-aid"
        ),
        clientID: "fixture-client-id",
        sampleID: "fixture-sample-id",
        zID: "fixture-z-id"
    )

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}

private struct SubmissionPostingBootstrapStub: TiebaPostingBootstrapping {
    let result: TiebaPostingBootstrapResult

    func bootstrap(bduss: String) async throws -> TiebaPostingBootstrapResult {
        result
    }
}

private struct FailingSubmissionPostingBootstrap: TiebaPostingBootstrapping {
    let error: TiebaPostingBootstrapError

    func bootstrap(bduss: String) async throws -> TiebaPostingBootstrapResult {
        throw error
    }
}

private actor CountingSubmissionPostingBootstrap: TiebaPostingBootstrapping {
    let result: TiebaPostingBootstrapResult
    private var calls = 0

    init(result: TiebaPostingBootstrapResult) {
        self.result = result
    }

    func bootstrap(bduss: String) async throws -> TiebaPostingBootstrapResult {
        calls += 1
        return result
    }

    func callCount() -> Int { calls }
}

private enum SubmissionStubMode: Sendable {
    case finalResponse(Data)
    case tbsRefreshFailure
    case finalTransportFailure
    case finalDecodeFailure
    case holdFinalRequestUntilCancellation
}

private struct SubmissionRecordedRequest: Sendable {
    let path: String
    let headers: [String: String]
    let body: Data?

    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private struct MultipartPart: Equatable {
    let name: String
    let filename: String?
    let body: Data
}

private enum MultipartTestError: Error {
    case malformed
}

private final class SubmissionURLProtocol: URLProtocol {
    static let testIDHeader = "X-TiebaPure-Submission-Test-ID"

    private struct Context {
        let mode: SubmissionStubMode
        var records: [SubmissionRecordedRequest]
    }

    private static let lock = NSLock()
    private static var contexts: [String: Context] = [:]

    static func register(mode: SubmissionStubMode, id: String) {
        lock.lock()
        contexts[id] = Context(mode: mode, records: [])
        lock.unlock()
    }

    static func remove(id: String) {
        lock.lock()
        contexts.removeValue(forKey: id)
        lock.unlock()
    }

    static func records(id: String) -> [SubmissionRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return contexts[id]?.records ?? []
    }

    static func paths(id: String) -> [String] {
        records(id: id).map(\.path)
    }

    static func count(path: String, id: String) -> Int {
        records(id: id).count { $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: testIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let id = request.value(forHTTPHeaderField: Self.testIDHeader),
              let mode = Self.record(request: request, id: id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch url.path {
        case "/c/s/uploadPicture":
            respond(
                statusCode: 200,
                payload: Data(#"{"error_code":0,"picId":"fixture_pic_1"}"#.utf8),
                contentType: "application/json"
            )

        case "/c/s/login":
            if case .tbsRefreshFailure = mode {
                respond(statusCode: 503, payload: Data("unavailable".utf8))
            } else {
                respond(
                    statusCode: 200,
                    payload: Data(#"{"error_code":"0","anti":{"tbs":"fresh-tbs"}}"#.utf8),
                    contentType: "application/json"
                )
            }

        case "/mo/q/newmoindex":
            respond(statusCode: 503, payload: Data("unavailable".utf8))

        case "/c/c/post/add", "/c/c/thread/add":
            switch mode {
            case let .finalResponse(payload):
                respond(statusCode: 200, payload: payload)
            case .finalTransportFailure:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .finalDecodeFailure:
                respond(statusCode: 200, payload: Data([0x0f]))
            case .holdFinalRequestUntilCancellation:
                break
            case .tbsRefreshFailure:
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            }

        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    private static func record(request: URLRequest, id: String) -> SubmissionStubMode? {
        let record = SubmissionRecordedRequest(
            path: request.url?.path ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: requestBody(request)
        )
        lock.lock()
        defer { lock.unlock() }
        guard var context = contexts[id] else { return nil }
        context.records.append(record)
        contexts[id] = context
        return context.mode
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func respond(
        statusCode: Int,
        payload: Data,
        contentType: String = "application/octet-stream"
    ) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": contentType,
                      "Content-Length": String(payload.count)
                  ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
