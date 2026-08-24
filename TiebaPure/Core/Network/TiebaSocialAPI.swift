import Foundation

enum TiebaMutationError: Error, Equatable, CustomStringConvertible {
    case missingTBS
    case invalidThreadID
    case invalidPostID
    case invalidUserID
    case invalidForumID

    var description: String {
        switch self {
        case .missingTBS:
            return "未能刷新登录校验信息，请重新登录后再试。"
        case .invalidThreadID:
            return "帖子 ID 无效，无法完成操作。"
        case .invalidPostID:
            return "回复 ID 无效，无法完成操作。"
        case .invalidUserID:
            return "用户 ID 无效，无法加载关系列表。"
        case .invalidForumID:
            return "未能确认贴吧 ID，无法修改关注状态。"
        }
    }
}

enum TiebaSocialRequestFactory {
    static func userRelationshipFields(
        account: Account?,
        userID: Int64,
        page: Int
    ) throws -> [String: String] {
        guard userID > 0 else { throw TiebaMutationError.invalidUserID }
        let requestedPage = try TieBaXRequestPolicy.signedPage(page)
        return [
            "BDUSS": account?.bduss ?? "",
            "_client_version": TieBaXRequestPolicy.socialClientVersion,
            "pn": "\(requestedPage)",
            "uid": "\(userID)"
        ]
    }

    static func forumMembershipFields(account: Account, forumID: Int64) throws -> [String: String] {
        guard forumID > 0 else { throw TiebaMutationError.invalidForumID }
        return [
            "BDUSS": account.bduss,
            "_client_version": TieBaXRequestPolicy.socialClientVersion,
            "forum_id": "\(forumID)",
            "friend_portrait": account.portrait
        ]
    }

    static func forumFollowFields(
        account: Account,
        forumID: Int64,
        tbs: String
    ) throws -> [String: String] {
        guard forumID > 0 else { throw TiebaMutationError.invalidForumID }
        let resolvedTBS = tbs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else { throw TiebaMutationError.missingTBS }
        return [
            "BDUSS": account.bduss,
            "fid": "\(forumID)",
            "tbs": resolvedTBS
        ]
    }

    static func likeFields(
        account: Account,
        tbs: String,
        threadID: Int64,
        postID: UInt64,
        objectType: TiebaLikeObjectType,
        liked: Bool,
        requestBuilder: TiebaRequestBuilder
    ) throws -> [String: String] {
        guard threadID > 0 else { throw TiebaMutationError.invalidThreadID }
        guard postID > 0 else { throw TiebaMutationError.invalidPostID }
        let resolvedTBS = tbs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else { throw TiebaMutationError.missingTBS }

        return [
            "BDUSS": account.bduss,
            "_client_version": TieBaXRequestPolicy.socialClientVersion,
            "agree_type": "2",
            "cuid": requestBuilder.miniCUID,
            "obj_type": "\(objectType.rawValue)",
            "op_type": liked ? "0" : "1",
            "post_id": objectType == .thread ? "0" : "\(postID)",
            "tbs": resolvedTBS,
            "thread_id": "\(threadID)"
        ]
    }
}

struct TiebaMutationResponseDTO: Decodable {
    var errorCode: Int
    var errorMessage: String

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_msg"
        case nestedError = "error"
    }

    private struct NestedError: Decodable {
        var code: Int
        var message: String

        enum CodingKeys: String, CodingKey {
            case code = "errno"
            case message = "errmsg"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.requiredFlexibleInt(forKey: .code)
            message = container.decodeStringIfPresent(forKey: .message) ?? ""
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let topLevelCode = try container.requiredFlexibleInt(forKey: .errorCode)
        let topLevelMessage = container.decodeStringIfPresent(forKey: .errorMessage) ?? ""
        let nested = try container.decodeIfPresent(NestedError.self, forKey: .nestedError)
        if topLevelCode != 0 {
            errorCode = topLevelCode
            errorMessage = topLevelMessage
        } else if let nested, nested.code != 0 {
            errorCode = nested.code
            errorMessage = nested.message
        } else {
            errorCode = 0
            errorMessage = topLevelMessage
        }
    }
}

