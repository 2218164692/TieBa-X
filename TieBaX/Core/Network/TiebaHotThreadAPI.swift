import Foundation
import UIKit

/// Official protobuf hot-thread feed used by TiebaLite's Explore > 热门 page.
/// The older `hotTopics()` JSON call is kept for a separate topic directory;
/// it is not used as the primary hot feed anymore.
extension TiebaAPI {
    func hotThreads(account: Account?, tabCode: String) async throws -> HotThreadFeedPage {
        let requestedCode = tabCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = requestedCode.isEmpty ? "all" : String(requestedCode.prefix(32))

        var requestData = Tieba_HotThreadList_HotThreadListRequestData()
        requestData.common = requestBuilder.v11Common(account: account)
        requestData.tabId = "1"
        requestData.tabCode = code

        var request = Tieba_HotThreadList_HotThreadListRequest()
        request.data = requestData

        // TiebaLite uses the V11 protobuf envelope for hotThreadList. The
        // endpoint expects the signed common form fields appended to the
        // multipart body by its Android interceptors.
        let multipart = try requestBuilder.multipart(
            protobuf: request,
            account: account,
            includeSToken: true,
            clientVersion: TieBaXRequestPolicy.officialClientVersion,
            additionalFields: requestBuilder.v11CommonFields(account: account),
            signingSecret: "tiebaclient!!!",
            fileContentType: nil
        )
        let cuid = requestBuilder.officialCUID
        let response = try await client.postProtobuf(
            .hotThreadList,
            body: multipart.body,
            contentType: multipart.contentType,
            headers: [
                "Charset": "UTF-8",
                "client_type": "2",
                "client_user_token": account?.uid ?? "",
                "Cookie": "CUID=\(cuid);ka=open;TBBRAND=\(UIDevice.current.model);",
                "CUID": cuid,
                "cuid_galaxy2": cuid,
                "c3_aid": requestBuilder.officialAID,
                "cuid_gid": "",
                "User-Agent": "bdtb for Android \(TieBaXRequestPolicy.officialClientVersion)",
                "X-BD-DATA-TYPE": "protobuf"
            ],
            as: Tieba_HotThreadList_HotThreadListResponse.self
        )

        // The V11 endpoint is the source used by TiebaLite and remains the
        // authoritative response whenever it contains ranked threads. Some
        // server/device combinations, however, return a successful envelope
        // with no `data` (or an empty `threadInfo`) even though the compatible
        // V12 request returns the same board. Retry that one compatibility
        // request so the screen does not regress to an empty state. Each
        // decoded page keeps the server's complete `threadInfo` collection;
        // no filtering or deduplication is applied, so the visible count
        // still matches the response selected below.
        let primaryPage: HotThreadFeedPage
        do {
            primaryPage = try Self.decodeHotThreadPage(from: response)
        } catch {
            if let apiError = error as? TiebaAPIError,
               case .sessionExpired = apiError {
                throw apiError
            }
            return try await hotThreadsV12Fallback(account: account, code: code)
        }
        guard primaryPage.threads.isEmpty else { return primaryPage }

        do {
            let fallbackPage = try await hotThreadsV12Fallback(account: account, code: code)
            return fallbackPage.threads.isEmpty ? primaryPage : fallbackPage
        } catch {
            if let apiError = error as? TiebaAPIError,
               case .sessionExpired = apiError {
                throw apiError
            }
            // An empty V11 page is still a valid server response. Preserve it
            // when the compatibility request is unavailable (for example,
            // because the device is offline) instead of replacing it with a
            // misleading network error.
            return primaryPage
        }
    }
}

private extension TiebaAPI {
    /// V12-compatible retry for installations whose V11 hotThreadList reply
    /// omits the ranked payload. This is the same protobuf endpoint and
    /// request shape used by the previous TiebaLite-compatible implementation;
    /// it is deliberately only attempted after an empty/undecodable V11 page.
    func hotThreadsV12Fallback(account: Account?, code: String) async throws -> HotThreadFeedPage {
        var requestData = Tieba_HotThreadList_HotThreadListRequestData()
        requestData.common = requestBuilder.common(account: account)
        requestData.tabId = "1"
        requestData.tabCode = code

        var request = Tieba_HotThreadList_HotThreadListRequest()
        request.data = requestData

        let multipart = try requestBuilder.multipart(
            protobuf: request,
            account: account,
            includeSToken: true,
            clientVersion: TieBaXRequestPolicy.appClientVersion,
            additionalFields: requestBuilder.officialCommonFields(
                bduss: account?.bduss,
                baiduID: account?.baiduID,
                clientVersion: TieBaXRequestPolicy.appClientVersion
            ),
            signingSecret: "tiebaclient!!!",
            fileContentType: nil
        )
        var headers = requestBuilder.officialHeaders(
            baiduID: account?.baiduID,
            clientVersion: TieBaXRequestPolicy.appClientVersion
        )
        headers["X-BD-DATA-TYPE"] = "protobuf"

        let response = try await client.postProtobuf(
            .hotThreadList,
            body: multipart.body,
            contentType: multipart.contentType,
            headers: headers,
            as: Tieba_HotThreadList_HotThreadListResponse.self
        )
        return try Self.decodeHotThreadPage(from: response)
    }

    static func decodeHotThreadPage(
        from response: Tieba_HotThreadList_HotThreadListResponse
    ) throws -> HotThreadFeedPage {
        try TiebaResponseValidator.validate(
            code: Int(response.error.errorCode),
            message: response.error.userMsg.isEmpty
                ? response.error.errorMsg
                : response.error.userMsg
        )
        // A successful response may omit `data` when the selected category has
        // no entries. Decode that as an empty page; the caller decides whether
        // to use the V12 compatibility retry while preserving this response's
        // exact `threadInfo` cardinality when no retry is available.
        guard response.hasData else {
            return HotThreadFeedPage(
                topics: [],
                tabs: [],
                threads: [],
                serverThreadCount: 0
            )
        }

        let data = response.data
        let topics = data.topicList.compactMap { topic -> HotTopicSummary? in
            let name = topic.topicName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { return nil }
            let id = topic.topicId == 0 ? name : String(topic.topicId)
            return HotTopicSummary(
                id: id,
                name: name,
                description: topic.topicDesc.trimmingCharacters(in: .whitespacesAndNewlines),
                tag: Int(topic.tag),
                discussCount: Int(topic.discussNum),
                imageURL: TiebaURL.image(topic.topicPic)
            )
        }
        let tabs = data.hotThreadTabInfo.compactMap { tab -> HotThreadTab? in
            let tabCode = tab.tabCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = [tab.tabName, tab.tabTitle]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.isEmpty == false } ?? "热门"
            guard tabCode.isEmpty == false else { return nil }
            return HotThreadTab(
                id: tabCode,
                title: title,
                code: tabCode,
                isDefault: tab.isDefault != 0
            )
        }

        // TiebaLite renders every ThreadInfo returned by hotThreadList. This
        // endpoint already supplies the ranked/curated set; applying the
        // timeline's live/deleted filter here silently reduced the number of
        // posts in each category, so preserve the server list verbatim.
        let threads = data.threadInfo.map { ThreadMapper.fromThreadInfo($0, usersByID: [:]) }
        return HotThreadFeedPage(topics: topics, tabs: tabs, threads: threads, serverThreadCount: data.threadInfo.count)
    }
}
