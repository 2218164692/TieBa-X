import Foundation

struct ForumThreadsRequestKey: Equatable, Sendable {
    let accountID: String?
    let forumID: Int64
    let forumName: String
    let category: ForumThreadCategory
    let page: Int
}
