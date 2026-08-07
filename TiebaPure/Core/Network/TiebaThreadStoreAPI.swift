import Foundation

/// A thread the account collected on Baidu's side, as opposed to the on-device
/// favorites the app keeps in `LocalThreadLibraryStore`.
struct AccountThreadFavorite: Equatable, Sendable, Identifiable {
    var threadID: Int64
    var forumID: Int64
    var forumName: String
    var title: String
    var authorDisplayName: String
    var replyCount: Int
    var lastReplyAt: Date?
    /// The floor Baidu remembered when the thread was collected. The service
    /// stores it with the collection, which is what lets a collected thread
    /// reopen where it was left.
    var markedPostID: UInt64?

    var id: Int64 { threadID }
}

struct AccountThreadFavoritesPage: Equatable, Sendable {
    var favorites: [AccountThreadFavorite]
    var currentPage: Int
    var hasMore: Bool
}

enum AccountThreadFavoritesPolicy {
    static let pageSize = 20

    static func fields(account: Account, page: Int) throws -> [String: String] {
        let requestedPage = try TiebaRequestValuePolicy.signedPage(page)
        return [
            "BDUSS": account.bduss,
            "stoken": account.stoken,
            "pn": "\(requestedPage)",
            "rn": "\(pageSize)"
        ]
    }
}

struct ThreadStoreListResponseDTO: Decodable {
    struct ThreadDTO: Decodable {
        var threadID: Int64
        var forumID: Int64
        var forumName: String
        var title: String
        var authorDisplayName: String
        var replyCount: Int
        var lastReplyAt: Date?
        var markedPostID: UInt64?

        private struct AuthorDTO: Decodable {
            var name: String
            var displayName: String

            enum CodingKeys: String, CodingKey {
                case name
                case displayName = "name_show"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = (try? container.decode(String.self, forKey: .name)) ?? ""
                displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
            }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case tid
            case forumID = "fid"
            case forumName = "fname"
            case title
            case author
            case replyCount = "reply_num"
            case lastReplyAt = "last_time_int"
            case markedPostID = "collect_mark_pid"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The payload carries the same thread under both keys; either one
            // alone is enough to open it.
            let tid = container.storeFlexibleInt64(forKey: .tid)
            threadID = tid != 0 ? tid : container.storeFlexibleInt64(forKey: .id)
            forumID = container.storeFlexibleInt64(forKey: .forumID)
            forumName = container.storeStringIfPresent(forKey: .forumName) ?? ""
            title = container.storeStringIfPresent(forKey: .title) ?? ""
            let author = try? container.decodeIfPresent(AuthorDTO.self, forKey: .author)
            authorDisplayName = author.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? ""
            replyCount = container.storeFlexibleInt(forKey: .replyCount)
            let timestamp = container.storeFlexibleInt64(forKey: .lastReplyAt)
            lastReplyAt = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
            let markedPostID = container.storeFlexibleInt64(forKey: .markedPostID)
            self.markedPostID = markedPostID > 0 ? UInt64(markedPostID) : nil
        }

        var favorite: AccountThreadFavorite? {
            guard threadID > 0 else { return nil }
            return AccountThreadFavorite(
                threadID: threadID,
                forumID: forumID,
                forumName: forumName,
                title: title.isEmpty ? "帖子 \(threadID)" : title,
                authorDisplayName: authorDisplayName.isEmpty ? "未知用户" : authorDisplayName,
                replyCount: replyCount,
                lastReplyAt: lastReplyAt,
                markedPostID: markedPostID
            )
        }
    }

    private struct DataDTO: Decodable {
        var threadList: [ThreadDTO]
        var hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case threadList = "thread_list"
            case hasMore = "has_more"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            threadList = (try? container.decode([ThreadDTO].self, forKey: .threadList)) ?? []
            hasMore = container.storeFlexibleInt(forKey: .hasMore) != 0
        }
    }

    var errorCode: Int
    var errorMessage: String
    var threads: [ThreadDTO]
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_msg"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = container.storeFlexibleInt(forKey: .errorCode)
        errorMessage = container.storeStringIfPresent(forKey: .errorMessage) ?? ""
        let data = try? container.decodeIfPresent(DataDTO.self, forKey: .data)
        threads = data?.threadList ?? []
        hasMore = data?.hasMore ?? false
    }
}

extension TiebaAPI {
    func accountThreadFavorites(account: Account, page: Int) async throws -> AccountThreadFavoritesPage {
        let response = try await client.postForm(
            .threadStoreList,
            fields: try AccountThreadFavoritesPolicy.fields(account: account, page: page),
            headers: requestBuilder.officialHeaders(
                baiduID: account.baiduID,
                clientVersion: TiebaClientVersion.v12.rawValue
            ),
            signingSecret: "tiebaclient!!!",
            as: ThreadStoreListResponseDTO.self
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
        return AccountThreadFavoritesPage(
            favorites: response.threads.compactMap(\.favorite),
            currentPage: page,
            hasMore: response.hasMore
        )
    }
}

private extension KeyedDecodingContainer {
    func storeStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    func storeFlexibleInt(forKey key: Key) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Bool.self, forKey: key) { return value ? 1 : 0 }
        if let value = try? decode(String.self, forKey: key) { return Int(value) ?? 0 }
        return 0
    }

    func storeFlexibleInt64(forKey key: Key) -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Int64(value) }
        if let value = try? decode(String.self, forKey: key) { return Int64(value) ?? 0 }
        return 0
    }
}
