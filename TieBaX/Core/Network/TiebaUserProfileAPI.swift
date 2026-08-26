import CoreFoundation
import Foundation

struct UserProfileRequestContext {
    var request: Tiebax_Profile_UserProfileRequest
    var isCurrentUser: Bool
}

enum UserProfileRequestFactory {
    static let ownThreadDeleteClientVersion = "12.25.1.0"

    static func profileRequest(
        account: Account?,
        user: UserSummary,
        requestBuilder: TiebaRequestBuilder
    ) -> UserProfileRequestContext {
        let currentUserID = account.flatMap { Int64($0.uid) }
        let isCurrentUser = currentUserID != nil && currentUserID == user.id

        var data = Tiebax_Profile_UserProfileRequestData()
        if let currentUserID {
            data.uid = currentUserID
        }
        if isCurrentUser == false {
            if user.id != 0 {
                data.friendUid = user.id
            } else {
                data.friendUidPortrait = user.portrait
            }
        }
        data.needPostCount = 1
        data.isGuest = isCurrentUser ? 0 : 1
        data.pn = 1
        data.rn = 20
        data.hasPlist_p = 1
        data.common = requestBuilder.common(account: account)
        data.scrW = UInt32(clamping: requestBuilder.screenWidth)
        data.scrH = UInt32(clamping: requestBuilder.screenHeight)
        data.qType = 0
        data.scrDip = requestBuilder.screenScale
        data.isFromUsercenter = 1
        data.page = 1

        var request = Tiebax_Profile_UserProfileRequest()
        request.data = data
        return UserProfileRequestContext(request: request, isCurrentUser: isCurrentUser)
    }

    static func threadsRequest(
        account: Account?,
        userID: Int64,
        page: Int,
        requestBuilder: TiebaRequestBuilder
    ) throws -> Tiebax_Profile_UserThreadsRequest {
        let requestedPage = try TieBaXRequestPolicy.unsignedPage(page)
        var data = Tiebax_Profile_UserThreadsRequestData()
        data.uid = userID
        data.rn = 20
        data.isThread = 1
        data.needContent = 1
        data.pn = requestedPage
        data.common = requestBuilder.common(account: account)
        data.scrW = Int32(clamping: requestBuilder.screenWidth)
        data.scrH = Int32(clamping: requestBuilder.screenHeight)
        data.scrDip = requestBuilder.screenScale
        data.qType = 1
        data.isViewCard = 1

        var request = Tiebax_Profile_UserThreadsRequest()
        request.data = data
        return request
    }

    static func followFields(
        account: Account,
        user: UserSummary,
        tbs: String? = nil
    ) throws -> [String: String] {
        let portrait = user.portrait.trimmingCharacters(in: .whitespacesAndNewlines)
        guard portrait.isEmpty == false else {
            throw UserProfileAPIError.missingPortrait
        }
        let resolvedTBS = (tbs ?? account.tbs).trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else {
            throw UserProfileAPIError.missingTBS
        }

        return [
            "BDUSS": account.bduss,
            "portrait": portrait,
            "tbs": resolvedTBS
        ]
    }

    static func profileEditFields(
        account: Account,
        request: UserProfileEditRequest
    ) throws -> [String: String] {
        let nickname = request.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nickname.isEmpty == false else {
            throw UserProfileMutationError.missingNickname
        }
        var fields = [
            "BDUSS": account.bduss,
            "intro": request.introduction,
            "nick_name": nickname
        ]
        // The profile endpoint accepts 1/2 for male/female, but a submitted 0
        // may be normalized to male. Omit the field to preserve an unset value.
        if let sex = request.sex.profileMutationProtocolValue {
            fields["sex"] = "\(sex)"
        }
        return fields
    }

