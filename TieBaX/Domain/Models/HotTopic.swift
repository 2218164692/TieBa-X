import Foundation

struct HotTopicSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    /// TiebaLite uses 1 for “新” and 2 for “热”. The server may omit this
    /// field, so zero means that no badge should be shown.
    let tag: Int
    let discussCount: Int
    let imageURL: URL?

    init(
        id: String,
        name: String,
        description: String,
        tag: Int = 0,
        discussCount: Int = 0,
        imageURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.tag = tag
        self.discussCount = discussCount
        self.imageURL = imageURL
    }

    var badgeTitle: String? {
        switch tag {
        case 2: return "热"
        case 1: return "新"
        default: return nil
        }
    }
}
/// A page returned by the public hot-topic detail endpoint. The detail page
/// uses the same ThreadSummary model as the hot board so opening a topic does
/// not fork the post renderer or navigation behaviour.
struct HotTopicDetailPage: Equatable, Sendable {
    let topic: HotTopicSummary
    let threads: [ThreadSummary]
    let currentPage: Int
    let hasMore: Bool
    let lastID: String
}
