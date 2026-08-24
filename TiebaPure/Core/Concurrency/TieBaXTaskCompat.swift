import Foundation

/// Keeps duration-based delays available on iOS 14, where the clock-based
/// `Task.sleep(for:)` overload is not present yet.
enum TieBaXTaskCompat {
    static func sleep(for duration: Duration) async throws {
        try await Task.sleep(nanoseconds: nanoseconds(for: duration))
    }

    private static func nanoseconds(for duration: Duration) -> UInt64 {
        guard duration > .zero else { return 0 }
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let wholeSeconds = UInt64(seconds)
        let subsecondNanoseconds = UInt64(attoseconds / 1_000_000_000)
        let (scaledSeconds, overflow) = wholeSeconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        guard overflow == false else { return UInt64.max }
        let (total, addOverflow) = scaledSeconds.addingReportingOverflow(subsecondNanoseconds)
        return addOverflow ? UInt64.max : total
    }
}
