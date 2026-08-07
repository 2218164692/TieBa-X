import Foundation

struct ThreadPage: Equatable, Sendable {
    var thread: ThreadSummary
    var forum: Forum
    var mainPost: Post?
    var posts: [Post]
    var currentPage: Int
    var totalPage: Int
    var hasMore: Bool
    /// Whether the signed-in account has this thread collected, as reported by
    /// the thread page itself — the collection lives on the account only.
    var isCollected: Bool = false
}

enum ThreadReplySort: Int, CaseIterable, Identifiable, Sendable {
    case hot = 2
    case ascending = 0
    case descending = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hot:
            return "热门"
        case .ascending:
            return "正序"
        case .descending:
            return "倒序"
        }
    }
}

struct Post: Identifiable, Equatable, Sendable {
    var id: UInt64
    var threadID: Int64
    var floor: Int
    var author: UserSummary
    var ipAddress: String?
    var createdAt: Date?
    var blocks: [ContentBlock]
    var subpostCount: Int
    var likeCount: Int
    var isLiked: Bool = false
    var previewSubposts: [Subpost]

    var contentPreview: String {
        blocks.compactMap(\.plainText).joined()
    }
}

struct Subpost: Identifiable, Equatable, Sendable {
    var id: UInt64
    var floor: Int
    var author: UserSummary
    var ipAddress: String?
    var blocks: [ContentBlock]
    var createdAt: Date?
    var likeCount: Int
    var isLiked: Bool = false
}

enum TiebaLikeObjectType: Int, Equatable, Sendable {
    case thread = 3
    case post = 1
    case subpost = 2
}
