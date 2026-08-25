import Foundation

/// iOS 14 fallback for the async URL loading APIs introduced in iOS 15.
///
/// Newer systems use `URLSession.bytes(for:)` so the caller can enforce
/// response limits while data is arriving. On iOS 14 we use the delegate-free
/// completion-handler API and apply the same limit after the response arrives.
enum TieBaXURLSessionCompat {
    static func data(for request: URLRequest, in session: URLSession) async throws -> (Data, URLResponse) {
        let state = TieBaXURLSessionTaskState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    guard state.beginCompletion() else { return }
                    if let error {
                        if (error as? URLError)?.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let response else {
                        continuation.resume(throwing: TiebaHTTPError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), response))
                }
                state.install(task)
                task.resume()
            }
        }, onCancel: {
            state.cancel()
        })
    }
}

/// Bridges structured-task cancellation to the completion-handler data task
/// without ever resuming its continuation twice when cancellation races the
/// response callback.
private final class TieBaXURLSessionTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var completed = false

    func install(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func beginCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard completed == false else { return false }
        completed = true
        task = nil
        return true
    }
}
