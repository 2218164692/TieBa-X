import Foundation

/// A forum returned by Baidu's directory search.  Keep this separate from
/// `Forum` so the search result can carry the short introduction and concern
/// state without changing the reader's stable forum model.
struct SearchForumResult: Identifiable, Equatable, Sendable {
    let forum: Forum
    let introduction: String
    let isFollowed: Bool

    var id: String {
        if forum.id > 0 { return "id-\(forum.id)" }
        return "name-\(forum.name)"
    }
}

struct SearchForumsPage: Equatable, Sendable {
    var results: [SearchForumResult]
    var currentPage: Int
    var hasMore: Bool
}

struct SearchUserResult: Identifiable, Equatable, Sendable {
    let user: UserSummary
    let introduction: String
    let followerCount: Int
    let isFollowed: Bool

    var id: String { "\(user.id)-\(user.name)" }
}

struct SearchUsersPage: Equatable, Sendable {
    var results: [SearchUserResult]
    var currentPage: Int
    var hasMore: Bool
}
