import Foundation
import XCTest
@testable import TiebaPure

final class ContentSubmissionRequestFactoryTests: XCTestCase {
    func testThreadReplyWebFieldsOmitEveryFloorTargetAndPreserveImageInfo() throws {
        let fields = try TiebaContentSubmissionRequestFactory.webReplyFields(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: Self.target(kind: .threadReply)),
            uploadedImageInfo: "fixture-image-info",
            timestamp: Self.timestamp
        )

        XCTAssertEqual(fields, [
            "co": "正文",
            "_t": "1700000000000",
            "tag": "11",
            "upload_img_info": "fixture-image-info",
            "fid": "100",
            "src": "1",
            "word": "fixture",
            "tbs": "fresh-tbs",
            "z": "1001",
            "lp": "6026",
            "nick_name": "夹具账号",
            "_BSK": "1700000000000"
        ])
    }

    func testPostReplyWebFieldsSetParentAndFloorButOmitSubpostTarget() throws {
        let fields = try TiebaContentSubmissionRequestFactory.webReplyFields(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: Self.target(
                kind: .postReply,
                parentPostID: 2002,
                replyUserID: 42
            )),
            uploadedImageInfo: "",
            timestamp: Self.timestamp
        )

        XCTAssertEqual(fields["pid"], "2002")
        XCTAssertEqual(fields["floor"], "2")
        XCTAssertNil(fields["lzl_id"])
        XCTAssertEqual(fields["co"], "正文")
    }

    func testSubpostReplyWebFieldsCarryGoldenTargetAndPlainReplyPrefix() throws {
        let fields = try TiebaContentSubmissionRequestFactory.webReplyFields(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: Self.target(
                kind: .subpostReply,
                parentPostID: 2002,
                subpostID: 3002,
                replyUserID: 43
            )),
            uploadedImageInfo: "",
            timestamp: Self.timestamp
        )

        XCTAssertEqual(fields["pid"], "2002")
        XCTAssertEqual(fields["floor"], "2")
        XCTAssertEqual(fields["lzl_id"], "3002")
        XCTAssertEqual(fields["co"], "回复 被回复用户 : 正文")
    }

    func testWebReplyFieldsRejectHeaderInjectingUploadedImageInfo() {
        XCTAssertThrowsError(try TiebaContentSubmissionRequestFactory.webReplyFields(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: Self.target(kind: .threadReply)),
            uploadedImageInfo: "fixture\r\nCookie: injected",
            timestamp: Self.timestamp
        )) { error in
            XCTAssertEqual(error as? ContentSubmissionValidationError, .invalidImage)
        }
    }

    func testWebThreadFieldsAndHeadersPreserveTextAndMinimizeCookies() throws {
        let fields = try TiebaContentSubmissionRequestFactory.webThreadFields(
            account: Self.account,
            tbs: "fresh-tbs",
            request: ContentSubmissionRequest(
                target: Self.target(kind: .newThread),
                title: "  新主题\n副标题  ",
                body: "  新主题正文\n第二行  ",
                images: []
            ),
            now: Self.now
        )
        XCTAssertEqual(fields, [
            "ie": "utf-8",
            "fid": "100",
            "kw": "fixture",
            "tbs": "fresh-tbs",
            "title": "  新主题\n副标题  ",
            "content": "  新主题正文\n第二行  ",
            "nick_name": "夹具账号",
            "bsk": "1700000000000"
        ])

        let headers = try TiebaContentSubmissionRequestFactory.webThreadHeaders(
            account: Self.account,
            forumName: "fixture"
        )
        XCTAssertEqual(headers["Cookie"], "BDUSS=bduss; STOKEN=stoken")
        XCTAssertFalse(headers["Cookie", default: ""].contains("BAIDUID"))
        XCTAssertEqual(headers["Origin"], "https://tieba.baidu.com")
        XCTAssertEqual(headers["Referer"], "https://tieba.baidu.com/f?kw=fixture")

        let replyHeaders = try TiebaContentSubmissionRequestFactory.webReplyHeaders(
            account: Self.account,
            threadID: 1001
        )
        let uploadHeaders = try TiebaContentSubmissionRequestFactory.webUploadHeaders(
            account: Self.account,
            threadID: 1001
        )
        for candidate in [replyHeaders, uploadHeaders] {
            XCTAssertEqual(candidate["Cookie"], headers["Cookie"])
            XCTAssertEqual(candidate["User-Agent"], headers["User-Agent"])
            XCTAssertEqual(candidate["Accept"], headers["Accept"])
            XCTAssertEqual(candidate["Accept-Language"], headers["Accept-Language"])
        }
        XCTAssertEqual(uploadHeaders["Referer"], replyHeaders["Referer"])
    }

    func testReplyBodyPreservesLeadingTrailingWhitespaceAndLineBreaks() throws {
        let body = "  第一行\n\n第二行  "
        let fields = try TiebaContentSubmissionRequestFactory.webReplyFields(
            account: Self.account,
            tbs: "fresh-tbs",
            request: ContentSubmissionRequest(
                target: Self.target(kind: .threadReply),
                title: "",
                body: body,
                images: []
            ),
            uploadedImageInfo: "",
            timestamp: Self.timestamp
        )

        XCTAssertEqual(fields["co"], body)
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

        let fields = try TiebaContentSubmissionRequestFactory.webReplyFields(
            account: Self.account,
            tbs: "fresh-tbs",
            request: Self.request(target: target),
            uploadedImageInfo: "",
            timestamp: Self.timestamp
        )

        XCTAssertEqual(fields["lzl_id"], "3002")
        XCTAssertEqual(fields["co"], "回复 被回复用户 : 正文")
    }

    func testWebUploadResponseAcceptsSnakeAndCamelImageInfo() throws {
        let snake = try decodeWebUpload(
            #"{"error_code":0,"image_info":"fixture-image-info"}"#
        )
        let camel = try decodeWebUpload(
            #"{"err_code":"0","imageInfo":"fixture-image-info-2"}"#
        )
        XCTAssertEqual(try snake.validatedImageInfo(), "fixture-image-info")
        XCTAssertEqual(try camel.validatedImageInfo(), "fixture-image-info-2")
    }

    func testWebUploadResponseRejectsEmptyOrHeaderInjectingImageInfo() throws {
        for value in ["", "fixture\r\nCookie: injected"] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "image_info": value
            ])
            let response = try JSONDecoder().decode(TiebaWebUploadPictureResponseDTO.self, from: payload)
            XCTAssertThrowsError(try response.validatedImageInfo(), "Unexpectedly accepted \(value)") { error in
                XCTAssertEqual(
                    error as? ContentSubmissionError,
                    .business(code: -1, message: "贴吧没有返回有效的图片信息。")
                )
            }
        }
    }

    func testWebUploadResponseRejectsNonzeroAndConflictingCodes() throws {
        let rejected = try decodeWebUpload(
            #"{"error_code":7,"error_msg":"上传被拒绝","image_info":"fixture"}"#
        )
        XCTAssertThrowsError(try rejected.validatedImageInfo()) { error in
            XCTAssertEqual(
                error as? ContentSubmissionError,
                .business(code: 7, message: "上传被拒绝")
            )
        }

        let session = try decodeWebUpload(
            #"{"error_code":110001,"error_msg":"用户未登录","image_info":"fixture"}"#
        )
        XCTAssertThrowsError(try session.validatedImageInfo()) { error in
            XCTAssertEqual(error as? ContentSubmissionError, .sessionExpired)
        }

        let conflict = try decodeWebUpload(
            #"{"error_code":0,"err_code":7,"error_msg":"状态冲突","image_info":"fixture"}"#
        )
        XCTAssertThrowsError(try conflict.validatedImageInfo()) { error in
            XCTAssertEqual(
                error as? ContentSubmissionError,
                .business(code: -1, message: "图片上传响应状态无效。")
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

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let timestamp: Int64 = 1_700_000_000_000

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

    private func decodeWebUpload(_ json: String) throws -> TiebaWebUploadPictureResponseDTO {
        try JSONDecoder().decode(TiebaWebUploadPictureResponseDTO.self, from: Data(json.utf8))
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
    func testStrictPostingTBSRefreshUsesSignedClientLoginInsteadOfWebEndpoint() async throws {
        for payload in [
            #"{"error_code":"0","anti":{"tbs":" fresh-tbs "}}"#,
            #"{"error_code":0,"anti":{"tbs":"fresh-tbs"}}"#
        ] {
            let harness = makeAPI(mode: .tbsResponse(Data(payload.utf8)))
            defer { SubmissionURLProtocol.remove(id: harness.id) }

            let tbs = try await harness.api.strictlyRefreshedPostingTBS(for: Self.account)

            XCTAssertEqual(tbs, "fresh-tbs")
            let records = SubmissionURLProtocol.records(id: harness.id)
            XCTAssertEqual(records.count, 1)
            let request = try XCTUnwrap(records.first)
            XCTAssertEqual(request.path, "/c/s/login")
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.scheme, "https")
            XCTAssertEqual(request.host, "tiebac.baidu.com")
            XCTAssertNil(request.query)
            XCTAssertNil(request.header(named: "Cookie"))
            XCTAssertNil(request.header(named: "Origin"))
            XCTAssertNil(request.header(named: "X-Requested-With"))
            XCTAssertEqual(request.header(named: "User-Agent"), "tieba/22.5.1.0 skin/default")

            let fields = try Self.formFields(from: request)
            XCTAssertEqual(fields["_client_version"], "22.5.1.0")
            XCTAssertEqual(fields["bdusstoken"], "fixture-bduss")
            XCTAssertFalse(fields["sign", default: ""].isEmpty)
            XCTAssertEqual(Set(fields.keys), Set(["_client_version", "bdusstoken", "sign"]))
        }
    }

    func testStrictPostingTBSRefreshRejectsExpiredSessionEvenWithNonemptyTBS() async {
        for code in ["110001", "110004"] {
            let payload = Data(
                #"{"error_code":"\#(code)","error_msg":"用户未登录","anti":{"tbs":"anonymous-tbs"}}"#.utf8
            )
            let harness = makeAPI(mode: .tbsResponse(payload))
            defer { SubmissionURLProtocol.remove(id: harness.id) }

            do {
                _ = try await harness.api.strictlyRefreshedPostingTBS(for: Self.account)
                XCTFail("Expected expired-session TBS response to be rejected")
            } catch let error as ContentSubmissionError {
                XCTAssertEqual(error, .sessionExpired)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), ["/c/s/login"])
        }
    }

    func testStrictPostingTBSRefreshRejectsMissingTBSBeforeMutation() async {
        let harness = makeAPI(mode: .tbsResponse(Data(#"{"error_code":"0","anti":{"tbs":""}}"#.utf8)))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        do {
            _ = try await harness.api.submitContent(account: Self.account, request: Self.textReply)
            XCTFail("Expected empty TBS to stop submission")
        } catch let error as TiebaMutationError {
            XCTAssertEqual(error, .missingTBS)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), ["/c/s/login"])
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 0)
    }

    func testAllReplyTargetsUseExactWebFormAndNeverBootstrapOrFallback() async throws {
        let cases: [(ContentSubmissionKind, Set<String>, String)] = [
            (
                .threadReply,
                Set(["co", "_t", "tag", "upload_img_info", "fid", "src", "word", "tbs", "z", "lp", "nick_name", "_BSK"]),
                "离线提交测试"
            ),
            (
                .postReply,
                Set(["co", "_t", "tag", "upload_img_info", "fid", "src", "word", "tbs", "z", "lp", "nick_name", "_BSK", "pid", "floor"]),
                "离线提交测试"
            ),
            (
                .subpostReply,
                Set(["co", "_t", "tag", "upload_img_info", "fid", "src", "word", "tbs", "z", "lp", "nick_name", "_BSK", "pid", "floor", "lzl_id"]),
                "回复 被回复用户 : 离线提交测试"
            )
        ]

        for (kind, expectedKeys, expectedBody) in cases {
            let response = Data(#"{"no":0,"error":"","data":{"pid":9001,"tid":1001}}"#.utf8)
            let bootstrap = CountingSubmissionPostingBootstrap(result: Self.bootstrap)
            let harness = makeAPI(mode: .finalResponse(response), postingBootstrap: bootstrap)
            let request = Self.replyRequest(kind: kind)
            do {
                let receipt = try await harness.api.submitContent(
                    account: Self.account,
                    request: request
                )
                XCTAssertEqual(receipt, ContentSubmissionReceipt(threadID: 1001, postID: 9001))
                XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), [
                    "/c/s/login",
                    "/mo/q/apubpost"
                ])
                let bootstrapCalls = await bootstrap.callCount()
                XCTAssertEqual(bootstrapCalls, 0)

                let records = SubmissionURLProtocol.records(id: harness.id)
                let loginRequest = try XCTUnwrap(records.first)
                let mutation = try XCTUnwrap(records.last)
                XCTAssertEqual(loginRequest.host, "tiebac.baidu.com")
                XCTAssertEqual(loginRequest.method, "POST")
                XCTAssertEqual(loginRequest.header(named: "User-Agent"), "tieba/22.5.1.0 skin/default")
                XCTAssertNil(loginRequest.header(named: "Cookie"))
                let loginFields = try Self.formFields(from: loginRequest)
                XCTAssertEqual(loginFields["_client_version"], "22.5.1.0")
                XCTAssertEqual(loginFields["bdusstoken"], "fixture-bduss")
                XCTAssertFalse(loginFields["sign", default: ""].isEmpty)
                XCTAssertEqual(mutation.scheme, "https")
                XCTAssertEqual(mutation.host, "tieba.baidu.com")
                XCTAssertEqual(mutation.method, "POST")
                XCTAssertEqual(
                    mutation.header(named: "Cookie"),
                    "BDUSS=fixture-bduss; STOKEN=fixture-stoken"
                )
                XCTAssertFalse(mutation.header(named: "Cookie")?.contains("BAIDUID") ?? true)
                XCTAssertEqual(mutation.header(named: "Origin"), "https://tieba.baidu.com")
                XCTAssertEqual(
                    mutation.header(named: "Referer"),
                    "https://tieba.baidu.com/p/1001?lp=5028&mo_device=1&is_jingpost=0&pn=1&"
                )
                XCTAssertEqual(mutation.header(named: "X-Requested-With"), "XMLHttpRequest")
                XCTAssertEqual(mutation.header(named: "Accept"), "application/json, text/plain, */*")
                XCTAssertTrue(mutation.header(named: "User-Agent")?.contains("iPhone OS 18_0") == true)

                let fields = try Self.formFields(from: mutation)
                XCTAssertEqual(Set(fields.keys), expectedKeys)
                XCTAssertEqual(fields["co"], expectedBody)
                XCTAssertEqual(fields["tag"], "11")
                XCTAssertEqual(fields["upload_img_info"], "")
                XCTAssertEqual(fields["fid"], "100")
                XCTAssertEqual(fields["src"], "1")
                XCTAssertEqual(fields["word"], "fixture")
                XCTAssertEqual(fields["tbs"], "fresh-tbs")
                XCTAssertEqual(fields["z"], "1001")
                XCTAssertEqual(fields["lp"], "6026")
                XCTAssertEqual(fields["nick_name"], "夹具账号")

                let queryFields = Self.queryFields(from: mutation)
                let timestamp = try XCTUnwrap(queryFields["_t"])
                XCTAssertEqual(Set(queryFields.keys), ["_t"])
                XCTAssertEqual(fields["_t"], timestamp)
                XCTAssertEqual(fields["_BSK"], timestamp)
                XCTAssertNotNil(Int64(timestamp))

                switch kind {
                case .threadReply:
                    XCTAssertNil(fields["pid"])
                    XCTAssertNil(fields["floor"])
                    XCTAssertNil(fields["lzl_id"])
                case .postReply:
                    XCTAssertEqual(fields["pid"], "2002")
                    XCTAssertEqual(fields["floor"], "2")
                    XCTAssertNil(fields["lzl_id"])
                case .subpostReply:
                    XCTAssertEqual(fields["pid"], "2002")
                    XCTAssertEqual(fields["floor"], "2")
                    XCTAssertEqual(fields["lzl_id"], "3002")
                case .newThread:
                    XCTFail("Unexpected new-thread case")
                }

                XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
                XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
                XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/s/uploadPicture", id: harness.id), 0)
            } catch {
                SubmissionURLProtocol.remove(id: harness.id)
                throw error
            }
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testNewThreadUsesSingleHTTPSWebFormWithMinimalCookies() async throws {
        let response = Data(#"{"result":"1","tid":"7001","pid":"7002"}"#.utf8)
        let bootstrap = CountingSubmissionPostingBootstrap(result: Self.bootstrap)
        let harness = makeAPI(mode: .finalResponse(response), postingBootstrap: bootstrap)
        defer { SubmissionURLProtocol.remove(id: harness.id) }
        let request = Self.newThreadRequest(
            title: "  新主题\n副标题  ",
            body: "  新主题正文\n第二行  "
        )
        let earliestBSK = Int64(Date().timeIntervalSince1970 * 1_000)

        let receipt = try await harness.api.submitContent(account: Self.account, request: request)
        let latestBSK = Int64(Date().timeIntervalSince1970 * 1_000)

        XCTAssertEqual(receipt, ContentSubmissionReceipt(threadID: 7001, postID: 7002))
        XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), [
            "/c/s/login",
            "/f/commit/thread/add"
        ])
        let bootstrapCalls = await bootstrap.callCount()
        XCTAssertEqual(bootstrapCalls, 0)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id), 1)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id), 0)

        let records = SubmissionURLProtocol.records(id: harness.id)
        let loginRequest = try XCTUnwrap(records.first)
        let mutation = try XCTUnwrap(records.last)
        XCTAssertEqual(loginRequest.host, "tiebac.baidu.com")
        XCTAssertEqual(loginRequest.method, "POST")
        XCTAssertNil(loginRequest.header(named: "Cookie"))
        let loginFields = try Self.formFields(from: loginRequest)
        XCTAssertEqual(loginFields["_client_version"], "22.5.1.0")
        XCTAssertEqual(loginFields["bdusstoken"], "fixture-bduss")
        XCTAssertFalse(loginFields["sign", default: ""].isEmpty)
        XCTAssertEqual(mutation.scheme, "https")
        XCTAssertEqual(mutation.host, "tieba.baidu.com")
        XCTAssertEqual(mutation.method, "POST")
        XCTAssertNil(mutation.query)
        XCTAssertEqual(
            mutation.header(named: "Cookie"),
            "BDUSS=fixture-bduss; STOKEN=fixture-stoken"
        )
        XCTAssertFalse(mutation.header(named: "Cookie")?.contains("BAIDUID") ?? true)
        XCTAssertTrue(mutation.header(named: "User-Agent")?.contains("iPhone OS 18_0") == true)
        XCTAssertTrue(
            mutation.header(named: "Content-Type")?
                .hasPrefix("application/x-www-form-urlencoded") == true
        )
        let fields = try Self.formFields(from: mutation)
        XCTAssertEqual(Set(fields.keys), Set([
            "ie", "fid", "kw", "tbs", "title", "content", "nick_name", "bsk"
        ]))
        XCTAssertEqual(fields["ie"], "utf-8")
        XCTAssertEqual(fields["fid"], "100")
        XCTAssertEqual(fields["kw"], "fixture")
        XCTAssertEqual(fields["tbs"], "fresh-tbs")
        XCTAssertEqual(fields["title"], request.title)
        XCTAssertEqual(fields["content"], request.body)
        XCTAssertEqual(fields["nick_name"], "夹具账号")
        let bskString = try XCTUnwrap(fields["bsk"])
        let bsk = try XCTUnwrap(Int64(bskString))
        XCTAssertGreaterThanOrEqual(bsk, earliestBSK)
        XCTAssertLessThanOrEqual(bsk, latestBSK)
    }

    func testWebThreadSuccessStatusAndIdentifierShapes() async throws {
        let cases: [(String, ContentSubmissionReceipt)] = [
            (
                #"{"result":1,"tid":7001,"pid":7002}"#,
                ContentSubmissionReceipt(threadID: 7001, postID: 7002)
            ),
            (
                #"{"error_code":"0","data":{"tid":"7003","pid":"7004"}}"#,
                ContentSubmissionReceipt(threadID: 7003, postID: 7004)
            ),
            (
                #"{"err_code":0,"tid":"7005","data":{"pid":7006}}"#,
                ContentSubmissionReceipt(threadID: 7005, postID: 7006)
            ),
            (
                #"{"result":1,"tid":"7007","pid":"7008","data":{"tid":7007,"pid":7008}}"#,
                ContentSubmissionReceipt(threadID: 7007, postID: 7008)
            )
        ]

        for (payload, expected) in cases {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            do {
                let receipt = try await harness.api.submitContent(
                    account: Self.account,
                    request: Self.newThreadRequest()
                )
                XCTAssertEqual(receipt, expected)
                XCTAssertEqual(
                    SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id),
                    1
                )
                XCTAssertEqual(
                    SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id),
                    0
                )
            } catch {
                SubmissionURLProtocol.remove(id: harness.id)
                throw error
            }
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebThreadConflictingTopLevelAndNestedIdentifiersHaveUnknownOutcome() async {
        let payloads = [
            #"{"result":1,"tid":7001,"data":{"tid":7002,"pid":7003}}"#,
            #"{"result":1,"tid":7001,"pid":7002,"data":{"pid":7003}}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.newThreadRequest(),
                equals: .outcomeUnknown
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id),
                1
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id),
                0
            )
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebThreadMalformedTopLevelOrNestedIdentifiersHaveUnknownOutcome() async {
        let payloads = [
            #"{"result":1,"tid":{"value":7001},"data":{"tid":7001}}"#,
            #"{"result":1,"tid":7001,"pid":true}"#,
            #"{"result":1,"tid":7001.0}"#,
            #"{"result":1,"tid":7001,"data":{"pid":"not-a-post-id"}}"#,
            #"{"result":1,"tid":7001,"data":{"tid":""}}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.newThreadRequest(),
                equals: .outcomeUnknown
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id),
                1
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id),
                0
            )
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebThreadExplicitErrorsRemainTyped() async throws {
        let cases: [(String, ContentSubmissionError)] = [
            (
                #"{"error_code":"7","error_msg":"操作频繁"}"#,
                .business(code: 7, message: "操作频繁")
            ),
            (
                #"{"err_code":110001,"err_msg":"用户未登录"}"#,
                .sessionExpired
            ),
            (
                #"{"result":0,"err_code":40,"err_msg":"请完成安全验证","data":{"vcode_md5":"fixture-md5"}}"#,
                .verificationRequired(ContentSubmissionChallenge(
                    message: "请完成安全验证",
                    verificationMD5: SubmissionSecret("fixture-md5")
                ))
            )
        ]

        for (payload, expected) in cases {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.newThreadRequest(),
                equals: expected
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id),
                1
            )
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebThreadStructuredChallengeIsTypedWithoutRetryingFinalWrite() async throws {
        let payload = #"""
        {
          "result": 0,
          "err_code": 40,
          "err_msg": "请完成安全验证",
          "data": {
            "info": {
              "need_vcode": 1,
              "vcode_md5": "fixture-md5",
              "vcode_type": "slide",
              "pass_token": "fixture-pass-token",
              "vcode_pic_url": "https://tieba.baidu.com/challenge.png",
              "anti_stat": {"vcode_stat":1,"days_tofree":3}
            },
            "ext_msg": "验证后可继续"
          }
        }
        """#
        let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        do {
            _ = try await harness.api.submitContent(
                account: Self.account,
                request: Self.newThreadRequest()
            )
            XCTFail("Expected structured verification challenge")
        } catch let ContentSubmissionError.verificationRequired(challenge) {
            XCTAssertEqual(challenge.message, "请完成安全验证")
            XCTAssertEqual(challenge.verificationMD5?.value, "fixture-md5")
            XCTAssertEqual(challenge.verificationType, "slide")
            XCTAssertEqual(challenge.passToken?.value, "fixture-pass-token")
            XCTAssertEqual(challenge.pictureURL?.host, "tieba.baidu.com")
            XCTAssertEqual(challenge.antiState?.verificationState, "1")
            XCTAssertEqual(challenge.antiState?.daysToFree, 3)
            XCTAssertEqual(challenge.extensionMessage, "验证后可继续")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id), 1)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id), 0)
    }

    func testWebThreadAmbiguousResponsesHaveUnknownOutcomeWithoutFallbackOrRetry() async {
        let payloads = [
            #"{"result":1,"pid":7002}"#,
            #"{"result":1,"error_code":7,"tid":7001}"#,
            #"{"tid":7001}"#,
            #"{"error_code":{"value":0},"tid":7001}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.newThreadRequest(),
                equals: .outcomeUnknown
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id),
                1
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id),
                0
            )
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebThreadMalformedTopLevelOrNestedStatusFieldsHaveUnknownOutcome() async {
        let payloads = [
            #"{"result":true,"tid":7001}"#,
            #"{"error_code":false,"tid":7001}"#,
            #"{"result":1.0,"tid":7001}"#,
            #"{"error_code":{"value":0},"tid":7001}"#,
            #"{"err_code":null,"tid":7001}"#,
            #"{"result":1,"tid":7001,"data":{"result":true}}"#,
            #"{"result":1,"tid":7001,"data":{"error_code":false}}"#,
            #"{"result":1,"tid":7001,"data":{"result":1.0}}"#,
            #"{"result":1,"tid":7001,"data":{"err_code":{"value":0}}}"#,
            #"{"result":1,"tid":7001,"data":{"error_code":null}}"#,
            #"{"result":1,"tid":7001,"data":true}"#,
            #"{"result":1,"tid":7001,"data":[]}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.newThreadRequest(),
                equals: .outcomeUnknown,
                context: payload
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id),
                1
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id),
                0
            )
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebThreadTransportAndDecodeFailuresHaveUnknownOutcomeWithoutRetry() async {
        for mode in [SubmissionStubMode.finalTransportFailure, .finalDecodeFailure] {
            let harness = makeAPI(mode: mode)
            await assertSubmissionError(
                from: harness.api,
                request: Self.newThreadRequest(),
                equals: .outcomeUnknown
            )
            XCTAssertEqual(
                SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id),
                1
            )
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebThreadCancellationAfterDispatchHasUnknownOutcomeWithoutRetry() async throws {
        let harness = makeAPI(mode: .holdFinalRequestUntilCancellation)
        defer { SubmissionURLProtocol.remove(id: harness.id) }
        let submission = Task {
            try await harness.api.submitContent(
                account: Self.account,
                request: Self.newThreadRequest()
            )
        }

        try await waitForRequest(path: "/f/commit/thread/add", id: harness.id)
        submission.cancel()

        do {
            _ = try await submission.value
            XCTFail("Expected cancellation after dispatch to have an unknown outcome")
        } catch let error as ContentSubmissionError {
            XCTAssertEqual(error, .outcomeUnknown)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/f/commit/thread/add", id: harness.id), 1)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/thread/add", id: harness.id), 0)
    }

    func testWebReplyBusinessSessionVerificationAndAmbiguousResponsesStayTyped() async {
        let cases: [(String, ContentSubmissionError)] = [
            (
                #"{"no":7,"error":"操作频繁"}"#,
                .business(code: 7, message: "操作频繁")
            ),
            (
                #"{"errno":110001,"error":"用户未登录"}"#,
                .sessionExpired
            ),
            (
                #"{"error_code":40,"error_msg":"请完成安全验证"}"#,
                .verificationRequired(message: "请完成安全验证")
            ),
            (
                #"{"no":0,"error_code":7,"error":"状态冲突"}"#,
                .outcomeUnknown
            ),
            (
                #"{"result":1,"no":7,"error":"状态冲突"}"#,
                .outcomeUnknown
            ),
            (
                #"{"data":{"tid":1001,"pid":9001}}"#,
                .outcomeUnknown
            ),
            (
                #"{"no":{"value":0},"data":{"tid":1001,"pid":9001}}"#,
                .outcomeUnknown
            ),
            (
                #"{"no":0,"data":{"tid":9999,"pid":9001}}"#,
                .outcomeUnknown
            ),
            (
                #"{"no":0,"pid":9001,"data":{"tid":1001,"pid":9002}}"#,
                .outcomeUnknown
            )
        ]

        for (payload, expected) in cases {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.textReply,
                equals: expected
            )
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebReplyStructuredChallengeAndSessionPriorityStayTyped() async throws {
        let challengePayload = #"""
        {
          "error_code": 40,
          "error_msg": "请完成安全验证",
          "data": {
            "info": {
              "need_vcode": true,
              "vcode_md5": "fixture-reply-md5",
              "pass_token": "fixture-reply-token"
            }
          }
        }
        """#
        let harness = makeAPI(mode: .finalResponse(Data(challengePayload.utf8)))
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        do {
            _ = try await harness.api.submitContent(account: Self.account, request: Self.textReply)
            XCTFail("Expected structured reply challenge")
        } catch let ContentSubmissionError.verificationRequired(challenge) {
            XCTAssertEqual(challenge.verificationMD5?.value, "fixture-reply-md5")
            XCTAssertEqual(challenge.passToken?.value, "fixture-reply-token")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)

        let sessionPayload = #"""
        {"error_code":110001,"error_msg":"用户未登录","need_vcode":1,"vcode_md5":"ignored"}
        """#
        let sessionHarness = makeAPI(mode: .finalResponse(Data(sessionPayload.utf8)))
        defer { SubmissionURLProtocol.remove(id: sessionHarness.id) }
        await assertSubmissionError(
            from: sessionHarness.api,
            request: Self.textReply,
            equals: .sessionExpired
        )
    }

    func testWebReplyMalformedTopLevelOrNestedStatusFieldsHaveUnknownOutcome() async {
        let payloads = [
            #"{"result":true,"tid":1001,"pid":9001}"#,
            #"{"no":false,"tid":1001,"pid":9001}"#,
            #"{"error_code":0.0,"tid":1001,"pid":9001}"#,
            #"{"err_code":{"value":0},"tid":1001,"pid":9001}"#,
            #"{"errno":null,"tid":1001,"pid":9001}"#,
            #"{"no":0,"tid":1001,"pid":9001,"data":{"result":true}}"#,
            #"{"no":0,"tid":1001,"pid":9001,"data":{"no":false}}"#,
            #"{"no":0,"tid":1001,"pid":9001,"data":{"error_code":0.0}}"#,
            #"{"no":0,"tid":1001,"pid":9001,"data":{"err_code":{"value":0}}}"#,
            #"{"no":0,"tid":1001,"pid":9001,"data":{"errno":null}}"#,
            #"{"no":0,"tid":1001,"pid":9001,"data":true}"#,
            #"{"no":0,"tid":1001,"pid":9001,"data":[]}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.textReply,
                equals: .outcomeUnknown,
                context: payload
            )
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebReplyMalformedTopLevelOrNestedIdentifiersHaveUnknownOutcome() async {
        let payloads = [
            #"{"no":0,"tid":true,"data":{"tid":1001,"pid":9001}}"#,
            #"{"no":0,"tid":{"value":1001},"data":{"tid":1001,"pid":9001}}"#,
            #"{"no":0,"tid":1001,"pid":"","data":{"pid":9001}}"#,
            #"{"no":0,"tid":1001,"post_id":null,"data":{"pid":9001}}"#,
            #"{"no":0,"data":{"tid":"","pid":9001}}"#,
            #"{"no":0,"data":{"tid":1001,"pid":false}}"#,
            #"{"no":0,"data":{"tid":1001,"post_id":{"value":9001}}}"#,
            #"{"no":0,"data":{"tid":0,"pid":9001}}"#,
            #"{"no":0,"data":{"tid":1001,"pid":-1}}"#,
            #"{"no":0,"data":{"tid":1001,"pid":1.5}}"#,
            #"{"no":0,"data":{"tid":1001,"pid":9001.0}}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.textReply,
                equals: .outcomeUnknown
            )
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebReplyConflictingIdentifierAliasesHaveUnknownOutcome() async {
        let payloads = [
            #"{"no":0,"tid":1001,"pid":9001,"post_id":9002}"#,
            #"{"no":0,"tid":1001,"data":{"tid":1002,"pid":9001}}"#,
            #"{"no":0,"tid":1001,"post_id":9001,"data":{"post_id":9002}}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            await assertSubmissionError(
                from: harness.api,
                request: Self.textReply,
                equals: .outcomeUnknown
            )
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebImageUploadFeedsExactImageInfoIntoReplyWithoutLegacyUpload() async throws {
        let response = Data(#"{"no":0,"data":{"tid":1001,"pid":9001}}"#.utf8)
        let bootstrap = CountingSubmissionPostingBootstrap(result: Self.bootstrap)
        let harness = makeAPI(mode: .finalResponse(response), postingBootstrap: bootstrap)
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
            "/mo/q/cooluploadpic",
            "/c/s/login",
            "/mo/q/apubpost"
        ])
        let bootstrapCalls = await bootstrap.callCount()
        XCTAssertEqual(bootstrapCalls, 0)

        let upload = try XCTUnwrap(records.first)
        XCTAssertEqual(upload.scheme, "https")
        XCTAssertEqual(upload.host, "tieba.baidu.com")
        XCTAssertEqual(upload.method, "POST")
        XCTAssertEqual(Self.queryFields(from: upload)["type"], "ajax")
        XCTAssertFalse(Self.queryFields(from: upload)["r", default: ""].isEmpty)
        XCTAssertEqual(
            upload.header(named: "Cookie"),
            "BDUSS=fixture-bduss; STOKEN=fixture-stoken"
        )
        XCTAssertFalse(upload.header(named: "Cookie")?.contains("BAIDUID") ?? true)
        XCTAssertEqual(upload.header(named: "Origin"), "https://tieba.baidu.com")
        XCTAssertEqual(
            upload.header(named: "Referer"),
            "https://tieba.baidu.com/p/1001?lp=5028&mo_device=1&is_jingpost=0&pn=1&"
        )
        XCTAssertEqual(upload.header(named: "X-Requested-With"), "XMLHttpRequest")
        XCTAssertEqual(upload.header(named: "Accept"), "application/json, text/plain, */*")
        XCTAssertTrue(upload.header(named: "User-Agent")?.contains("iPhone OS 18_0") == true)
        let uploadFields = try Self.formFields(from: upload)
        XCTAssertEqual(Set(uploadFields.keys), ["pic"])
        XCTAssertEqual(uploadFields["pic"], imageData.base64EncodedString())

        let loginRequest = try XCTUnwrap(records.first(where: { $0.path == "/c/s/login" }))
        XCTAssertEqual(loginRequest.host, "tiebac.baidu.com")
        XCTAssertEqual(loginRequest.method, "POST")
        XCTAssertNil(loginRequest.header(named: "Cookie"))
        let loginFields = try Self.formFields(from: loginRequest)
        XCTAssertEqual(loginFields["_client_version"], "22.5.1.0")
        XCTAssertEqual(loginFields["bdusstoken"], "fixture-bduss")
        XCTAssertFalse(loginFields["sign", default: ""].isEmpty)

        let mutation = try XCTUnwrap(records.last)
        for identityHeader in ["Cookie", "User-Agent", "Accept", "Accept-Language"] {
            XCTAssertEqual(upload.header(named: identityHeader), mutation.header(named: identityHeader))
        }
        let mutationFields = try Self.formFields(from: mutation)
        XCTAssertEqual(mutationFields["co"], "带图回复")
        XCTAssertEqual(mutationFields["upload_img_info"], Self.fixtureImageInfo)
        XCTAssertEqual(mutationFields["tbs"], "fresh-tbs")
        XCTAssertNotEqual(mutationFields["tbs"], Self.account.tbs)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/cooluploadpic", id: harness.id), 1)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/s/uploadPicture", id: harness.id), 0)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
    }

    func testWebUploadFailuresRemainTypedAndStopBeforeTBSOrFinalMutation() async throws {
        let cases: [(SubmissionStubMode, ContentSubmissionError)] = [
            (
                .uploadResponse(Data(#"{"error_code":7,"error_msg":"上传被拒绝"}"#.utf8)),
                .business(code: 7, message: "上传被拒绝")
            ),
            (
                .uploadResponse(Data(#"{"error_code":110001,"error_msg":"用户未登录"}"#.utf8)),
                .sessionExpired
            ),
            (
                .uploadTransportFailure,
                .business(code: -1, message: "图片上传失败，请检查网络后重试。")
            )
        ]

        for (mode, expected) in cases {
            let harness = makeAPI(mode: mode)
            await assertSubmissionError(
                from: harness.api,
                request: try Self.imageReplyRequest(),
                equals: expected
            )
            XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), ["/mo/q/cooluploadpic"])
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/s/login", id: harness.id), 0)
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 0)
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testMalformedFloorTargetsAreRejectedBeforeBootstrapOrNetwork() async throws {
        let response = Data(#"{"no":0,"data":{"tid":1001,"pid":9001}}"#.utf8)
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

    func testReplyDoesNotConsultPostingBootstrapEvenWhenItWouldFail() async throws {
        let error = TiebaPostingBootstrapError.server(code: 340006, message: "sync rejected")
        let harness = makeAPI(
            mode: .finalResponse(Data(#"{"no":0,"data":{"tid":1001,"pid":9001}}"#.utf8)),
            postingBootstrap: FailingSubmissionPostingBootstrap(error: error)
        )
        defer { SubmissionURLProtocol.remove(id: harness.id) }

        let receipt = try await harness.api.submitContent(
            account: Self.account,
            request: Self.textReply
        )

        XCTAssertEqual(receipt, ContentSubmissionReceipt(threadID: 1001, postID: 9001))
        XCTAssertEqual(SubmissionURLProtocol.paths(id: harness.id), [
            "/c/s/login",
            "/mo/q/apubpost"
        ])
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
            "/c/s/login"
        ])
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 0)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
    }

    func testWebReplyFinalTransportAndDecodeFailuresHaveUnknownOutcomeWithoutRetry() async {
        for mode in [SubmissionStubMode.finalTransportFailure, .finalDecodeFailure] {
            let harness = makeAPI(mode: mode)
            await assertSubmissionError(
                from: harness.api,
                request: Self.textReply,
                equals: .outcomeUnknown
            )
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
            XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
            SubmissionURLProtocol.remove(id: harness.id)
        }
    }

    func testWebReplyCancellationAfterFinalDispatchHasUnknownOutcomeWithoutRetry() async throws {
        let harness = makeAPI(mode: .holdFinalRequestUntilCancellation)
        defer { SubmissionURLProtocol.remove(id: harness.id) }
        let submission = Task {
            try await harness.api.submitContent(account: Self.account, request: Self.textReply)
        }

        try await waitForRequest(path: "/mo/q/apubpost", id: harness.id)
        submission.cancel()

        do {
            _ = try await submission.value
            XCTFail("Expected cancellation after dispatch to have an unknown outcome")
        } catch let error as ContentSubmissionError {
            XCTAssertEqual(error, .outcomeUnknown)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/mo/q/apubpost", id: harness.id), 1)
        XCTAssertEqual(SubmissionURLProtocol.count(path: "/c/c/post/add", id: harness.id), 0)
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
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let contextSuffix = context.isEmpty ? "" : " for response: \(context)"
        do {
            _ = try await api.submitContent(account: Self.account, request: request)
            XCTFail("Expected submission to fail\(contextSuffix)", file: file, line: line)
        } catch let error as ContentSubmissionError {
            XCTAssertEqual(
                error,
                expected,
                "Unexpected submission error\(contextSuffix)",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)\(contextSuffix)", file: file, line: line)
        }
    }

    private static func formFields(from request: SubmissionRecordedRequest) throws -> [String: String] {
        let body = try XCTUnwrap(request.body)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        var components = URLComponents()
        // application/x-www-form-urlencoded represents spaces as '+'. A
        // literal plus is already escaped as %2B by the production encoder.
        components.percentEncodedQuery = text.replacingOccurrences(of: "+", with: "%20")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static func queryFields(from request: SubmissionRecordedRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = request.query
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

    private static func replyRequest(kind: ContentSubmissionKind) -> ContentSubmissionRequest {
        let target: ContentSubmissionTarget
        switch kind {
        case .threadReply:
            target = Self.target
        case .postReply:
            target = ContentSubmissionTarget(
                kind: .postReply,
                forumID: 100,
                forumName: "fixture",
                forumDisplayName: "夹具吧",
                threadID: 1001,
                threadTitle: "夹具主题",
                parentPostID: 2002,
                parentFloor: 2,
                subpostID: nil,
                replyUserID: 42,
                replyUserDisplayName: "被回复用户"
            )
        case .subpostReply:
            target = ContentSubmissionTarget(
                kind: .subpostReply,
                forumID: 100,
                forumName: "fixture",
                forumDisplayName: "夹具吧",
                threadID: 1001,
                threadTitle: "夹具主题",
                parentPostID: 2002,
                parentFloor: 2,
                subpostID: 3002,
                replyUserID: 43,
                replyUserDisplayName: "被回复用户"
            )
        case .newThread:
            target = Self.target
        }
        return ContentSubmissionRequest(
            target: target,
            title: "",
            body: "离线提交测试",
            images: []
        )
    }

    private static func imageReplyRequest() throws -> ContentSubmissionRequest {
        let imageData = try XCTUnwrap(Data(base64Encoded: onePixelPNGBase64))
        return ContentSubmissionRequest(
            target: target,
            title: "",
            body: "带图回复",
            images: [ContentSubmissionImage(
                data: imageData,
                pixelWidth: 1,
                pixelHeight: 1,
                mimeType: "image/png"
            )]
        )
    }

    private static func newThreadRequest(
        title: String = "新主题",
        body: String = "新主题正文"
    ) -> ContentSubmissionRequest {
        ContentSubmissionRequest(
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
            title: title,
            body: body,
            images: []
        )
    }

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
    private static let fixtureImageInfo = "fixture-image-info"
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
    case uploadResponse(Data)
    case uploadTransportFailure
    case tbsResponse(Data)
    case tbsRefreshFailure
    case finalTransportFailure
    case finalDecodeFailure
    case holdFinalRequestUntilCancellation
}

private struct SubmissionRecordedRequest: Sendable {
    let path: String
    let scheme: String
    let host: String
    let method: String
    let query: String?
    let headers: [String: String]
    let body: Data?

    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
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
        case "/mo/q/cooluploadpic":
            switch mode {
            case let .uploadResponse(payload):
                respond(statusCode: 200, payload: payload, contentType: "application/json")
            case .uploadTransportFailure:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            default:
                respond(
                    statusCode: 200,
                    payload: Data(#"{"error_code":0,"image_info":"fixture-image-info"}"#.utf8),
                    contentType: "application/json"
                )
            }

        case "/c/s/uploadPicture":
            respond(
                statusCode: 200,
                payload: Data(#"{"error_code":0,"picId":"fixture_pic_1"}"#.utf8),
                contentType: "application/json"
            )

        case "/c/s/login":
            if case .tbsRefreshFailure = mode {
                respond(statusCode: 503, payload: Data("unavailable".utf8))
            } else if case let .tbsResponse(payload) = mode {
                respond(statusCode: 200, payload: payload, contentType: "application/json")
            } else {
                respond(
                    statusCode: 200,
                    payload: Data(#"{"error_code":"0","anti":{"tbs":"fresh-tbs"}}"#.utf8),
                    contentType: "application/json"
                )
            }

        case "/mo/q/newmoindex":
            respond(statusCode: 503, payload: Data("unavailable".utf8))

        case "/mo/q/apubpost", "/c/c/post/add", "/f/commit/thread/add":
            switch mode {
            case let .finalResponse(payload):
                respond(statusCode: 200, payload: payload)
            case .finalTransportFailure:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .finalDecodeFailure:
                respond(statusCode: 200, payload: Data([0x0f]))
            case .holdFinalRequestUntilCancellation:
                break
            case .tbsRefreshFailure, .tbsResponse, .uploadResponse, .uploadTransportFailure:
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
            scheme: request.url?.scheme ?? "",
            host: request.url?.host ?? "",
            method: request.httpMethod ?? "",
            query: request.url?.query,
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
