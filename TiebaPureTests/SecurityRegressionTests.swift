import SwiftProtobuf
import XCTest
@testable import TiebaPure

final class SecurityRegressionTests: XCTestCase {
    override func tearDown() {
        SecurityURLProtocol.payload = Data()
        SecurityURLProtocol.chunks = nil
        SecurityURLProtocol.mimeType = "application/octet-stream"
        SecurityURLProtocol.delay = 0
        SecurityURLProtocol.chunkDelay = 0
        SecurityURLProtocol.declaredContentLength = nil
        super.tearDown()
    }

    func testKeychainUpdatesExistingItemWithoutDeleteFirst() async throws {
        let service = KeychainAccountStoreService(
            service: "dev.infinityf4p.tiebapure.tests.\(UUID().uuidString)",
            account: "update"
        )
        try? await service.clearData()
        try await service.saveData(Data("first".utf8))
        try await service.saveData(Data("second".utf8))
        let loaded = try await service.loadData()
        XCTAssertEqual(loaded, Data("second".utf8))
        try await service.clearData()
    }

    func testAccountEncodingDoesNotPersistCompleteCookieField() throws {
        let account = FixtureTiebaAPI.account
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(account), encoding: .utf8))
        XCTAssertFalse(json.contains("\"cookie\""))
        XCTAssertFalse(json.contains("Cookie:"))
    }

    @MainActor
    func testCancellationDuringAccountSaveRollsBackWithoutPublishingLogin() async throws {
        let service = ControlledSaveAccountStoreService()
        let store = AccountStore(service: service)
        var publishedAccounts: [Account] = []
        let observation = store.accountDidChange.compactMap { $0 }.sink {
            publishedAccounts.append($0)
        }

        let saveTask = Task {
            try await store.save(FixtureTiebaAPI.account)
        }
        for _ in 0..<200 {
            if await service.hasPendingSave() { break }
            await Task.yield()
        }
        let didStartSaving = await service.hasPendingSave()
        XCTAssertTrue(didStartSaving)

        saveTask.cancel()
        await service.finishPendingSave()
        do {
            try await saveTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        let persisted = try await store.load()
        XCTAssertNil(persisted)
        XCTAssertTrue(publishedAccounts.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testPublishedLoginRemainsSavedWhenSheetDismissalCancelsValidationTask() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        var saveTask: Task<Void, Error>?
        let observation = store.accountDidChange.sink { account in
            if account != nil {
                saveTask?.cancel()
            }
        }

        saveTask = Task {
            try await store.save(FixtureTiebaAPI.account)
        }
        try await saveTask?.value

        let persistedAccount = try await store.load()
        XCTAssertEqual(persistedAccount, FixtureTiebaAPI.account)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testCancelledSaveNeverRestoresUnsafePreviousCredentials() async throws {
        var unsafeAccount = FixtureTiebaAPI.account
        unsafeAccount.stoken = "unsafe; INJECTED=true"
        let service = ControlledSaveAccountStoreService(
            data: try JSONEncoder().encode(unsafeAccount)
        )
        let store = AccountStore(service: service)

        let saveTask = Task {
            try await store.save(FixtureTiebaAPI.account)
        }
        for _ in 0..<200 {
            if await service.hasPendingSave() { break }
            await Task.yield()
        }
        let didStartSaving = await service.hasPendingSave()
        XCTAssertTrue(didStartSaving)

        saveTask.cancel()
        await service.finishPendingSave()
        do {
            try await saveTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        let remainingData = try await service.loadData()
        XCTAssertNil(remainingData)
    }

    func testBoundedResponseRejectsDeclaredOverflow() async throws {
        SecurityURLProtocol.payload = Data(repeating: 0x41, count: 9)
        SecurityURLProtocol.declaredContentLength = 9
        let loader = BoundedURLSession(session: Self.session())
        do {
            _ = try await loader.data(for: URLRequest(url: URL(string: "https://example.com/large")!), maximumBytes: 8)
            XCTFail("Expected response cap")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: 8))
        }
    }

    func testBoundedResponseRejectsAccumulatedOverflowWithoutDeclaredLength() async throws {
        SecurityURLProtocol.payload = Data(repeating: 0x41, count: 64 * 1_024)
        SecurityURLProtocol.declaredContentLength = nil
        let loader = BoundedURLSession(session: Self.session())
        do {
            _ = try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/chunked")!),
                maximumBytes: 8
            )
            XCTFail("Expected streamed response cap")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: 8))
        }
    }

    func testBoundedResponseReportsMonotonicProgressForChunkedResponse() async throws {
        let chunkSize = 64 * 1_024
        SecurityURLProtocol.chunks = [
            Data(repeating: 0x41, count: chunkSize),
            Data(repeating: 0x42, count: chunkSize),
            Data(repeating: 0x43, count: chunkSize)
        ]
        SecurityURLProtocol.declaredContentLength = chunkSize * 3
        SecurityURLProtocol.chunkDelay = 0.02
        let recorder = ProgressRecorder()
        let loader = BoundedURLSession(session: Self.session())

        let (data, _) = try await loader.data(
            for: URLRequest(url: URL(string: "https://example.com/progress")!),
            maximumBytes: chunkSize * 4,
            onProgress: { progress in
                await recorder.record(progress)
            }
        )

        let progress = await recorder.values()
        XCTAssertEqual(data.count, chunkSize * 3)
        XCTAssertEqual(progress.first, .init(receivedBytes: 0, expectedBytes: chunkSize * 3))
        XCTAssertEqual(progress.last, .init(receivedBytes: chunkSize * 3, expectedBytes: chunkSize * 3))
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy {
            $0.receivedBytes <= $1.receivedBytes
        })
        XCTAssertTrue(progress.allSatisfy { $0.expectedBytes == chunkSize * 3 })
    }

    func testBoundedResponseDoesNotReportProgressPastStreamedLimit() async throws {
        let chunkSize = 64 * 1_024
        SecurityURLProtocol.chunks = [
            Data(repeating: 0x41, count: chunkSize),
            Data(repeating: 0x42, count: chunkSize)
        ]
        SecurityURLProtocol.declaredContentLength = nil
        SecurityURLProtocol.chunkDelay = 0.02
        let recorder = ProgressRecorder()
        let loader = BoundedURLSession(session: Self.session())
        let limit = 100_000

        do {
            _ = try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/progress-overflow")!),
                maximumBytes: limit,
                onProgress: { progress in
                    await recorder.record(progress)
                }
            )
            XCTFail("Expected streamed response cap")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: limit))
        }

        let progress = await recorder.values()
        XCTAssertEqual(progress.first?.receivedBytes, 0)
        XCTAssertTrue(progress.allSatisfy { $0.receivedBytes <= limit })
        XCTAssertEqual(progress.last?.receivedBytes, chunkSize)
    }

    func testBoundedResponseCancellationStopsFurtherProgressUpdates() async throws {
        let chunkSize = 64 * 1_024
        SecurityURLProtocol.chunks = [
            Data(repeating: 0x41, count: chunkSize),
            Data(repeating: 0x42, count: chunkSize),
            Data(repeating: 0x43, count: chunkSize)
        ]
        SecurityURLProtocol.declaredContentLength = chunkSize * 3
        SecurityURLProtocol.chunkDelay = 0.25
        let recorder = ProgressRecorder()
        let loader = BoundedURLSession(session: Self.session())
        let task = Task {
            try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/progress-cancel")!),
                maximumBytes: chunkSize * 4,
                onProgress: { progress in
                    await recorder.record(progress)
                }
            )
        }

        await recorder.waitForPositiveProgress()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let progressAtCancellation = await recorder.values()
        try await Task.sleep(nanoseconds: 600_000_000)
        let progressAfterCancellation = await recorder.values()
        XCTAssertEqual(progressAfterCancellation, progressAtCancellation)
    }

    func testImageMIMEValidationRejectsNonImageResponse() async throws {
        SecurityURLProtocol.payload = Data("not an image".utf8)
        SecurityURLProtocol.mimeType = "text/html"
        let loader = BoundedURLSession(session: Self.session())
        do {
            _ = try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/image")!),
                maximumBytes: 100,
                requiredMIMEPrefix: "image/"
            )
            XCTFail("Expected MIME rejection")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .invalidMIMEType("text/html"))
        }
    }

    func testImageDecodePolicyRejectsPixelBombDimensions() {
        XCTAssertTrue(TiebaImageDecodePolicy.allows(width: 4_096, height: 4_096))
        XCTAssertFalse(TiebaImageDecodePolicy.allows(width: 100_000, height: 1))
        XCTAssertFalse(TiebaImageDecodePolicy.allows(width: 20_000, height: 20_000))
        XCTAssertFalse(TiebaImageDecodePolicy.allows(width: Int.max, height: 2))
    }

    func testImageDownloadValidatesDataAndUsesDetectedFileType() async throws {
        SecurityURLProtocol.payload = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        SecurityURLProtocol.mimeType = "image/png"
        let client = TiebaImageDownloadClient(session: Self.session())
        let url = try XCTUnwrap(URL(string: "https://example.com/original.jpg"))

        let payload = try await client.download(from: url)

        XCTAssertEqual(payload.data, SecurityURLProtocol.payload)
        XCTAssertEqual(payload.mimeType, "image/png")
        XCTAssertEqual(payload.fileName, "original.png")
    }

    func testImageDownloadUpgradesInsecureSourceAndStillRejectsPrivateTargets() async throws {
        SecurityURLProtocol.payload = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        SecurityURLProtocol.mimeType = "image/png"
        let client = TiebaImageDownloadClient(session: Self.session())
        let url = try XCTUnwrap(URL(string: "http://example.com/original.jpg"))

        // A legacy http source is upgraded to https instead of being dropped;
        // nothing is ever fetched over plain http.
        let payload = try await client.download(from: url)
        XCTAssertEqual(payload.data, SecurityURLProtocol.payload)
        XCTAssertEqual(SecurityURLProtocol.lastRequestURL?.scheme, "https")

        for rejected in ["http://127.0.0.1/original.jpg", "file:///tmp/original.jpg"] {
            let rejectedURL = try XCTUnwrap(URL(string: rejected))
            do {
                _ = try await client.download(from: rejectedURL)
                XCTFail("Expected rejection for \(rejected)")
            } catch {
                XCTAssertEqual(error as? TiebaImageDownloadError, .invalidURL)
            }
        }
    }

    func testRequestBuilderRejectsOverflowingRemoteIdentifiersAndPages() async throws {
        let api = TiebaAPI(client: TiebaHTTPClient(session: Self.session()))

        do {
            _ = try await api.threadPage(
                account: nil,
                threadID: 1,
                page: 1,
                postID: UInt64.max
            )
            XCTFail("Expected overflowing post identifier rejection")
        } catch {
            XCTAssertEqual(
                error as? TiebaRequestValidationError,
                .invalidIdentifier(UInt64.max)
            )
        }

        do {
            _ = try await api.personalizedThreads(account: nil, page: -1, loadType: 1)
            XCTFail("Expected invalid page rejection")
        } catch {
            XCTAssertEqual(error as? TiebaRequestValidationError, .invalidPage(-1))
        }
    }

    func testBoundedResponsePropagatesCancellation() async throws {
        SecurityURLProtocol.payload = Data("late".utf8)
        SecurityURLProtocol.delay = 2
        let loader = BoundedURLSession(session: Self.session())
        let task = Task {
            try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/slow")!),
                maximumBytes: 100
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            return
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testBusinessErrorsAndExpiredSessionAreDistinct() throws {
        XCTAssertNoThrow(try TiebaResponseValidator.validate(code: 0, message: ""))
        XCTAssertThrowsError(try TiebaResponseValidator.validate(code: 12, message: "业务错误")) {
            XCTAssertEqual($0 as? TiebaAPIError, .response(code: 12, message: "业务错误"))
        }
        XCTAssertThrowsError(try TiebaResponseValidator.validate(code: 110001, message: "登录失效")) {
            XCTAssertEqual($0 as? TiebaAPIError, .sessionExpired(code: 110001, message: "登录失效"))
        }
    }

    func testForumFallbackOnlyAcceptsDecodeIncompatibility() {
        let decodingError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "fixture"))
        XCTAssertTrue(TiebaAPI.shouldFallbackFromForumProtobuf(decodingError))
        XCTAssertTrue(TiebaAPI.shouldFallbackFromForumProtobuf(BinaryDecodingError.truncated))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(URLError(.notConnectedToInternet)))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(CancellationError()))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(TiebaAPIError.response(code: 1, message: "业务错误")))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(TiebaAPIError.emptyResponse))
    }

    @MainActor
    func testLogoutFailureKeepsStoredAccount() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(FixtureTiebaAPI.account)
        let coordinator = LogoutCoordinator(accountStore: store, artifactCleaner: FailingArtifactCleaner())

        do {
            try await coordinator.logOut()
            XCTFail("Expected logout failure")
        } catch {
            let persisted = try await store.load()
            XCTAssertEqual(persisted, FixtureTiebaAPI.account)
        }
    }

    @MainActor
    func testCompleteLogoutClearsAccountAfterArtifacts() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(FixtureTiebaAPI.account)
        let cleaner = RecordingArtifactCleaner()
        let coordinator = LogoutCoordinator(accountStore: store, artifactCleaner: cleaner)

        try await coordinator.logOut()
        let persisted = try await store.load()
        XCTAssertNil(persisted)
        XCTAssertTrue(cleaner.didClear)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SecurityURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private struct FailingArtifactCleaner: SessionArtifactCleaning {
    func clear() async throws { throw URLError(.cannotRemoveFile) }
}

