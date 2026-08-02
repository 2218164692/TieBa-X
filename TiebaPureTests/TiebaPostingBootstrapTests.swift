import Foundation
import XCTest
@testable import TiebaPure

final class TiebaPostingBootstrapTests: XCTestCase {
    private static let vectorSeed = try! TiebaPostingIdentitySeed(
        androidID: "6723280942424242",
        uuid: "67232809-3407-3442-4207-672346917aaa",
        aesCBCKey: Data("6723280942424242".utf8)
    )

    override func setUp() {
        super.setUp()
        PostingBootstrapURLProtocol.reset()
    }

    override func tearDown() {
        PostingBootstrapURLProtocol.reset()
        super.tearDown()
    }

    func testLiveAccountCredentialShape() async throws {
        guard ProcessInfo.processInfo.environment["TIEBAPURE_RUN_LIVE_CREDENTIAL_CHECK"] == "1" else {
            throw XCTSkip("真实账号凭证形态检查仅在显式启用时运行。")
        }

        let store = AccountStore(service: KeychainAccountStoreService())
        let loadedAccount = try await store.load()
        let account = try XCTUnwrap(loadedAccount)
        let bdussBytes = account.bduss.utf8.count
        let stokenBytes = account.stoken.utf8.count
        print("TIEBAPURE_LIVE_CREDENTIAL_SHAPE bduss_bytes=\(bdussBytes) stoken_bytes=\(stokenBytes)")
        XCTAssertEqual(bdussBytes, 192, "发布协议要求 192 字节的传统 BDUSS。")
        XCTAssertEqual(stokenBytes, 64, "发布协议要求 64 字节的 STOKEN。")
    }

    func testLivePostingTBSRefresh() async throws {
        guard ProcessInfo.processInfo.environment["TIEBAPURE_RUN_LIVE_CREDENTIAL_CHECK"] == "1" else {
            throw XCTSkip("真实账号发布校验仅在显式启用时运行。")
        }

        let store = AccountStore(service: KeychainAccountStoreService())
        let loadedAccount = try await store.load()
        let account = try XCTUnwrap(loadedAccount)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let api = TiebaAPI(client: TiebaHTTPClient(session: SecureRemoteURLSession.make(
            configuration: configuration,
            redirectScope: .baiduHTTPS
        )))

        let tbs = try await api.strictlyRefreshedPostingTBS(for: account)
        print("TIEBAPURE_LIVE_POSTING_TBS tbs_bytes=\(tbs.utf8.count)")
        XCTAssertFalse(tbs.isEmpty)
    }

    func testIdentityMatchesPinnedAiotieba471Vectors() throws {
        let identity = try TiebaPostingBootstrap.deriveIdentity(from: Self.vectorSeed)

        XCTAssertEqual(identity.cuidGalaxy2, "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TA")
        XCTAssertEqual(identity.c3AID, "A00-OGBA33NRAQASXI6FDZ4YAJFTK75EF4Y5-YVOG764X")

        let wrapped = TiebaPostingCrypto.rc442(
            key: Data("d0337b3b3d597c5f87a1c0c37139d87b".utf8),
            input: Data("6723280942424242".utf8)
        )
        XCTAssertEqual(wrapped, Data([
            0x9f, 0xab, 0x55, 0x14, 0xa7, 0x0e, 0xb6, 0x6b,
            0xc4, 0x77, 0x56, 0xf2, 0x48, 0x4e, 0x2b, 0x2e
        ]))
    }

    func testBootstrappingProtocolSupportsInjectedSubstitute() async throws {
        let expected = TiebaPostingBootstrapResult(
            identity: TiebaPostingIdentity(
                androidID: "0123456789abcdef",
                uuid: "01234567-89ab-4def-8123-456789abcdef",
                cuidGalaxy2: "fixture-cuid",
                c3AID: "fixture-c3-aid"
            ),
            clientID: "fixture-client-id",
            sampleID: "fixture-sample-id",
            zID: "fixture-z-id"
        )
        let bootstrapper: any TiebaPostingBootstrapping = PostingBootstrapStub(result: expected)

        let actual = try await bootstrapper.bootstrap(bduss: "fixture-bduss")

        XCTAssertEqual(actual, expected)
    }

