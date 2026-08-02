import Foundation

enum TiebaEndpoint {
    static let base = URL(string: "https://tieba.baidu.com")!
    static let appBase = URL(string: "https://c.tieba.baidu.com")!
    static let protobufBase = URL(string: "https://tiebac.baidu.com")!
    static let socialBase = URL(string: "https://tiebac.baidu.com")!

    case login
    case initNickname
    case webMyInfo
    case followedForums
    case forumPageForm
    case personalized
    case frsPage
    case pbPage
    case pbFloor
    case searchThread
    case searchUser
    case userProfile
    case userThreads
    case followUser
    case unfollowUser
    case followedUsers
    case followers
    case resolveForumID
    case forumMembership
    case followForum
    case unfollowForum
    case agreePost
    case addThread
    case addPost
    case uploadPicture

    var url: URL {
        switch self {
        case .login:
            return Self.appBase.appending(path: "/c/s/login")
        case .initNickname:
            return Self.appBase.appending(path: "/c/s/initNickname")
        case .webMyInfo:
            return Self.base.appending(path: "/mo/q/newmoindex")
        case .followedForums:
            return Self.appBase.appending(path: "/c/f/forum/getforumlist")
        case .forumPageForm:
            return Self.appBase.appending(path: "/c/f/frs/page")
        case .personalized:
            return Self.base
                .appending(path: "/c/f/excellent/personalized")
                .appending(queryItems: [.init(name: "cmd", value: "309264")])
        case .frsPage:
            return Self.base
                .appending(path: "/c/f/frs/page")
                .appending(queryItems: [.init(name: "cmd", value: "301001")])
        case .pbPage:
            return Self.base
                .appending(path: "/c/f/pb/page")
                .appending(queryItems: [
                    .init(name: "cmd", value: "302001"),
                    .init(name: "format", value: "protobuf")
                ])
        case .pbFloor:
            return Self.base
                .appending(path: "/c/f/pb/floor")
                .appending(queryItems: [
                    .init(name: "cmd", value: "302002"),
                    .init(name: "format", value: "protobuf")
                ])
        case .searchThread:
            return Self.base.appending(path: "/mo/q/search/thread")
        case .searchUser:
            return Self.base.appending(path: "/mo/q/search/user")
        case .userProfile:
            return Self.protobufBase
                .appending(path: "/c/u/user/profile")
                .appending(queryItems: [
                    .init(name: "cmd", value: "303012"),
                    .init(name: "format", value: "protobuf")
                ])
        case .userThreads:
            return Self.protobufBase
                .appending(path: "/c/u/feed/userpost")
                .appending(queryItems: [
                    .init(name: "cmd", value: "303002"),
                    .init(name: "format", value: "protobuf")
                ])
        case .followUser:
            return Self.socialBase.appending(path: "/c/c/user/follow")
        case .unfollowUser:
            return Self.socialBase.appending(path: "/c/c/user/unfollow")
        case .followedUsers:
            return Self.socialBase.appending(path: "/c/u/follow/followList")
        case .followers:
            return Self.socialBase.appending(path: "/c/u/fans/page")
        case .resolveForumID:
            return Self.base.appending(path: "/f/commit/share/fnameShareApi")
        case .forumMembership:
            return Self.socialBase.appending(path: "/c/f/forum/getUserForumLevelInfo")
        case .followForum:
            return Self.socialBase.appending(path: "/c/c/forum/like")
        case .unfollowForum:
            return Self.socialBase.appending(path: "/c/c/forum/unfavolike")
        case .agreePost:
            return Self.socialBase.appending(path: "/c/c/agree/opAgree")
        case .addThread:
            return Self.protobufBase
                .appending(path: "/c/c/thread/add")
                .appending(queryItems: [
                    .init(name: "cmd", value: "309730"),
                    .init(name: "format", value: "protobuf")
                ])
        case .addPost:
            return Self.protobufBase
                .appending(path: "/c/c/post/add")
                .appending(queryItems: [
                    .init(name: "cmd", value: "309731"),
                    .init(name: "format", value: "protobuf")
                ])
        case .uploadPicture:
            return Self.protobufBase.appending(path: "/c/s/uploadPicture")
        }
    }
}