    static func deleteThreadFields(
        account: Account,
        tbs: String,
        target: OwnThreadDeletionTarget,
        requestBuilder: TiebaRequestBuilder,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> [String: String] {
        try validateDeletionTarget(target)
        let resolvedTBS = tbs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else {
            throw UserProfileAPIError.missingTBS
        }
        var fields = requestBuilder.officialCommonFields(
            bduss: account.bduss,
            baiduID: account.baiduID,
            clientVersion: ownThreadDeleteClientVersion,
            timestamp: timestamp
        )
        fields.merge([
            "delete_my_thread": "1",
            "fid": "\(target.forumID)",
            "is_frs_mask": "0",
            "is_vipdel": "0",
            "src": "1",
            "tbs": resolvedTBS,
            "word": target.forumName.trimmingCharacters(in: .whitespacesAndNewlines),
            "z": "\(target.threadID)"
        ], uniquingKeysWith: { _, new in new })
        return fields
    }

    static func validateDeletionTarget(_ target: OwnThreadDeletionTarget) throws {
        guard target.forumID > 0 else {
            throw UserProfileMutationError.invalidForumID
        }
        guard target.forumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw UserProfileMutationError.invalidForumName
        }
        guard target.threadID > 0 else {
            throw UserProfileMutationError.invalidThreadID
        }
        guard target.firstPostID > 0 else {
            throw UserProfileMutationError.invalidFirstPostID
        }
    }
}

enum UserProfileAPIError: Error, Equatable, CustomStringConvertible {
    case missingProfile
    case missingUserIdentifier
    case missingPortrait
    case missingTBS

    var description: String {
        switch self {
        case .missingProfile:
            return "贴吧没有返回可用的用户资料。"
        case .missingUserIdentifier:
            return "缺少用户 ID，无法加载用户帖子。"
        case .missingPortrait:
            return "缺少用户标识，无法修改关注状态。"
        case .missingTBS:
            return "登录状态不完整，请重新登录后再试。"
        }
    }
}

enum UserProfileMutationError: Error, Equatable, CustomStringConvertible {
    case missingNickname
    case invalidForumID
    case invalidForumName
    case invalidThreadID
    case invalidFirstPostID
    case outcomeUnknown
    case unsupportedByService

    var description: String {
        switch self {
        case .missingNickname:
            return "昵称不能为空。"
        case .invalidForumID:
            return "贴吧 ID 无效，无法删除主题。"
        case .invalidForumName:
            return "贴吧名称无效，无法删除主题。"
        case .invalidThreadID:
            return "主题 ID 无效，无法删除主题。"
        case .invalidFirstPostID:
            return "缺少主题首帖 ID，无法确认删除目标。"
        case .outcomeUnknown:
            return "请求已经发出，但未能确认贴吧是否处理成功。请刷新后再决定是否重试。"
        case .unsupportedByService:
            return "当前数据服务不支持该操作。"
        }
    }
}

typealias UserFollowResponseDTO = TiebaMutationResponseDTO