    func testGeneratedIdentityIsPersistedAndReused() async throws {
        let store = PostingBootstrapMemoryStore()
        let random = LockedRandomBytes(Data((0..<40).map(UInt8.init)))
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: FailingPostingBootstrapTransport(error: .invalidResponse),
            randomBytes: { count in try random.bytes(count: count) }
        )

        let first = try await bootstrap.identity()
        let second = try await bootstrap.identity()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.androidID, "0001020304050607")
        XCTAssertEqual(first.uuid, "08090a0b-0c0d-4e0f-9011-121314151617")
        XCTAssertEqual(random.callCount, 1)
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1)
    }

    func testCorruptPersistedIdentityFailsWithoutRandomFallback() async throws {
        let store = PostingBootstrapMemoryStore(data: Data("not-json".utf8))
        let random = LockedRandomBytes(Data(repeating: 7, count: 40))
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: FailingPostingBootstrapTransport(error: .invalidResponse),
            randomBytes: { count in try random.bytes(count: count) }
        )

        do {
            _ = try await bootstrap.identity()
            XCTFail("损坏的持久身份不得静默换成新设备")
        } catch {
            XCTAssertEqual(error as? TiebaPostingBootstrapError, .invalidStoredIdentity)
        }
        XCTAssertEqual(random.callCount, 0)
    }

    func testBootstrapSynchronizesRiskFieldsWithEncryptedZIDFixture() async throws {
        let encodedSeed = try JSONEncoder().encode(Self.vectorSeed)
        let store = PostingBootstrapMemoryStore(data: encodedSeed)
        PostingBootstrapURLProtocol.handler = { request in
            switch request.url?.path {
            case "/c/s/sync":
                try Self.validateSyncRequest(request)
                return .json(#"{"error_code":"0","client":{"client_id":"wappc_fixture"},"wl_config":{"sample_id":"104505_3-107269_1"}}"#)
            case let path? where path.hasPrefix("/c/11/z/100/200033/1700000000/"):
                return try Self.zIDResponse(for: request, token: "zid-fixture-token")
            default:
                throw PostingBootstrapFixtureError.unexpectedRequest
            }
        }

        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: makeURLSessionTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let result = try await bootstrap.bootstrap(bduss: "fixture-bduss")

        XCTAssertEqual(result.clientID, "wappc_fixture")
        XCTAssertEqual(result.sampleID, "104505_3-107269_1")
        XCTAssertEqual(result.zID, "zid-fixture-token")
        XCTAssertEqual(result.identity.cuidGalaxy2, "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TA")
        XCTAssertEqual(Set(PostingBootstrapURLProtocol.paths), ["/c/s/sync", PostingBootstrapURLProtocol.zIDPath])
    }

    func testSecondBootstrapFailureDoesNotReturnPreviousValues() async throws {
        let store = PostingBootstrapMemoryStore(data: try JSONEncoder().encode(Self.vectorSeed))
        let state = LockedFixtureState()
        PostingBootstrapURLProtocol.handler = { request in
            if request.url?.path == "/c/s/sync" {
                if state.consumeSyncSuccess() {
                    return .json(#"{"error_code":0,"client":{"client_id":"first-client"},"wl_config":{"sample_id":"first-sample"}}"#)
                }
                return .json(#"{"error_code":340006,"error_msg":"sync rejected"}"#)
            }
            return try Self.zIDResponse(for: request, token: "fixture-zid")
        }
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: makeURLSessionTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let first = try await bootstrap.bootstrap(bduss: "fixture-bduss")
        XCTAssertEqual(first.clientID, "first-client")

        do {
            _ = try await bootstrap.bootstrap(bduss: "fixture-bduss")
            XCTFail("同步失败不得回退上一次身份字段")
        } catch {
            XCTAssertEqual(
                error as? TiebaPostingBootstrapError,
                .server(code: 340006, message: "sync rejected")
            )
        }
    }

    func testDeclaredOversizedResponseIsRejected() async throws {
        let store = PostingBootstrapMemoryStore(data: try JSONEncoder().encode(Self.vectorSeed))
        PostingBootstrapURLProtocol.handler = { request in
            if request.url?.path == "/c/s/sync" {
                return PostingBootstrapFixtureResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Content-Length": "\(TiebaPostingBootstrap.maximumSyncResponseBytes + 1)"
                    ],
                    data: Data("{}".utf8)
                )
            }
            return try Self.zIDResponse(for: request, token: "fixture-zid")
        }
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: makeURLSessionTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        do {
            _ = try await bootstrap.bootstrap(bduss: "fixture-bduss")
            XCTFail("声明超限的响应应立即拒绝")
        } catch {
            XCTAssertEqual(
                error as? TiebaPostingBootstrapError,
                .responseTooLarge(limit: TiebaPostingBootstrap.maximumSyncResponseBytes)
            )
        }
    }

    func testSyncResponseLargerThanLegacyLimitIsAcceptedWithinBound() async throws {
        let store = PostingBootstrapMemoryStore(data: try JSONEncoder().encode(Self.vectorSeed))
        PostingBootstrapURLProtocol.handler = { request in
            if request.url?.path == "/c/s/sync" {
                let padding = String(repeating: "x", count: 128 * 1_024)
                return .json(
                    #"{"error_code":0,"client":{"client_id":"fixture-client"},"wl_config":{"sample_id":"fixture-sample"},"unused":"\#(padding)"}"#
                )
            }
            return try Self.zIDResponse(for: request, token: "fixture-zid")
        }
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: makeURLSessionTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await bootstrap.bootstrap(bduss: "fixture-bduss")

        XCTAssertEqual(result.clientID, "fixture-client")
        XCTAssertEqual(result.sampleID, "fixture-sample")
        XCTAssertEqual(result.zID, "fixture-zid")
    }

    func testStreamedOversizedResponseIsRejected() async throws {
        let store = PostingBootstrapMemoryStore(data: try JSONEncoder().encode(Self.vectorSeed))
        PostingBootstrapURLProtocol.handler = { request in
            if request.url?.path == "/c/s/sync" {
                return PostingBootstrapFixtureResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    data: Data(repeating: 0x41, count: TiebaPostingBootstrap.maximumSyncResponseBytes + 1)
                )
            }
            return try Self.zIDResponse(for: request, token: "fixture-zid")
        }
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: makeURLSessionTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        do {
            _ = try await bootstrap.bootstrap(bduss: "fixture-bduss")
            XCTFail("流式累计超限的响应应立即拒绝")
        } catch {
            XCTAssertEqual(
                error as? TiebaPostingBootstrapError,
                .responseTooLarge(limit: TiebaPostingBootstrap.maximumSyncResponseBytes)
            )
        }
    }

    func testZIDResponseOpaqueSuffixDoesNotRejectValidPayload() async throws {
        let store = PostingBootstrapMemoryStore(data: try JSONEncoder().encode(Self.vectorSeed))
        PostingBootstrapURLProtocol.handler = { request in
            if request.url?.path == "/c/s/sync" {
                return .json(#"{"error_code":0,"client":{"client_id":"fixture"},"wl_config":{"sample_id":"fixture"}}"#)
            }
            return try Self.zIDResponse(
                for: request,
                token: "fixture-zid",
                responseSuffix: Data(repeating: 0, count: 16)
            )
        }
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: makeURLSessionTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await bootstrap.bootstrap(bduss: "fixture-bduss")
        XCTAssertEqual(result.zID, "fixture-zid")
    }

    func testZIDResponseInvalidPaddingIsRejected() async throws {
        let store = PostingBootstrapMemoryStore(data: try JSONEncoder().encode(Self.vectorSeed))
        PostingBootstrapURLProtocol.handler = { request in
            if request.url?.path == "/c/s/sync" {
                return .json(#"{"error_code":0,"client":{"client_id":"fixture"},"wl_config":{"sample_id":"fixture"}}"#)
            }
            return try Self.zIDResponse(for: request, token: "fixture-zid", validPadding: false)
        }
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: makeURLSessionTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        do {
            _ = try await bootstrap.bootstrap(bduss: "fixture-bduss")
            XCTFail("无效的 PKCS#7 填充必须被拒绝")
        } catch {
            XCTAssertEqual(error as? TiebaPostingBootstrapError, .invalidCiphertext)
        }
    }

    func testCancellationIsPreserved() async throws {
        let store = PostingBootstrapMemoryStore(data: try JSONEncoder().encode(Self.vectorSeed))
        let transport = BlockingPostingBootstrapTransport()
        let bootstrap = TiebaPostingBootstrap(
            store: store,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let task = Task {
            try await bootstrap.bootstrap(bduss: "fixture-bduss")
        }
        await transport.waitUntilStarted()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消必须原样传播")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private static func validateSyncRequest(_ request: URLRequest) throws {
        XCTAssertEqual(request.httpMethod, "POST")
        let form = try XCTUnwrap(formFields(requestBodyData(request)))
        XCTAssertEqual(form["BDUSS"], "fixture-bduss")
        XCTAssertEqual(form["_client_version"], "22.5.1.0")
        XCTAssertEqual(form["cuid"], "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TA")
        let unsigned = form.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
        XCTAssertEqual(
            form["sign"],
            TiebaPostingCrypto.formSignature(fields: unsigned, salt: "tiebaclient!!!")
        )
    }

    private static func zIDResponse(
        for request: URLRequest,
        token: String,
        responseSuffix: Data? = nil,
        validPadding: Bool = true
    ) throws -> PostingBootstrapFixtureResponse {
        let deviceID = try XCTUnwrap(request.value(forHTTPHeaderField: "x-device-id"))
        XCTAssertEqual(deviceID, "bfa38d90556047524f41f88c6e6f6ea7")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let wrappedValue = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "skey" })?.value)
        let wrapped = try XCTUnwrap(Data(base64Encoded: wrappedValue))
        let requestKey = TiebaPostingCrypto.rc442(key: Data(deviceID.utf8), input: wrapped)
        XCTAssertEqual(requestKey, Self.vectorSeed.aesCBCKey)

        let body = try XCTUnwrap(requestBodyData(request))
        XCTAssertGreaterThan(body.count, 16)
        let encrypted = Data(body.dropLast(16))
        let digest = Data(body.suffix(16))
        let compressed = try TiebaPostingCrypto.removePKCS7Padding(
            TiebaPostingCrypto.aesCBCDecryptRaw(encrypted, key: requestKey)
        )
        let xyus = "236DD25AD32A5FE71FD3D68F7A0F3FFF|0"
        let expectedJSON = Data("{\"module_section\":[{\"zid\":\"\(xyus)\"}]}".utf8)
        XCTAssertEqual(compressed, TiebaPostingCrypto.gzipStored(expectedJSON))
        XCTAssertEqual(digest, TiebaPostingCrypto.md5(compressed))

        let responseKey = Data("0123456789abcdef".utf8)
        let responseWrappedKey = TiebaPostingCrypto.rc442(
            key: Data(deviceID.utf8),
            input: responseKey
        )
        let json = Data("{\"token\":\"\(token)\"}".utf8)
        var paddedJSON = TiebaPostingCrypto.addPKCS7Padding(json)
        if validPadding == false {
            paddedJSON[paddedJSON.index(before: paddedJSON.endIndex)] = 0
        }
        let suffix = responseSuffix ?? TiebaPostingCrypto.md5(json)
        XCTAssertEqual(suffix.count, 16)
        let responsePlaintext = paddedJSON + suffix
        let responseCiphertext = try TiebaPostingCrypto.aesCBCEncryptRaw(responsePlaintext, key: responseKey)
        let responseObject = [
            "skey": responseWrappedKey.base64EncodedString(),
            "data": responseCiphertext.base64EncodedString()
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys])
        return .jsonData(responseData)
    }

    private static func formFields(_ data: Data?) -> [String: String]? {
        guard let data, let value = String(data: data, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for pair in value.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { return nil }
            let key = String(components[0]).removingPercentEncoding ?? String(components[0])
            let rawValue = String(components[1]).replacingOccurrences(of: "+", with: " ")
            result[key] = rawValue.removingPercentEncoding ?? rawValue
        }
        return result
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func makeURLSessionTransport() -> URLSessionTiebaPostingBootstrapTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PostingBootstrapURLProtocol.self]
        return URLSessionTiebaPostingBootstrapTransport(session: URLSession(configuration: configuration))
    }
}

