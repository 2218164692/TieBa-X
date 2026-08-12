import Foundation

struct ThreadPage: Equatable, Sendable {
    var thread: ThreadSummary
    var forum: Forum
    var mainPost: Post?
    var posts: [Post]
    var currentPage: Int
    var totalPage: Int
    var hasMore: Bool
    /// The service omitted the complete first floor, so the main post shown
    /// here comes from the already-visible list summary.
    var mainPostIsSummaryFallback: Bool = false
    /// Whether the signed-in account has this thread collected, as reported by
    /// the thread page itself — the collection lives on the account only.
    var isCollected: Bool = false
}

struct ThreadMainPostFallback: Equatable, Hashable, Sendable {
    let threadID: Int64
    let postID: UInt64?
    let author: UserSummary
    let createdAt: Date?
    let blocks: [ContentBlock]
    let likeCount: Int
    let isLiked: Bool

    init?(thread: ThreadSummary) {
        guard thread.blocks.isEmpty == false else { return nil }
        threadID = thread.id
        postID = thread.firstPostID
        author = thread.author
        createdAt = thread.createdAt
        blocks = thread.blocks
        likeCount = thread.likeCount
        isLiked = thread.isLiked
    }

    func post(for requestedThreadID: Int64) -> Post? {
        guard requestedThreadID == threadID, blocks.isEmpty == false else { return nil }
        return Post(
            id: postID ?? 0,
            threadID: threadID,
            floor: 1,
            author: author,
            ipAddress: author.ipAddress,
            createdAt: createdAt,
            blocks: blocks,
            subpostCount: 0,
            likeCount: likeCount,
            isLiked: isLiked,
            previewSubposts: []
        )
    }

    func hash(into hasher: inout Hasher) {
        // Route identity only needs stable source identity. Unequal summaries
        // may share a hash; Equatable still compares their complete content.
        hasher.combine(threadID)
        hasher.combine(postID)
        hasher.combine(author)
        hasher.combine(createdAt)
        hasher.combine(blocks.count)
    }
}

enum ThreadPageMainPostPolicy {
    static func mainPost(in page: ThreadPage) -> Post? {
        page.mainPost ?? page.posts.first { $0.floor == 1 }
    }

    static func needsFirstPageRecovery(_ page: ThreadPage, requestedPage: Int) -> Bool {
        requestedPage == 1
            && mainPost(in: page) == nil
    }

    static func merging(
        _ incoming: ThreadPage,
        previousMainPost: Post?,
        previousMainPostIsSummaryFallback: Bool = false,
        requestedPage: Int
    ) -> ThreadPage {
        var merged = incoming
        if let incomingMainPost = mainPost(in: incoming) {
            merged.mainPost = incomingMainPost
        } else if let previousMainPost {
            // A refresh or pagination response must not erase a main post the
            // reader has already displayed just because one response omits it.
            merged.mainPost = previousMainPost
            merged.mainPostIsSummaryFallback = previousMainPostIsSummaryFallback
        }
        return merged
    }

    static func applyingFallback(
        _ fallback: ThreadMainPostFallback?,
        to page: ThreadPage,
        threadID: Int64
    ) -> ThreadPage {
        guard mainPost(in: page) == nil,
              let fallbackPost = fallback?.post(for: threadID) else { return page }
        var resolved = page
        resolved.mainPost = fallbackPost
        resolved.mainPostIsSummaryFallback = true
        return resolved
    }
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