extension TiebaAPI {
    func userFollowedForums(
        account: Account?,
        userID: Int64,
        page: Int,
        pageSize: Int
    ) async throws -> UserFollowedForumsPage {
        guard userID > 0 else { throw UserProfileAPIError.missingUserIdentifier }
        let requestedPage = try TieBaXRequestPolicy.signedPage(page)
        let requestedPageSize = min(max(pageSize, 1), 200)
        let response = try await client.postForm(
            .userFollowedForums,
            fields: [
                "BDUSS": account?.bduss ?? "",
                "_client_version": TieBaXRequestPolicy.officialClientVersion,
                "friend_uid": "\(userID)",
                "page_no": "\(requestedPage)",
                "page_size": "\(requestedPageSize)"
            ],
            headers: [
                "User-Agent": "bdtb for Android \(TieBaXRequestPolicy.officialClientVersion)",
                "Referer": "https://tieba.baidu.com/i/i/forum"
            ],
            as: UserFollowedForumsResponseDTO.self
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
        let currentPage = max(Int(requestedPage), response.currentPage)
        let forums = response.forums.compactMap { item -> Forum? in
            let forum = item.forum
            return forum.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : forum
        }
        return UserFollowedForumsPage(
            forums: forums,
            currentPage: currentPage,
            totalCount: max(response.totalCount, forums.count),
            hasMore: response.hasMore ?? (response.totalCount > forums.count || forums.count >= requestedPageSize)
        )
    }

    func userProfile(account: Account?, user: UserSummary) async throws -> UserProfile {
        let context = UserProfileRequestFactory.profileRequest(
            account: account,
            user: user,
            requestBuilder: requestBuilder
        )
        let multipart = try requestBuilder.multipart(
            protobuf: context.request,
            account: account,
            includeSToken: false
        )
        let response = try await client.postProtobuf(
            .userProfile,
            body: multipart.body,
            contentType: multipart.contentType,
            headers: ["X-BD-DATA-TYPE": "protobuf"],
            as: Tiebax_Profile_UserProfileResponse.self
        )
        try TiebaResponseValidator.validate(
            code: Int(response.error.errorCode),
            message: response.error.userMsg.isEmpty ? response.error.errorMsg : response.error.userMsg
        )
        guard response.hasData, response.data.hasUser else {
            throw UserProfileAPIError.missingProfile
        }
        return UserProfileMapper.profile(
            from: response.data.user,
            fallback: user,
            isCurrentUser: context.isCurrentUser
        )
    }

    func userThreads(account: Account?, userID: Int64, page: Int) async throws -> UserThreadsPage {
        guard userID > 0 else { throw UserProfileAPIError.missingUserIdentifier }
        let request = try UserProfileRequestFactory.threadsRequest(
            account: account,
            userID: userID,
            page: page,
            requestBuilder: requestBuilder
        )
        let multipart = try requestBuilder.multipart(
            protobuf: request,
            account: account,
            includeSToken: true
        )
        let response = try await client.postProtobuf(
            .userThreads,
            body: multipart.body,
            contentType: multipart.contentType,
            headers: ["X-BD-DATA-TYPE": "protobuf"],
            as: Tiebax_Profile_UserThreadsResponse.self
        )
        try TiebaResponseValidator.validate(
            code: Int(response.error.errorCode),
            message: response.error.userMsg.isEmpty ? response.error.errorMsg : response.error.userMsg
        )
        return UserProfileMapper.threadsPage(from: response, page: page)
    }

    func updateOwnProfile(account: Account, request: UserProfileEditRequest) async throws {
        let fields = try UserProfileRequestFactory.profileEditFields(
            account: account,
            request: request
        )
        let response = try await sendFinalUserProfileMutation(
            endpoint: .modifyProfile,
            fields: fields
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
    }

    func deleteOwnThread(account: Account, target: OwnThreadDeletionTarget) async throws {
        try Task.checkCancellation()
        try UserProfileRequestFactory.validateDeletionTarget(target)
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let fields = try UserProfileRequestFactory.deleteThreadFields(
            account: account,
            tbs: tbs,
            target: target,
            requestBuilder: requestBuilder,
            timestamp: timestamp
        )
        let response = try await sendFinalUserProfileMutation(
            endpoint: .deleteOwnThread,
            fields: fields,
            headers: requestBuilder.officialHeaders(
                baiduID: account.baiduID,
                clientVersion: UserProfileRequestFactory.ownThreadDeleteClientVersion,
                timestamp: timestamp
            )
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
    }

    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws {
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let fields = try UserProfileRequestFactory.followFields(
            account: account,
            user: user,
            tbs: tbs
        )
        let endpoint: TiebaEndpoint = followed ? .followUser : .unfollowUser
        let response = try await client.postForm(
            endpoint,
            fields: fields,
            headers: ["User-Agent": "tieba/\(TieBaXRequestPolicy.socialClientVersion)"],
            signingSecret: "tiebaclient!!!",
            as: UserFollowResponseDTO.self
        )
        try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)
    }

    private func sendFinalUserProfileMutation(
        endpoint: TiebaEndpoint,
        fields: [String: String],
        headers: [String: String] = ["User-Agent": "tieba/\(TieBaXRequestPolicy.socialClientVersion)"]
    ) async throws -> StrictUserProfileMutationResponse {
        try Task.checkCancellation()
        do {
            let data = try await client.postFormData(
                endpoint,
                fields: fields,
                headers: headers,
                signingSecret: "tiebaclient!!!"
            )
            return try strictUserProfileMutationResponse(from: data)
        } catch {
            // Once the final POST is dispatched, losing its response cannot
            // prove that Tieba did not apply the mutation. Keep this distinct
            // from a preflight failure so callers never retry automatically.
            throw UserProfileMutationError.outcomeUnknown
        }
    }
}

private struct StrictUserProfileMutationResponse {
    var errorCode: Int
    var errorMessage: String
}

/// JSONDecoder accepts integral floating-point tokens such as `0.0` when
/// decoding an Int. Inspect the raw JSON instead, then reconcile every known
/// status alias before treating an already-dispatched mutation as successful.
private func strictUserProfileMutationResponse(
    from data: Data
) throws -> StrictUserProfileMutationResponse {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UserProfileMutationError.outcomeUnknown
    }

    var containers = [object]
    if let nestedData = object["data"] {
        guard let nestedData = nestedData as? [String: Any] else {
            throw UserProfileMutationError.outcomeUnknown
        }
        containers.append(nestedData)
    }
    var errorString: String?
    if let nestedError = object["error"], nestedError is NSNull == false {
        if let nestedError = nestedError as? [String: Any] {
            containers.append(nestedError)
        } else if let nestedError = nestedError as? String {
            errorString = nestedError
        } else {
            throw UserProfileMutationError.outcomeUnknown
        }
    }

    let integerKeys: Set<String> = [
        "result", "error_code", "err_code", "errno", "error_no", "no"
    ]
    var statusValues: [Int] = []
    for container in containers {
        for key in integerKeys {
            guard let value = container[key] else { continue }
            statusValues.append(try strictUserProfileMutationInteger(value))
        }
    }

    guard let status = statusValues.first,
          statusValues.allSatisfy({ $0 == status }) else {
        throw UserProfileMutationError.outcomeUnknown
    }

    let normalizedErrorString = errorString?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if status == 0, normalizedErrorString?.isEmpty == false {
        throw UserProfileMutationError.outcomeUnknown
    }

    let messageKeys = ["error_msg", "err_msg", "errmsg", "user_msg", "message", "msg"]
    let message = containers.lazy
        .flatMap { container in
            messageKeys.compactMap { key -> String? in
                guard let value = container[key] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        .first
        ?? normalizedErrorString
        ?? ""
    return StrictUserProfileMutationResponse(
        errorCode: status,
        errorMessage: message
    )
}

private func strictUserProfileMutationInteger(_ value: Any) throws -> Int {
    if let value = value as? String {
        guard let integer = Int(value) else {
            throw UserProfileMutationError.outcomeUnknown
        }
        return integer
    }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw UserProfileMutationError.outcomeUnknown
    }
    switch String(cString: number.objCType) {
    case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
        guard let integer = Int(number.stringValue) else {
            throw UserProfileMutationError.outcomeUnknown
        }
        return integer
    default:
        throw UserProfileMutationError.outcomeUnknown
    }
}

private struct UserFollowedForumsResponseDTO: Decodable {
    private struct CodingKeyValue: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    struct ForumDTO: Decodable {
        let id: Int64
        let name: String
        let avatar: String?
        let memberCount: Int
        let threadCount: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeyValue.self)
            id = Int64(UserFollowedForumsResponseDTO.string(container, names: ["forum_id", "fid", "id", "forumID", "forumId"]) ?? "") ?? 0
            name = UserFollowedForumsResponseDTO.string(container, names: ["forum_name", "fname", "name", "forumName"]) ?? ""
            avatar = UserFollowedForumsResponseDTO.string(container, names: [
                "avatar", "avatar_url", "avatarUrl", "forum_avatar", "forumAvatar", "forum_image", "forum_pic", "pic", "image", "icon", "logo"
            ])
            memberCount = UserFollowedForumsResponseDTO.int(container, names: ["member_num", "concern_num", "member_count", "memberNum", "concernCount"])
            threadCount = UserFollowedForumsResponseDTO.int(container, names: ["thread_num", "post_num", "thread_count", "threadNum", "postNum"])
        }

        var forum: Forum {
            Forum(
                id: id,
                name: name,
                displayName: ForumNamePolicy.displayName(for: name),
                avatarURL: TiebaURL.avatar(avatar),
                memberCount: max(memberCount, 0),
                threadCount: max(threadCount, 0)
            )
        }
    }

