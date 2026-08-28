import Foundation

/// A category exposed by the official hot-thread endpoint.  TiebaLite sends
/// the category's `tabCode` back to the same endpoint when the user switches
/// tabs (the initial request uses `all`).
struct HotThreadTab: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let code: String
    let isDefault: Bool
}

enum HotThreadTabPolicy {
    /// Resolves the tab code that should own the feed. The all-channel
    /// response can advertise tabs without returning that tab's thread list.
    static func preferredCode(requestedCode: String, tabs: [HotThreadTab]) -> String {
        let requested = requestedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if requested.isEmpty == false, tabs.contains(where: { $0.code == requested }) {
            return requested
        }
        return tabs.first(where: { $0.isDefault })?.code
            ?? tabs.first?.code
            ?? (requested.isEmpty ? "all" : requested)
    }

    static func fallbackCode(requestedCode: String, tabs: [HotThreadTab]) -> String {
        let requested = requestedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return tabs.first(where: { $0.code != requested && $0.isDefault })?.code
            ?? tabs.first(where: { $0.code != requested })?.code
            ?? preferredCode(requestedCode: requested, tabs: tabs)
    }

    /// The server has occasionally returned the tab metadata without a usable
    /// default flag. These are the stable V11 codes used by TiebaLite; they are
    /// only tried after the requested page is empty, never during normal loads.
    static func fallbackCodes(requestedCode: String, tabs: [HotThreadTab]) -> [String] {
        let requested = requestedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        func append(_ code: String) {
            guard code.isEmpty == false, code != requested, result.contains(code) == false else { return }
            result.append(code)
        }
        append(fallbackCode(requestedCode: requested, tabs: tabs))
        tabs.forEach { append($0.code) }
        ["changgeng", "youxi", "shuma", "shipin"].forEach(append)
        return result
    }
}

/// The three collections returned by hotThreadList.  `topics` is retained for
/// the small topic strip used by TiebaLite; `threads` is the actual 热门 feed.
struct HotThreadFeedPage: Equatable, Sendable {
    let topics: [HotTopicSummary]
    let tabs: [HotThreadTab]
    let threads: [ThreadSummary]
}