@MainActor
private final class RecordingArtifactCleaner: SessionArtifactCleaning {
    private(set) var didClear = false
    func clear() async throws { didClear = true }
}

private final class SecurityURLProtocol: URLProtocol {
    static var payload = Data()
    static var chunks: [Data]?
    static var mimeType = "application/octet-stream"
    static var delay: TimeInterval = 0
    static var chunkDelay: TimeInterval = 0
    static var declaredContentLength: Int?
    static var lastRequestURL: URL?
    private let stateLock = NSLock()
    private var workItems: [DispatchWorkItem] = []
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestURL = request.url
        let payload = Self.payload
        let chunks = Self.chunks ?? [payload]
        let mimeType = Self.mimeType
        let declaredContentLength = Self.declaredContentLength
        let chunkDelay = Self.chunkDelay
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, let url = self.request.url else { return }
            var headers = ["Content-Type": Self.mimeType]
            headers["Content-Type"] = mimeType
            if let declaredContentLength {
                headers["Content-Length"] = "\(declaredContentLength)"
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for (index, chunk) in chunks.enumerated() {
                let chunkItem = DispatchWorkItem { [weak self] in
                    guard let self, self.isActive else { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                    if index == chunks.indices.last {
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                }
                self.schedule(chunkItem, after: chunkDelay * Double(index))
            }
        }
        schedule(item, after: Self.delay)
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let items = workItems
        workItems.removeAll()
        stateLock.unlock()
        items.forEach { $0.cancel() }
    }

    private var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped == false
    }