    let errorCode: Int
    let errorMessage: String
    let forums: [ForumDTO]
    let currentPage: Int
    let totalCount: Int
    let hasMore: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeyValue.self)
        let nested = try? container.nestedContainer(
            keyedBy: CodingKeyValue.self,
            forKey: CodingKeyValue(stringValue: "data")!
        )
        errorCode = Self.int(container, names: ["error_code", "errno", "no", "errorCode"])
        errorMessage = Self.string(container, names: ["error_msg", "errmsg", "error", "message", "errorMessage"]) ?? ""
        let directForums = Self.array(container, names: [
            "forum_list", "like_forum", "forum_info", "forums", "list", "forumList", "likeForum"
        ])
        forums = directForums.isEmpty ? Self.array(nested, names: [
            "forum_list", "like_forum", "forum_info", "forums", "list", "forumList", "likeForum"
        ]) : directForums
        currentPage = max(
            Self.int(container, names: ["page_no", "pn", "page", "current_page"]),
            Self.int(nested, names: ["page_no", "pn", "page", "current_page"])
        )
        totalCount = max(
            Self.int(container, names: ["total_count", "total_num", "total", "like_num", "my_like_num"]),
            Self.int(nested, names: ["total_count", "total_num", "total", "like_num", "my_like_num"])
        )
        hasMore = Self.bool(container, names: ["has_more", "like_forum_has_more"])
            ?? Self.bool(nested, names: ["has_more", "like_forum_has_more"])
    }

    private static func string(
        _ container: KeyedDecodingContainer<CodingKeyValue>?,
        names: [String]
    ) -> String? {
        guard let container else { return nil }
        for name in names {
            let key = CodingKeyValue(stringValue: name)!
            if let value = try? container.decode(String.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Int64.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decode(Bool.self, forKey: key) {
                return value ? "1" : "0"
            }
        }
        return nil
    }

    private static func int(
        _ container: KeyedDecodingContainer<CodingKeyValue>?,
        names: [String]
    ) -> Int {
        guard let value = string(container, names: names) else { return 0 }
        return Int(value) ?? 0
    }

    private static func bool(
        _ container: KeyedDecodingContainer<CodingKeyValue>?,
        names: [String]
    ) -> Bool? {
        guard let value = string(container, names: names)?.lowercased() else { return nil }
        switch value {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private static func array(
        _ container: KeyedDecodingContainer<CodingKeyValue>?,
        names: [String]
    ) -> [ForumDTO] {
        guard let container else { return [] }
        for name in names {
            let key = CodingKeyValue(stringValue: name)!
            if let value = try? container.decode([ForumDTO].self, forKey: key) {
                return value
            }
            if let value = try? container.decode([String: ForumDTO].self, forKey: key) {
                return Array(value.values)
            }
            if let value = try? container.decode(ForumDTO.self, forKey: key) {
                return [value]
            }
        }
        return []
    }
}
