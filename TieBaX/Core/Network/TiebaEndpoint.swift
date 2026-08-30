import Foundation

enum TiebaEndpoint {
    static let base = URL(string: "https://tieba.baidu.com")!
    static let appBase = URL(string: "https://c.tieba.baidu.com")!
    static let protobufBase = URL(string: "https://tiebac.baidu.com")!
    static let socialBase = URL(string: "https://tiebac.baidu.com")!

    case login
    case postingLogin
    case initNickname
    case webMyInfo
    case followedForums
    case userFollowedForums
    case forumPageForm
    case personalized
    case frsPage
    case pbPage
    case pbFloor
    case searchForum
    case searchThread
    case searchUser
    case hotMessageList
    case sync
    case hotThreadList
    case hotTopicDetail
    case userProfile
    case userThreads
    case modifyProfile
    case deleteOwnThread
    case followUser
    case unfollowUser
    case followedUsers
    case followers
    case resolveForumID
    case forumMembership
    case followForum
    case unfollowForum
    case signForum
    case threadStoreList
    case addThreadStore
    case removeThreadStore
    case agreePost
    case webAddThread
    case webAddPost(timestamp: Int64)
    case webUploadPicture(nonce: String)
    case addPost
    case uploadPicture

    var url: URL {
        switch self {
        case .login:
            return Self.appBase.tieBaAppendingPath("/c/s/login")
        case .postingLogin:
            return Self.protobufBase.tieBaAppendingPath("/c/s/login")
        case .initNickname:
            return Self.appBase.tieBaAppendingPath("/c/s/initNickname")
        case .webMyInfo:
            return Self.base.tieBaAppendingPath("/mo/q/newmoindex")
        case .followedForums:
            return Self.appBase.tieBaAppendingPath("/c/f/forum/getforumlist")
        case .userFollowedForums:
            return Self.appBase.tieBaAppendingPath("/c/f/forum/like")
        case .forumPageForm:
            return Self.appBase.tieBaAppendingPath("/c/f/frs/page")
        case .personalized:
            return Self.base
                .tieBaAppendingPath("/c/f/excellent/personalized")
                .tieBaAppendingQueryItems([.init(name: "cmd", value: "309264")])
        case .frsPage:
            return Self.base
                .tieBaAppendingPath("/c/f/frs/page")
                .tieBaAppendingQueryItems([.init(name: "cmd", value: "301001")])
        case .pbPage:
            return Self.base
                .tieBaAppendingPath("/c/f/pb/page")
                .tieBaAppendingQueryItems([
                    .init(name: "cmd", value: "302001"),
                    .init(name: "format", value: "protobuf")
                ])
        case .pbFloor:
            return Self.base
                .tieBaAppendingPath("/c/f/pb/floor")
                .tieBaAppendingQueryItems([
                    .init(name: "cmd", value: "302002"),
                    .init(name: "format", value: "protobuf")
                ])
        case .searchForum:
            return Self.base.tieBaAppendingPath("/mo/q/search/forum")
        case .searchThread:
            return Self.base.tieBaAppendingPath("/mo/q/search/thread")
        case .searchUser:
            return Self.base.tieBaAppendingPath("/mo/q/search/user")
        case .hotMessageList:
            return Self.base
                .tieBaAppendingPath("/mo/q/hotMessage/list")
                .tieBaAppendingQueryItems([.init(name: "fr", value: "newwise")])
        case .sync:
            return Self.protobufBase.tieBaAppendingPath("/c/s/sync")
        case .hotThreadList:
            return Self.protobufBase
                .tieBaAppendingPath("/c/f/forum/hotThreadList")
                .tieBaAppendingQueryItems([.init(name: "cmd", value: "309661")])
        case .hotTopicDetail:
            return Self.base.tieBaAppendingPath("/mo/q/newtopic/topicDetail")
        case .userProfile:
            return Self.protobufBase
                .tieBaAppendingPath("/c/u/user/profile")
                .tieBaAppendingQueryItems([
                    .init(name: "cmd", value: "303012"),
                    .init(name: "format", value: "protobuf")
                ])
        case .userThreads:
            return Self.protobufBase
                .tieBaAppendingPath("/c/u/feed/userpost")
                .tieBaAppendingQueryItems([
                    .init(name: "cmd", value: "303002"),
                    .init(name: "format", value: "protobuf")
                ])
        case .modifyProfile:
            return Self.socialBase.tieBaAppendingPath("/c/c/profile/modify")
        case .deleteOwnThread:
            return Self.appBase.tieBaAppendingPath("/c/c/bawu/delthread")
        case .followUser:
            return Self.socialBase.tieBaAppendingPath("/c/c/user/follow")
        case .unfollowUser:
            return Self.socialBase.tieBaAppendingPath("/c/c/user/unfollow")
        case .followedUsers:
            return Self.socialBase.tieBaAppendingPath("/c/u/follow/followList")
        case .followers:
            return Self.socialBase.tieBaAppendingPath("/c/u/fans/page")
        case .resolveForumID:
            // The www host answers this path with a 301 down to plain http,
            // which the client refuses to follow; the app host serves the same
            // JSON over https.
            return Self.appBase.tieBaAppendingPath("/f/commit/share/fnameShareApi")
        case .forumMembership:
            return Self.socialBase.tieBaAppendingPath("/c/f/forum/getUserForumLevelInfo")
        case .followForum:
            return Self.socialBase.tieBaAppendingPath("/c/c/forum/like")
        case .unfollowForum:
            return Self.socialBase.tieBaAppendingPath("/c/c/forum/unfavolike")
        case .signForum:
            return Self.appBase.tieBaAppendingPath("/c/c/forum/sign")
        case .threadStoreList:
            return Self.appBase.tieBaAppendingPath("/c/u/feed/threadStoreList")
        case .addThreadStore:
            return Self.appBase.tieBaAppendingPath("/c/c/post/addstore")
        case .removeThreadStore:
            return Self.appBase.tieBaAppendingPath("/c/c/post/rmstore")
        case .agreePost:
            return Self.socialBase.tieBaAppendingPath("/c/c/agree/opAgree")
        case .webAddThread:
            return Self.base.tieBaAppendingPath("/f/commit/thread/add")
        case let .webAddPost(timestamp):
            return Self.base
                .tieBaAppendingPath("/mo/q/apubpost")
                .tieBaAppendingQueryItems([.init(name: "_t", value: String(timestamp))])
        case let .webUploadPicture(nonce):
            return Self.base
                .tieBaAppendingPath("/mo/q/cooluploadpic")
                .tieBaAppendingQueryItems([
                    .init(name: "type", value: "ajax"),
                    .init(name: "r", value: nonce)
                ])
        case .addPost:
            return Self.protobufBase
                .tieBaAppendingPath("/c/c/post/add")
                .tieBaAppendingQueryItems([.init(name: "cmd", value: "309731")])
        case .uploadPicture:
            return Self.protobufBase.tieBaAppendingPath("/c/s/uploadPicture")
        }
    }
}