    private func schedule(_ item: DispatchWorkItem, after delay: TimeInterval) {
        stateLock.lock()
        let shouldSchedule = stopped == false
        if shouldSchedule {
            workItems.append(item)
        }
        stateLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }
}

private actor ProgressRecorder {
    private var progress: [BoundedURLSessionProgress] = []
    private var positiveProgressWaiters: [CheckedContinuation<Void, Never>] = []

    func record(_ value: BoundedURLSessionProgress) {
        progress.append(value)
        guard value.receivedBytes > 0 else { return }
        let waiters = positiveProgressWaiters
        positiveProgressWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func values() -> [BoundedURLSessionProgress] {
        progress
    }

    func waitForPositiveProgress() async {
        guard progress.contains(where: { $0.receivedBytes > 0 }) == false else { return }
        await withCheckedContinuation { continuation in
            positiveProgressWaiters.append(continuation)
        }
    }
}

private actor ControlledSaveAccountStoreService: AccountStoreService {
    private var data: Data?
    private var pendingSave: (data: Data, continuation: CheckedContinuation<Void, Never>)?

    init(data: Data? = nil) {
        self.data = data
    }

    func loadData() async throws -> Data? { data }

    func saveData(_ data: Data) async throws {
        await withCheckedContinuation { continuation in
            pendingSave = (data, continuation)
        }
        self.data = data
    }

    func clearData() async throws {
        data = nil
    }

    func hasPendingSave() -> Bool {
        pendingSave != nil
    }

    func finishPendingSave() {
        guard let pendingSave else { return }
        self.pendingSave = nil
        pendingSave.continuation.resume()
    }
}