struct FollowedUsersResponseDTO: Decodable {
    struct UserDTO: Decodable {
        var id: Int64
        var name: String
        var displayName: String
        var portrait: String

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case displayName = "name_show"
            case portrait
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.flexibleInt64(forKey: .id)
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
            portrait = (try? container.decode(String.self, forKey: .portrait)) ?? ""
        }

        var userSummary: UserSummary {
            let portraitToken = portrait.split(separator: "?", maxSplits: 1).first.map(String.init) ?? portrait
            return UserSummary(
                id: id,
                name: name,
                displayName: displayName,
                portrait: portraitToken
            )
        }
    }

    var errorCode: Int
    var errorMessage: String
    var users: [UserDTO]
    var currentPage: Int
    var totalCount: Int
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_msg"
        case users = "follow_list"
        case currentPage = "pn"
        case totalCount = "total_follow_num"
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = try container.requiredFlexibleInt(forKey: .errorCode)
        errorMessage = (try? container.decode(String.self, forKey: .errorMessage)) ?? ""
        users = (try? container.decode([UserDTO].self, forKey: .users)) ?? []
        currentPage = container.flexibleInt(forKey: .currentPage)
        totalCount = container.flexibleInt(forKey: .totalCount)
        hasMore = container.flexibleInt(forKey: .hasMore) != 0
    }
}

struct FollowersResponseDTO: Decodable {
    struct PageDTO: Decodable {
        var currentPage: Int
        var totalCount: Int
        var hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case currentPage = "current_page"
            case totalCount = "total_count"
            case hasMore = "has_more"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currentPage = container.flexibleInt(forKey: .currentPage)
            totalCount = container.flexibleInt(forKey: .totalCount)
            hasMore = container.flexibleInt(forKey: .hasMore) != 0
        }
    }

    var errorCode: Int
    var errorMessage: String
    var users: [FollowedUsersResponseDTO.UserDTO]
    var page: PageDTO

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_msg"
        case users = "user_list"
        case page
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = try container.requiredFlexibleInt(forKey: .errorCode)
        errorMessage = container.decodeStringIfPresent(forKey: .errorMessage) ?? ""
        users = try container.decodeIfPresent([FollowedUsersResponseDTO.UserDTO].self, forKey: .users) ?? []
        page = try container.decodeIfPresent(PageDTO.self, forKey: .page) ?? PageDTO(
            currentPage: 0,
            totalCount: users.count,
            hasMore: false
        )
    }
}

private extension FollowersResponseDTO.PageDTO {
    init(currentPage: Int, totalCount: Int, hasMore: Bool) {
        self.currentPage = currentPage
        self.totalCount = totalCount
        self.hasMore = hasMore
    }
}

struct ForumIDResponseDTO: Decodable {
    struct DataDTO: Decodable {
        var forumID: Int64

        enum CodingKeys: String, CodingKey { case forumID = "fid" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            forumID = container.flexibleInt64(forKey: .forumID)
        }
    }

    var code: Int
    var message: String
    var data: DataDTO?

    enum CodingKeys: String, CodingKey {
        case code = "no"
        case message = "error"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.requiredFlexibleInt(forKey: .code)
        message = container.decodeStringIfPresent(forKey: .message) ?? ""
        data = try container.decodeIfPresent(DataDTO.self, forKey: .data)
    }
}

struct ForumMembershipResponseDTO: Decodable {
    struct DataDTO: Decodable {
        struct UserForumInfoDTO: Decodable {
            var isFollowed: Bool

            enum CodingKeys: String, CodingKey { case isFollowed = "is_follow" }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isFollowed = try container.requiredFlexibleInt(forKey: .isFollowed) != 0
            }
        }

        var userForumInfo: UserForumInfoDTO