private struct PostingBootstrapStub: TiebaPostingBootstrapping {
    let result: TiebaPostingBootstrapResult

    func bootstrap(bduss: String) async throws -> TiebaPostingBootstrapResult {
        result
    }
}

private actor PostingBootstrapMemoryStore: TiebaPostingIdentityPersisting {
    private var data: Data?
    private(set) var saveCount = 0

    init(data: Data? = nil) {
        self.data = data
    }

    func load() async throws -> Data? { data }

    func save(_ data: Data) async throws {
        self.data = data
        saveCount += 1
    }
}

private struct FailingPostingBootstrapTransport: TiebaPostingBootstrapTransport {
    let error: TiebaPostingBootstrapError

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

private actor BlockingPostingBootstrapTransport: TiebaPostingBootstrapTransport {
    private var starts = 0

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        starts += 1
        try await Task.sleep(for: .seconds(30))
        throw PostingBootstrapFixtureError.unexpectedRequest
    }

    func waitUntilStarted() async {
        for _ in 0..<100 where starts == 0 {
            await Task.yield()
        }
    }
}

private final class LockedRandomBytes: @unchecked Sendable {
    private let lock = NSLock()
    private let value: Data
    private var count = 0

    init(_ value: Data) {
        self.value = value
    }

    var callCount: Int {
        lock.withLock { count }
    }

