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
    /// TiebaLite always renders a local 总榜 entry, even when the server
    /// only sends metadata for the category tabs.
    static let totalTab = HotThreadTab(id: "all", title: "总榜", code: "all", isDefault: true)

    /// Returns a stable, de-duplicated tab list with 总榜 first. Server
    /// metadata is retained for all other categories.
    static func normalizedTabs(_ tabs: [HotThreadTab]) -> [HotThreadTab] {
        var result = [totalTab]
        var seen = Set([totalTab.code])
        for tab in tabs {
            let code = tab.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code.isEmpty == false, seen.insert(code).inserted else { continue }
            let title = normalizedTitle(tab.title, code: code)
            result.append(HotThreadTab(id: code, title: title, code: code, isDefault: false))
        }
        return result
    }

    private static func normalizedTitle(_ title: String, code: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == "all" { return totalTab.title }
        if trimmed.isEmpty || trimmed == "热门" || trimmed == "全部" {
            switch code.lowercased() {
            case "shipin", "video": return "视频"
            case "changgeng", "longer": return "长更"
            case "youxi", "game": return "游戏"
            case "shuma", "digital": return "数码"
            default: return trimmed.isEmpty ? code : trimmed
            }
        }
        return trimmed
    }
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

/// The three collections returned by hotThreadList. `topics` powers the
/// numbered 话题榜 and `threads` is the selected ranked 热榜 feed.
struct HotThreadFeedPage: Equatable, Sendable {
    let topics: [HotTopicSummary]
    /// Raw server tab metadata. A category refresh may omit this collection;
    /// the view then keeps the initial tab list, just like TiebaLite.
    let tabs: [HotThreadTab]
    let threads: [ThreadSummary]
}
