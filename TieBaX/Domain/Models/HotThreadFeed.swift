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

/// The three collections returned by hotThreadList.  `topics` is retained for
/// the small topic strip used by TiebaLite; `threads` is the actual 热门 feed.
struct HotThreadFeedPage: Equatable, Sendable {
    let topics: [HotTopicSummary]
    let tabs: [HotThreadTab]
    let threads: [ThreadSummary]
}