    func bytes(count requestedCount: Int) throws -> Data {
        lock.withLock { count += 1 }
        guard value.count == requestedCount else {
            throw TiebaPostingBootstrapError.randomGenerationFailed
        }
        return value
    }
}

private final class LockedFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasReturnedSyncSuccess = false

    func consumeSyncSuccess() -> Bool {
        lock.withLock {
            guard hasReturnedSyncSuccess == false else { return false }
            hasReturnedSyncSuccess = true
            return true
        }
    }
}

private struct PostingBootstrapFixtureResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    static func json(_ value: String) -> Self {
        jsonData(Data(value.utf8))
    }

    static func jsonData(_ data: Data) -> Self {
        Self(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(data.count)"
            ],
            data: data
        )
    }
}

private enum PostingBootstrapFixtureError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class PostingBootstrapURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> PostingBootstrapFixtureResponse
    private static let state = State()

    static var handler: Handler? {
        get { state.handler }
        set { state.handler = newValue }
    }

    static var paths: [String] {
        state.paths
    }

    static var zIDPath: String {
        paths.first(where: { $0.hasPrefix("/c/11/z/") }) ?? ""
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.state.record(path: request.url?.path ?? "")
            let response = try Self.handler?(request) ?? { throw PostingBootstrapFixtureError.missingHandler }()
            let http = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedPaths: [String] = []
        private var storedHandler: Handler?

        var paths: [String] {
            lock.withLock { recordedPaths }
        }

        var handler: Handler? {
            get { lock.withLock { storedHandler } }
            set { lock.withLock { storedHandler = newValue } }
        }

        func record(path: String) {
            lock.withLock { recordedPaths.append(path) }
        }

        func reset() {
            lock.withLock {
                recordedPaths = []
                storedHandler = nil
            }
        }
    }
}
