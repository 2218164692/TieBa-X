import XCTest
@testable import TieBaX

final class MessageAPITests: XCTestCase {
    private let builder = TiebaRequestBuilder(
        screenScale: 3,
        screenWidth: 1179,
        screenHeight: 2556,
        clientID: "message-test-client"
    )

    override func tearDown() {
        MessageMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testReplyMessagesPostsSignedFormToReplyMePath() async throws {
        let api = makeAPI { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "c.tieba.baidu.com")
            XCTAssertEqual(url.path, "/c/u/feed/replyme")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 8.2.2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "cuid"), self.builder.miniCUID)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")

            var fields = try Self.formFields(request)
            XCTAssertEqual(fields["BDUSS"], "bduss")
            XCTAssertEqual(fields["pn"], "2")
            XCTAssertEqual(fields["_client_id"], "message-test-client")
            XCTAssertEqual(fields["_client_type"], "2")
            XCTAssertEqual(fields["_client_version"], "8.2.2")
            XCTAssertEqual(fields["from"], "baidu_appstore")
            XCTAssertEqual(fields["net_type"], "1")
            XCTAssertEqual(fields["stErrorNums"], "0")
            XCTAssertNotNil(fields["timestamp"])
            XCTAssertNil(fields["subapp_type"])
            XCTAssertNil(fields["cuid_galaxy2"])
            let sign = try XCTUnwrap(fields.removeValue(forKey: "sign"))
            XCTAssertEqual(sign, TiebaFormSigner.sign(fields: fields, secret: "tiebaclient!!!"))

