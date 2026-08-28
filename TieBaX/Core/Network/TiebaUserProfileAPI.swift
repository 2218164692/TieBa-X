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

private enum UserFollowedForumsRequestVariant {
    case officialJSON
    case mini
}

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
        let accountUserID = account.flatMap { Int64($0.uid) }
        let isCurrentUser = accountUserID == userID
        let requestedPageInt = Int(requestedPage)
        let primaryResponse: UserFollowedForumsResponseDTO
        do {
            primaryResponse = try await requestUserFollowedForums(
                account: account,
                userID: userID,
                page: requestedPageInt,
                pageSize: requestedPageSize,
                isCurrentUser: isCurrentUser,
                variant: .officialJSON
            )
        } catch let primaryError {
            // TiebaLite uses the Mini API for the imperative userLikeForum
            // call. Keep the official flow as the primary contract, but use
            // the Mini request when a server shard rejects the newer JSON
            // parameter set instead of falling back to the six-item profile
            // preview in the UI.
            do {
                primaryResponse = try await requestUserFollowedForums(
                    account: account,
                    userID: userID,
                    page: requestedPageInt,
                    pageSize: requestedPageSize,
                    isCurrentUser: isCurrentUser,
                    variant: .mini
                )
            } catch {
                throw primaryError
            }
        }

        // The official and Mini contracts do not always expose the same
        // collection. In particular, the official response can contain a
        // six-item profile preview while the Mini response contains the next
        // page (or the two responses can contain different pages). Merge both
        // responses instead of choosing one by count, then de-duplicate by
        // forum ID/name below.
        let primaryUniqueCount = deduplicatedForumCount(primaryResponse.forums)
        let needsMiniFallback = primaryUniqueCount == 0
            || primaryResponse.hasMore == true
            || primaryResponse.totalCount > primaryUniqueCount
            || primaryUniqueCount <= 6
        var responses = [primaryResponse]
        if needsMiniFallback,
           let miniResponse = try? await requestUserFollowedForums(
               account: account,
               userID: userID,
               page: requestedPageInt,
               pageSize: requestedPageSize,
               isCurrentUser: isCurrentUser,
               variant: .mini
           ) {
            responses.append(miniResponse)
        }

        var seenForumKeys = Set<String>()
        var forums: [Forum] = []
        var currentPage = requestedPageInt
        var totalCount = 0
        var serverHasMore = false
        var receivedHasMore = false
        for response in responses {
            currentPage = max(currentPage, response.currentPage)
            totalCount = max(totalCount, response.totalCount)
            if let hasMore = response.hasMore {
                receivedHasMore = true
                serverHasMore = serverHasMore || hasMore
            }
            for item in response.forums {
                let forum = item.forum
                let name = forum.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.isEmpty == false else { continue }
                let idKey = forum.id > 0 ? "id:\(forum.id)" : nil
                let nameKey = "name:\(name.lowercased())"
                guard seenForumKeys.contains(nameKey) == false,
                      idKey.map({ seenForumKeys.contains($0) }) != true else { continue }
                seenForumKeys.insert(nameKey)
                if let idKey { seenForumKeys.insert(idKey) }
                forums.append(forum)
            }
        }
        totalCount = max(totalCount, forums.count)
        // `has_more=false` is not reliable on the preview response. A
        // six-item page is the known preview shape, so allow the view to ask
        // for one more page; its duplicate-page guard stops immediately when
        // the endpoint really has no additional forums.
        let hasMore = serverHasMore
            || totalCount > forums.count
            || forums.count >= requestedPageSize
            || (receivedHasMore == false && forums.count == 6)
        return UserFollowedForumsPage(
            forums: forums,
            currentPage: currentPage,
            totalCount: totalCount,
            hasMore: hasMore
        )
    }

    private func deduplicatedForumCount(
        _ items: [UserFollowedForumsResponseDTO.ForumDTO]
    ) -> Int {
        var seen = Set<String>()
        var count = 0
        for item in items {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { continue }
            let idKey = item.id > 0 ? "id:\(item.id)" : nil
            let nameKey = "name:\(name.lowercased())"
            guard seen.contains(nameKey) == false,
                  idKey.map({ seen.contains($0) }) != true else { continue }
            seen.insert(nameKey)
            if let idKey { seen.insert(idKey) }
            count += 1
        }
        return count
    }

    private func requestUserFollowedForums(
        account: Account?,
        userID: Int64,
        page: Int,
        pageSize: Int,
        isCurrentUser: Bool,
        variant: UserFollowedForumsRequestVariant
    ) async throws -> UserFollowedForumsResponseDTO {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        var fields: [String: String]
        var headers: [String: String]

        switch variant {
        case .officialJSON:
            fields = requestBuilder.officialJSONCommonFields(
                bduss: account?.bduss,
                baiduID: account?.baiduID,
                clientVersion: TieBaXRequestPolicy.officialJSONClientVersion,
                timestamp: timestamp
            )
            headers = requestBuilder.officialJSONHeaders(
                baiduID: account?.baiduID,
                clientVersion: TieBaXRequestPolicy.officialJSONClientVersion,
                timestamp: timestamp,
                accountUID: account?.uid
            )
            headers["c3_aid"] = requestBuilder.officialAID

        case .mini:
            fields = requestBuilder.miniCommonFields(
                timestamp: timestamp,
                bduss: account?.bduss,
                baiduID: account?.baiduID
            )
            headers = requestBuilder.officialHeaders(
                baiduID: account?.baiduID,
                clientVersion: TieBaXRequestPolicy.miniClientVersion,
                timestamp: timestamp
            )
            headers["client_user_token"] = account?.uid ?? ""
        }

        fields["page_no"] = "\(page)"
        fields["page_size"] = "\(pageSize)"
        if let uid = account?.uid, uid.isEmpty == false {
            fields["uid"] = uid
        }
        // TiebaLite's userLikeForumFlow identifies the signed-in account in
        // uid and uses friend_uid/is_guest only for another user's profile.
        if isCurrentUser == false {
            fields["friend_uid"] = "\(userID)"
            fields["is_guest"] = "1"
        }
        headers["Referer"] = "https://tieba.baidu.com/i/i/forum"
        headers["force_login"] = "true"

        let response = try await client.postForm(
            .userFollowedForums,
            fields: fields,
            headers: headers,
            signingSecret: "tiebaclient!!!",
            as: UserFollowedForumsResponseDTO.self
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
        return response
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

struct UserFollowedForumsResponseDTO: Decodable {
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
        // TiebaLite renders forum_list as the followed list. common_forum_list
        // is a server-side recommendation bucket, so use it only as a
        // compatibility fallback when the followed collection is absent.
        let collectionNames = [
            "forum_list", "like_forum", "forum_info", "forums", "list",
            "forumList", "likeForum", "non-gconforum", "non_gconforum", "gconforum"
        ]
        // A profile response may contain a six-item preview at the root and
        // the complete paged collection under data/forum_list. Merge both
        // layers; the API mapper below removes duplicate forum IDs/names.
        let directForums = Self.arrays(container, names: collectionNames)
        let nestedForums = Self.arrays(nested, names: collectionNames)
        let parsedForums = directForums + nestedForums
        if parsedForums.isEmpty {
            forums = Self.arrays(container, names: ["common_forum_list"])
                + Self.arrays(nested, names: ["common_forum_list"])
        } else {
            forums = parsedForums
        }
        currentPage = max(
            Self.int(container, names: ["page_no", "pn", "page", "current_page"]),
            Self.int(nested, names: ["page_no", "pn", "page", "current_page"])
        )
        totalCount = max(
            Self.int(container, names: ["total_count", "total_num", "total", "like_num", "my_like_num", "like_forum_num"]),
            Self.int(nested, names: ["total_count", "total_num", "total", "like_num", "my_like_num", "like_forum_num"])
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

    private static func arrays(
        _ container: KeyedDecodingContainer<CodingKeyValue>?,
        names: [String]
    ) -> [ForumDTO] {
        guard let container else { return [] }
        return arrays(in: container, names: names, depth: 0)
    }

    /// `/c/f/forum/like` has returned several shapes over time. Walk every
    /// known collection key instead of returning the first non-empty array;
    /// this preserves the full list when a root preview and a nested page are
    /// present in the same response.
    private static func arrays(
        in container: KeyedDecodingContainer<CodingKeyValue>,
        names: [String],
        depth: Int
    ) -> [ForumDTO] {
        guard depth < 8 else { return [] }
        var result: [ForumDTO] = []
        for name in names {
            guard let key = CodingKeyValue(stringValue: name), container.contains(key) else { continue }
            if let value = try? container.decode([ForumDTO].self, forKey: key) {
                result.append(contentsOf: value)
                continue
            }
            if let value = try? container.decode([String: ForumDTO].self, forKey: key) {
                result.append(contentsOf: value.values)
                continue
            }
            if let value = try? container.decode(ForumDTO.self, forKey: key),
               value.name.isEmpty == false || value.id > 0 {
                result.append(value)
                continue
            }
            if let nested = try? container.nestedContainer(
                keyedBy: CodingKeyValue.self,
                forKey: key
            ) {
                result.append(contentsOf: arrays(in: nested, names: names, depth: depth + 1))
            }
        }
        return result
    }
}
