import Foundation

enum TiebaVideoDownloadError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case badStatus(Int)
    case invalidMIMEType(String?)
    case responseTooLarge(limit: Int)
    case emptyResponse
    case cannotCreateTemporaryFile
}

enum TiebaVideoRemotePolicy {
    static func url(_ value: String?) -> URL? {
        if let value,
           let localURL = URL(string: value),
           SavedThreadMediaAuthorization.shared.allows(localURL),
           isDirectMP4(localURL) {
            return localURL
        }
        guard let url = TiebaURL.video(value), isDirectMP4(url) else { return nil }
        if TiebaRemoteMediaPolicy.allows(url) {
            return url
        }
#if DEBUG
        if isSyntheticFixtureURL(url) {
            return url
        }
#endif
        return nil
    }

    static func allowsNetworkRequest(_ url: URL?) -> Bool {
        guard let url, TiebaRemoteMediaPolicy.allows(url) else { return false }
        return isDirectMP4(url)
    }

    static func isDirectMP4(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mp4"
    }

    static func isSyntheticFixtureURL(_ url: URL) -> Bool {
#if DEBUG
        TiebaImageSourcePolicy.isSyntheticSuccessURL(url)
#else
        false
#endif
    }
}

final class TiebaVideoFileLease: @unchecked Sendable {
    let fileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var isReleased = false
    private let removesFileOnRelease: Bool

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        removesFileOnRelease: Bool = true
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.removesFileOnRelease = removesFileOnRelease
    }

    func release() {
        let shouldRemove = lock.withLock { () -> Bool in
            guard isReleased == false else { return false }
            isReleased = true
            return true
        }
        guard shouldRemove, removesFileOnRelease else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    deinit {
        release()
    }
}

struct TiebaVideoDownloadClient: @unchecked Sendable {
    static let shared = TiebaVideoDownloadClient()
    static let maximumVideoBytes = 200 * 1_024 * 1_024

    let configuration: URLSessionConfiguration
    let maximumBytes: Int
    let temporaryDirectory: URL
    let fileManager: FileManager

    init(
        configuration suppliedConfiguration: URLSessionConfiguration? = nil,
        maximumBytes: Int = TiebaVideoDownloadClient.maximumVideoBytes,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        precondition(maximumBytes > 0)
        let configuration = (suppliedConfiguration ?? .ephemeral).copy()
            as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        self.configuration = configuration
        self.maximumBytes = maximumBytes
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    func download(from sourceURL: URL) async throws -> TiebaVideoFileLease {
        guard let safeURL = TiebaVideoRemotePolicy.url(sourceURL.absoluteString) else {
            throw TiebaVideoDownloadError.invalidURL
        }

        if safeURL.isFileURL {
            guard SavedThreadMediaAuthorization.shared.allows(safeURL) else {
                throw TiebaVideoDownloadError.invalidURL
            }
            return TiebaVideoFileLease(
                fileURL: safeURL,
                fileManager: fileManager,
                removesFileOnRelease: false
            )
        }

        let destinationURL = temporaryDirectory
            .appendingPathComponent("TiebaPureVideo-" + UUID().uuidString, isDirectory: false)
            .appendingPathExtension("mp4")
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw TiebaVideoDownloadError.cannotCreateTemporaryFile
        }

        do {
#if DEBUG
            if TiebaVideoRemotePolicy.isSyntheticFixtureURL(safeURL) {
                return TiebaVideoFileLease(fileURL: destinationURL, fileManager: fileManager)
            }
#endif
            var request = URLRequest(url: safeURL)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("tieba/12.52.1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://tieba.baidu.com/", forHTTPHeaderField: "Referer")

            let operation = try TiebaVideoStreamDownloadOperation(
                configuration: configuration,
                destinationURL: destinationURL,
                maximumBytes: maximumBytes,
                fileManager: fileManager
            )
            return try await withTaskCancellationHandler {
                try await operation.start(request: request)
            } onCancel: {
                operation.cancel()
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            if Task.isCancelled {
                throw CancellationError()
            }
            if let error = error as? URLError, error.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

private final class TiebaVideoStreamDownloadOperation: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private static let acceptedMIMETypes: Set<String> = [
        "video/mp4",
        "video/x-m4v",
        "application/mp4"
    ]

    private let configuration: URLSessionConfiguration
    private let destinationURL: URL
    private let maximumBytes: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var continuation: CheckedContinuation<TiebaVideoFileLease, Error>?
    private var receivedBytes = 0
    private var acceptedResponse = false
    private var isFinished = false
    private var terminalError: Error?

    init(
        configuration: URLSessionConfiguration,
        destinationURL: URL,
        maximumBytes: Int,
        fileManager: FileManager
    ) throws {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.destinationURL = destinationURL
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        fileHandle = try FileHandle(forWritingTo: destinationURL)
        super.init()
    }

    func start(request: URLRequest) async throws -> TiebaVideoFileLease {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isFinished {
                let error = terminalError ?? CancellationError()
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }

            self.continuation = continuation
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        complete(with: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = SecureRemoteRedirectPolicy.allows(
            originalMethod: task.originalRequest?.httpMethod ?? task.currentRequest?.httpMethod,
            destination: request.url,
            scope: .tiebaVideoHTTPS
        )
        completionHandler(allowed ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            try Self.validate(response: response, maximumBytes: maximumBytes)
            lock.lock()
            acceptedResponse = isFinished == false
            let shouldContinue = acceptedResponse
            lock.unlock()
            completionHandler(shouldContinue ? .allow : .cancel)
        } catch {
            completionHandler(.cancel)
            complete(with: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var failure: Error?
        lock.lock()
        if isFinished == false {
            if data.count > maximumBytes - receivedBytes {
                failure = TiebaVideoDownloadError.responseTooLarge(limit: maximumBytes)
            } else {
                do {
                    try fileHandle?.write(contentsOf: data)
                    receivedBytes += data.count
                } catch {
                    failure = error
                }
            }
        }
        lock.unlock()
        if let failure {
            complete(with: failure)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                complete(with: CancellationError())
            } else {
                complete(with: error)
            }
            return
        }

        lock.lock()
        let didAcceptResponse = acceptedResponse
        let byteCount = receivedBytes
        lock.unlock()
        guard didAcceptResponse else {
            complete(with: TiebaVideoDownloadError.invalidResponse)
            return
        }
        guard byteCount > 0 else {
            complete(with: TiebaVideoDownloadError.emptyResponse)
            return
        }
        complete(with: nil)
    }

    private func complete(with error: Error?) {
        lock.lock()
        guard isFinished == false else {
            lock.unlock()
            return
        }
        isFinished = true
        terminalError = error
        let continuation = self.continuation
        self.continuation = nil
        let handle = fileHandle
        fileHandle = nil
        let task = self.task
        self.task = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        task?.cancel()
        try? handle?.close()
        session?.invalidateAndCancel()

        if let error {
            try? fileManager.removeItem(at: destinationURL)
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: TiebaVideoFileLease(
                fileURL: destinationURL,
                fileManager: fileManager
            ))
        }
    }

    deinit {
        cancel()
    }

    private static func validate(response: URLResponse, maximumBytes: Int) throws {
        guard let response = response as? HTTPURLResponse else {
            throw TiebaVideoDownloadError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw TiebaVideoDownloadError.badStatus(response.statusCode)
        }
        let mimeType = response.mimeType?.lowercased()
        guard let mimeType, acceptedMIMETypes.contains(mimeType) else {
            throw TiebaVideoDownloadError.invalidMIMEType(mimeType)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw TiebaVideoDownloadError.responseTooLarge(limit: maximumBytes)
        }
    }
}