        enum CodingKeys: String, CodingKey { case userForumInfo = "user_forum_info" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userForumInfo = try container.decode(UserForumInfoDTO.self, forKey: .userForumInfo)
        }
    }

    var errorCode: Int
    var errorMessage: String
    var data: DataDTO?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_msg"
        case fallbackError = "error"
        case fallbackMessage = "errmsg"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = try container.requiredFlexibleInt(forKey: .errorCode)
        errorMessage = container.decodeStringIfPresent(forKey: .errorMessage)
            ?? container.decodeStringIfPresent(forKey: .fallbackError)
            ?? container.decodeStringIfPresent(forKey: .fallbackMessage)
            ?? ""
        if errorCode == 0 {
            data = try container.decode(DataDTO.self, forKey: .data)
        } else {
            data = try container.decodeIfPresent(DataDTO.self, forKey: .data)
        }
    }
}

extension TiebaAPI {
    func refreshedClientTBS(for account: Account) async throws -> String {
        try await refreshedClientTBS(for: account, allowsStoredFallback: true)
    }

    func strictlyRefreshedClientTBS(for account: Account) async throws -> String {
        try await refreshedClientTBS(for: account, allowsStoredFallback: false)
    }

    private func refreshedClientTBS(
        for account: Account,
        allowsStoredFallback: Bool
    ) async throws -> String {
        var clientError: Error?
        var webError: Error?

        do {
            let response = try await login(
                bduss: account.bduss,
                stoken: account.stoken,
                baiduID: account.baiduID ?? ""
            )
            try Task.checkCancellation()
            let code = Int(response.errorCode ?? "0") ?? 0
            if code == 0 {
                let tbs = response.anti?.tbs.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines
                ) ?? ""
                if tbs.isEmpty == false {
                    return tbs
                }
                clientError = TiebaMutationError.missingTBS
            } else {
                do {
                    try TiebaResponseValidator.validate(
                        code: code,
                        message: response.errorMessage ?? ""
                    )
                } catch {
                    clientError = error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            clientError = error
        }

        try Task.checkCancellation()

        do {
            let webInfo = try await webMyInfo(cookies: BaiduCookies(
                bduss: account.bduss,
                stoken: account.stoken,
                baiduID: account.baiduID
            ))
            try Task.checkCancellation()

            if webInfo.data?.isLogin == false {
                if let apiError = clientError as? TiebaAPIError,
                   case .sessionExpired = apiError {
                    throw apiError
                }
                throw TiebaAPIError.sessionExpired(code: 4, message: "网页登录状态已失效")
            }

            if let data = webInfo.data {
                for candidate in [data.tbs, data.itbTbs] {
                    let tbs = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if tbs.isEmpty == false {
                        return tbs
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let apiError as TiebaAPIError {
            if case .sessionExpired = apiError {
                throw apiError
            }
            webError = apiError
        } catch {
            webError = error
        }

        if allowsStoredFallback {
            let storedTBS = account.tbs.trimmingCharacters(in: .whitespacesAndNewlines)
            if storedTBS.isEmpty == false {
                return storedTBS
            }
        }
        if let clientError {
            throw clientError
        }
        if let webError {
            throw webError
        }
        throw TiebaMutationError.missingTBS
    }

    func setPostLiked(
        account: Account,
        threadID: Int64,
        postID: UInt64,
        objectType: TiebaLikeObjectType,
        liked: Bool
    ) async throws {
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let response = try await postLikeResponse(
            account: account,
            tbs: tbs,
            threadID: threadID,
            postID: postID,
            objectType: objectType,
            liked: liked
        )
        try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)
    }

    private func postLikeResponse(
        account: Account,
        tbs: String,
        threadID: Int64,
        postID: UInt64,
        objectType: TiebaLikeObjectType,
        liked: Bool
    ) async throws -> TiebaMutationResponseDTO {
        let fields = try TiebaSocialRequestFactory.likeFields(
            account: account,
            tbs: tbs,
            threadID: threadID,
            postID: postID,
            objectType: objectType,
            liked: liked,
            requestBuilder: requestBuilder
        )
        return try await client.postForm(
            .agreePost,
            fields: fields,
            headers: [
                "Pragma": "no-cache",
                "User-Agent": "tieba/\(TieBaXRequestPolicy.socialClientVersion)"
            ],
            signingSecret: "tiebaclient!!!",
            as: TiebaMutationResponseDTO.self
        )
    }

    func userRelationships(
        account: Account?,
        userID: Int64,
        kind: UserRelationshipKind,
        page: Int
    ) async throws -> UserRelationshipPage {
        let fields = try TiebaSocialRequestFactory.userRelationshipFields(
            account: account,
            userID: userID,
            page: page
        )
        let headers = [
            "Pragma": "no-cache",
            "User-Agent": "tieba/\(TieBaXRequestPolicy.socialClientVersion)"
        ]

        switch kind {
        case .following:
            let response = try await client.postForm(
                .followedUsers,
                fields: fields,
                headers: headers,
                signingSecret: "tiebaclient!!!",
                as: FollowedUsersResponseDTO.self
            )
            try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)
            return UserRelationshipPage(
                users: response.users.map(\.userSummary),
                currentPage: max(response.currentPage, page),
                totalCount: max(response.totalCount, 0),
                hasMore: response.hasMore
            )
        case .followers:
            let response = try await client.postForm(
                .followers,
                fields: fields,
                headers: headers,
                signingSecret: "tiebaclient!!!",
                as: FollowersResponseDTO.self
            )
            try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)
            return UserRelationshipPage(
                users: response.users.map(\.userSummary),
                currentPage: max(response.page.currentPage, page),
                totalCount: max(response.page.totalCount, 0),
                hasMore: response.page.hasMore
            )
        }
    }

    func forumMembership(account: Account, forum: Forum) async throws -> ForumMembership {
        let forumID = try await resolvedForumID(for: forum)
        let fields = try TiebaSocialRequestFactory.forumMembershipFields(
            account: account,
            forumID: forumID
        )
        let response = try await client.postForm(
            .forumMembership,
            fields: fields,
            headers: ["User-Agent": "tieba/\(TieBaXRequestPolicy.socialClientVersion)"],
            signingSecret: "tiebaclient!!!",
            as: ForumMembershipResponseDTO.self
        )
        try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)
        guard let membershipData = response.data else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Successful forum membership response is missing data."
            ))
        }
        return ForumMembership(
            forumID: forumID,
            isFollowed: membershipData.userForumInfo.isFollowed
        )
    }

    func setForumFollowed(
        account: Account,
        forum: Forum,
        followed: Bool
    ) async throws -> ForumMembership {
        let forumID = try await resolvedForumID(for: forum)
        try Task.checkCancellation()
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let fields = try TiebaSocialRequestFactory.forumFollowFields(
            account: account,
            forumID: forumID,
            tbs: tbs
        )
        let response = try await client.postForm(
            followed ? .followForum : .unfollowForum,
            fields: fields,
            headers: ["User-Agent": "tieba/\(TieBaXRequestPolicy.socialClientVersion)"],
            signingSecret: "tiebaclient!!!",
            as: TiebaMutationResponseDTO.self
        )
        try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)
        return ForumMembership(forumID: forumID, isFollowed: followed)
    }

    private func resolvedForumID(for forum: Forum) async throws -> Int64 {
        if forum.id > 0 { return forum.id }
        let name = forum.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { throw TiebaMutationError.invalidForumID }
        let response = try await client.getJSON(
            .resolveForumID,
            queryItems: [
                .init(name: "fname", value: name),
                .init(name: "ie", value: "utf-8")
            ],
            headers: ["User-Agent": "TieBaX"],
            as: ForumIDResponseDTO.self
        )
        try TiebaResponseValidator.validate(code: response.code, message: response.message)
        guard let forumID = response.data?.forumID, forumID > 0 else {
            throw TiebaMutationError.invalidForumID
        }
        return forumID
    }
}

private extension KeyedDecodingContainer {
    func decodeStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Decimal.self, forKey: key) {
            return NSDecimalNumber(decimal: value).stringValue
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func requiredFlexibleInt(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return Int(clamping: value) }
        if let value = try? decode(String.self, forKey: key), let number = Int(value) { return number }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected a numeric business status code"
        )
    }

    func flexibleInt(forKey key: Key) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return Int(clamping: value) }
        if let value = try? decode(String.self, forKey: key) { return Int(value) ?? 0 }
        return 0
    }

    func flexibleInt64(forKey key: Key) -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Int64(value) }
        if let value = try? decode(String.self, forKey: key) { return Int64(value) ?? 0 }
        return 0
    }
}