            return Self.replyResponseJSON
        }

        let page = try await api.messages(account: makeAccount(), kind: .reply, page: 2)

        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.items.count, 2)

        let first = try XCTUnwrap(page.items.first)
        XCTAssertEqual(first.id, "reply-123-456-77-1710000000")
        XCTAssertEqual(first.kind, .reply)
        XCTAssertEqual(first.author.id, 77)
        XCTAssertEqual(first.author.displayNameResolved, "回复者")
        XCTAssertEqual(first.author.portrait, "tb.1.reply")
        XCTAssertEqual(first.content, "回复内容")
        XCTAssertEqual(first.threadID, 123)
        XCTAssertEqual(first.postID, 456)
        XCTAssertEqual(first.threadTitle, "主题标题")
        XCTAssertEqual(first.forumName, "iPhone")
        XCTAssertFalse(first.isFloorReply)
        XCTAssertEqual(first.createdAt, Date(timeIntervalSince1970: 1_710_000_000))

        let floor = try XCTUnwrap(page.items.last)
        XCTAssertEqual(floor.id, "reply-124-999-88-1710003600")
        XCTAssertTrue(floor.isFloorReply)
        // A floor reply must jump to the parent post, not the subpost id.
        XCTAssertEqual(floor.postID, 456)
    }

    func testAtMessagesPostsToAtMePathAndMapsAtList() async throws {
        let api = makeAPI { request in
            XCTAssertEqual(request.url?.path, "/c/u/feed/atme")
            let fields = try Self.formFields(request)
            XCTAssertEqual(fields["pn"], "1")
            XCTAssertNotNil(fields["sign"])
            return Self.atResponseJSON
        }

        let page = try await api.messages(account: makeAccount(), kind: .at, page: 1)

        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertEqual(page.items.count, 1)

        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.id, "at-321-654-99-1710007200")
        XCTAssertEqual(item.kind, .at)
        XCTAssertEqual(item.author.displayNameResolved, "提及我的用户")
        XCTAssertEqual(item.threadID, 321)
        XCTAssertEqual(item.postID, 654)
        XCTAssertEqual(item.forumName, "显卡")
    }

    func testMessagesMapsExpiredSessionBusinessCode() async throws {
        let api = makeAPI { _ in
            // Business failures are validated before requiring the successful
            // response's selected list field or interpreting its shape.
            Data(
                #"{"error_code":"110001","error_msg":"登录失效","reply_list":{}}"#.utf8
            )
        }

        do {
            _ = try await api.messages(account: makeAccount(), kind: .reply, page: 1)
            XCTFail("Expected expired session business error")
        } catch {
            XCTAssertEqual(
                error as? TiebaAPIError,
                .sessionExpired(code: 110001, message: "登录失效")
            )
        }
    }

    func testMessagesRejectsInvalidPageBeforeSendingRequest() async {
        let api = makeAPI { request in
            XCTFail("Unexpected request: \(String(describing: request.url))")
            return Data()
        }

        do {
            _ = try await api.messages(account: makeAccount(), kind: .reply, page: 0)
            XCTFail("Expected page validation error")
        } catch {
            XCTAssertEqual(
                error as? TiebaRequestValidationError,
                .invalidPage(0)
            )
        }
    }

    func testPaginationKeepsLoadingAfterFilteredEmptyPageWhenServerHasMore() {
        let page = MessagesPage(
            items: [],
            currentPage: 3,
            hasMore: true
        )

        XCTAssertEqual(
            MessagePaginationPolicy.state(after: page, requestedPage: 3),
            MessagePaginationState(nextPage: 4, hasMore: true)
        )
    }

    func testMessagesTreatsMissingSelectedListFieldAsEmpty() async throws {
        let api = makeAPI { _ in
            Data(#"{"error_code":0,"error_msg":"success","at_list":[]}"#.utf8)
        }

        let page = try await api.messages(account: makeAccount(), kind: .reply, page: 1)

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testMessagesRejectsDriftedSelectedListType() async throws {
        let api = makeAPI { _ in
            Data(#"{"error_code":0,"error_msg":"success","reply_list":{}}"#.utf8)
        }

        do {
            _ = try await api.messages(account: makeAccount(), kind: .reply, page: 1)
            XCTFail("Expected reply_list type mismatch")
        } catch DecodingError.typeMismatch {
            // Expected: a present list field must be an array.
        } catch {
            XCTFail("Expected DecodingError.typeMismatch, got \(error)")
        }
    }

    func testResponseDecodingTreatsNilPrimitiveAndExplicitEmptyListsAsEmpty() throws {
        let replyValues = ["null", "0", "\"\"", "[]"]
        for value in replyValues {
            let response = try JSONDecoder().decode(
                MessageListResponseDTO.self,
                from: Data(#"{"error_code":0,"reply_list":\#(value)}"#.utf8)
            )
            XCTAssertTrue(response.list(for: .reply).isEmpty, "reply_list=\(value)")
        }

        let missing = try JSONDecoder().decode(
            MessageListResponseDTO.self,
            from: Data(#"{"error_code":0}"#.utf8)
        )
        XCTAssertTrue(missing.list(for: .reply).isEmpty)

        let atPrimitive = try JSONDecoder().decode(
            MessageListResponseDTO.self,
            from: Data(#"{"error_code":0,"at_list":0}"#.utf8)
        )
        XCTAssertTrue(atPrimitive.list(for: .at).isEmpty)
    }

    func testResponseDecodingRejectsMalformedArrayElement() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            MessageListResponseDTO.self,
            from: Data(#"{"error_code":0,"reply_list":[0]}"#.utf8)
        )) { error in
            guard case DecodingError.typeMismatch = error else {
                return XCTFail("Expected array element type mismatch, got \(error)")
            }
        }
    }

    func testResponseDecodingAcceptsMixedNumericAndStringFields() throws {
        let response = try JSONDecoder().decode(
            MessageListResponseDTO.self,
            from: Data("""
            {
              "error_code": 0,
              "reply_list": [
                {
                  "is_floor": 1,
                  "title": "数字字段标题",
                  "content": "数字字段内容",
                  "replyer": {"id": 5, "name": "raw", "name_show": "混合类型用户", "portrait": "tb.1.mixed?t=99"},
                  "thread_id": 42,
                  "post_id": 4300,
                  "quote_pid": 4200,
                  "time": 1710000000,
                  "fname": "测试"
                },
                {
                  "is_floor": "0",
                  "title": "无主题",
                  "content": "被丢弃的条目",
                  "thread_id": "0",
                  "post_id": "1"
                }
              ],
              "page": {"current_page": 3, "has_more": 0}
            }
            """.utf8)
        )

        XCTAssertEqual(response.currentPage, 3)
        XCTAssertFalse(response.hasMore)
        let replyList = try XCTUnwrap(response.replyList)
        XCTAssertEqual(replyList.count, 2)

        let item = try XCTUnwrap(replyList.first?.messageItem(kind: .reply))
        XCTAssertEqual(item.author.id, 5)
        XCTAssertEqual(item.author.portrait, "tb.1.mixed")
        XCTAssertEqual(item.threadID, 42)
        XCTAssertTrue(item.isFloorReply)
        XCTAssertEqual(item.postID, 4200)
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1_710_000_000))

        // Entries without a thread cannot be opened and must be dropped.
        XCTAssertNil(replyList.last?.messageItem(kind: .reply))
    }

    func testMessageWithoutReplyerFallsBackToPlaceholderAuthor() throws {
        let response = try JSONDecoder().decode(
            MessageListResponseDTO.self,
            from: Data("""
            {
              "error_code": "0",
              "at_list": [
                {"title": "标题", "content": "内容", "thread_id": "9", "post_id": "10", "quote_pid": "0"}
              ],
              "page": {"current_page": "1", "has_more": "0"}
            }
            """.utf8)
        )

        let atList = try XCTUnwrap(response.atList)
        let item = try XCTUnwrap(atList.first?.messageItem(kind: .at))
        XCTAssertEqual(item.author.id, 0)
        XCTAssertEqual(item.author.displayNameResolved, "未知用户")
        XCTAssertNil(item.forumName)
        XCTAssertNil(item.createdAt)
    }

    func testMessageIdentityDistinguishesEventsOnTheSamePostAndIsStable() throws {
        let data = Data("""
        {
          "error_code": 0,
          "reply_list": [
            {
              "thread_id": "42",
              "post_id": "99",
              "time": "1710000000",
              "replyer": {"id": "7", "name": "first"}
            },
            {
              "thread_id": "42",
              "post_id": "99",
              "time": "1710000001",
              "replyer": {"id": "8", "name": "second"}
            }
          ]
        }
        """.utf8)

        let firstDecode = try JSONDecoder().decode(MessageListResponseDTO.self, from: data)
        let secondDecode = try JSONDecoder().decode(MessageListResponseDTO.self, from: data)
        let firstIDs = firstDecode.list(for: .reply).compactMap {
            $0.messageItem(kind: .reply)?.id
        }
        let secondIDs = secondDecode.list(for: .reply).compactMap {
            $0.messageItem(kind: .reply)?.id
        }

        XCTAssertEqual(
            firstIDs,
            [
                "reply-42-99-7-1710000000",
                "reply-42-99-8-1710000001"
            ]
        )
        XCTAssertEqual(secondIDs, firstIDs)
        XCTAssertEqual(Set(firstIDs).count, 2)
    }

    private func makeAccount() -> Account {
        Account(
            uid: "42",
            name: "raw",
            displayName: "本人",
            portrait: "portrait",
            bduss: "bduss",
            stoken: "stoken",
            baiduID: "baiduid",
            tbs: "tbs"
        )
    }

    private func makeAPI(handler: @escaping (URLRequest) throws -> Data) -> TiebaAPI {
        MessageMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageMockURLProtocol.self]
        return TiebaAPI(
            client: TiebaHTTPClient(session: URLSession(configuration: configuration)),
            requestBuilder: builder
        )
    }

    private static func formFields(_ request: URLRequest) throws -> [String: String] {
        let body: Data
        if let requestBody = request.httpBody {
            body = requestBody
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw try XCTUnwrap(stream.streamError) }
                if count == 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            body = collected
        }
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static let replyResponseJSON = Data("""
    {
      "error_code": "0",
      "error_msg": "",
      "time": 1710000123,
      "reply_list": [
        {
          "is_floor": "0",
          "title": "主题标题",
          "content": "回复内容",
          "quote_content": "我的原贴内容",
          "replyer": {
            "id": "77",
            "name": "raw_replyer",
            "name_show": "回复者",
            "portrait": "tb.1.reply?t=123"
          },
          "thread_id": "123",
          "post_id": "456",
          "time": "1710000000",
          "fname": "iPhone",
          "quote_pid": "0",
          "unread": "1"
        },
        {
          "is_floor": "1",
          "title": "主题标题2",
          "content": "楼中楼回复",
          "replyer": {
            "id": 88,
            "name": "floor_raw",
            "name_show": "楼中楼回复者",
            "portrait": "tb.1.floor"
          },
          "thread_id": 124,
          "post_id": "999",
          "quote_pid": "456",
          "time": "1710003600",
          "fname": "显卡"
        }
      ],
      "page": {"current_page": "2", "has_more": "1", "has_prev": "1"},
      "message": {"replyme": "2", "atme": "0"}
    }
    """.utf8)

    private static let atResponseJSON = Data("""
    {
      "error_code": "0",
      "error_msg": "",
      "at_list": [
        {
          "is_floor": "0",
          "title": "提及主题",
          "content": "@本人 看看这个",
          "replyer": {
            "id": "99",
            "name": "at_raw",
            "name_show": "提及我的用户",
            "portrait": "tb.1.at"
          },
          "thread_id": "321",
          "post_id": "654",
          "time": "1710007200",
          "fname": "显卡",
          "quote_pid": "0"
        }
      ],
      "page": {"current_page": "1", "has_more": "0", "has_prev": "0"}
    }
    """.utf8)
}

private final class MessageMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
