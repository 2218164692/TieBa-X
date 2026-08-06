import Foundation

/// One forum's check-in outcome. Signing an already-signed forum is not an
/// error on the service: it answers with the existing streak, which is why
/// `wasAlreadySigned` is part of a successful result rather than a failure.
struct ForumSignResult: Equatable, Sendable, Identifiable {
    var forumID: Int64
    var forumName: String
    var wasAlreadySigned: Bool
    var bonusPoints: Int
    var continuousDays: Int
    var rank: Int

    var id: Int64 { forumID }
}

enum ForumSignError: Error, Equatable, CustomStringConvertible {
    case missingForumName
    /// The service reports "already signed today" as an error code rather than
    /// a successful no-op, so it is translated back into a normal outcome.
    case alreadySigned

    var description: String {
        switch self {
        case .missingForumName:
            return "缺少吧名，无法签到。"
        case .alreadySigned:
            return "今天已经签到过了。"
        }
    }
}

enum ForumSignResponsePolicy {
    /// Baidu returns 160002 ("已签到") for a repeated check-in on the same day.
    static let alreadySignedErrorCode = 160002

    static func isAlreadySigned(errorCode: Int) -> Bool {
        errorCode == alreadySignedErrorCode
    }
}

enum TiebaForumSignRequestFactory {
    static func signFields(
        account: Account,
        forumID: Int64,
        forumName: String,
        tbs: String,
        requestBuilder: TiebaRequestBuilder,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> [String: String] {
        let name = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { throw ForumSignError.missingForumName }
        let resolvedTBS = tbs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else { throw TiebaMutationError.missingTBS }

        var fields = requestBuilder.officialCommonFields(
            bduss: account.bduss,
            baiduID: account.baiduID,
            clientVersion: TiebaClientVersion.v12.rawValue,
            timestamp: timestamp
        )
        fields["BDUSS"] = account.bduss
        fields["kw"] = name
        fields["tbs"] = resolvedTBS
        if forumID > 0 {
            fields["fid"] = "\(forumID)"
        }
        return fields
    }
}

struct ForumSignResponseDTO: Decodable {
    struct UserInfoDTO: Decodable {
        var isSignedIn: Bool
        var bonusPoints: Int
        var continuousDays: Int
        var rank: Int

        enum CodingKeys: String, CodingKey {
            case isSignedIn = "is_sign_in"
            case bonusPoints = "sign_bonus_point"
            case continuousDays = "cont_sign_num"
            case rank = "user_sign_rank"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isSignedIn = container.flexibleInt(forKey: .isSignedIn) != 0
            bonusPoints = container.flexibleInt(forKey: .bonusPoints)
            continuousDays = container.flexibleInt(forKey: .continuousDays)
            rank = container.flexibleInt(forKey: .rank)
        }
    }

    var errorCode: Int
    var errorMessage: String
    var userInfo: UserInfoDTO?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_msg"
        case userInfo = "user_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = try container.requiredFlexibleInt(forKey: .errorCode)
        errorMessage = (try? container.decode(String.self, forKey: .errorMessage)) ?? ""
        userInfo = try? container.decodeIfPresent(UserInfoDTO.self, forKey: .userInfo)
    }
}

private extension KeyedDecodingContainer {
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
        if let value = try? decode(Bool.self, forKey: key) { return value ? 1 : 0 }
        if let value = try? decode(String.self, forKey: key) { return Int(value) ?? 0 }
        return 0
    }
}

extension TiebaAPI {
    func signForum(account: Account, forum: Forum) async throws -> ForumSignResult {
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let fields = try TiebaForumSignRequestFactory.signFields(
            account: account,
            forumID: forum.id,
            forumName: forum.name,
            tbs: tbs,
            requestBuilder: requestBuilder
        )
        let response = try await client.postForm(
            .signForum,
            fields: fields,
            headers: requestBuilder.officialHeaders(
                baiduID: account.baiduID,
                clientVersion: TiebaClientVersion.v12.rawValue
            ),
            signingSecret: "tiebaclient!!!",
            as: ForumSignResponseDTO.self
        )

        if ForumSignResponsePolicy.isAlreadySigned(errorCode: response.errorCode) {
            return ForumSignResult(
                forumID: forum.id,
                forumName: forum.name,
                wasAlreadySigned: true,
                bonusPoints: 0,
                continuousDays: response.userInfo?.continuousDays ?? 0,
                rank: response.userInfo?.rank ?? 0
            )
        }
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
        return ForumSignResult(
            forumID: forum.id,
            forumName: forum.name,
            wasAlreadySigned: response.userInfo?.isSignedIn == true
                && (response.userInfo?.bonusPoints ?? 0) == 0,
            bonusPoints: response.userInfo?.bonusPoints ?? 0,
            continuousDays: response.userInfo?.continuousDays ?? 0,
            rank: response.userInfo?.rank ?? 0
        )
    }
}
