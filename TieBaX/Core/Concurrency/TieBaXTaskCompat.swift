import Foundation

/// Keeps duration-based delays available on iOS 14, where the clock-based
/// `Task.sleep(for:)` overload is not present yet. TimeInterval is used here
/// instead of Swift's `Duration`, whose API is not available on the minimum OS.
enum TieBaXTaskCompat {
    static func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let nanoseconds = seconds >= Double(UInt64.max) / 1_000_000_000
            ? UInt64.max
            : UInt64((seconds * 1_000_000_000).rounded(.up))
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
