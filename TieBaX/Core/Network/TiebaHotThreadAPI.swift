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

        let primaryPage: HotThreadFeedPage
        do {
            primaryPage = try Self.decodeHotThreadPage(from: response)
        } catch {
            // A V11 envelope can be rejected by a server shard while the
            // equivalent V12 protobuf route still returns the feed.
            return try await hotThreadsV12Fallback(account: account, code: code)
        }
        guard primaryPage.threads.isEmpty else { return primaryPage }
        do {
            return try await hotThreadsV12Fallback(account: account, code: code)
        } catch {
            // Preserve valid metadata; ExploreView will try TiebaLite's
            // stable category codes when this page is genuinely empty.
            return primaryPage
        }
    }
}

private extension TiebaAPI {
    func hotThreadsV12Fallback(
        account: Account?,
        code: String
    ) async throws -> HotThreadFeedPage {
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
        guard response.hasData else { throw TiebaAPIError.emptyResponse }

        let data = response.data
        let topics = data.topicList.compactMap { topic -> HotTopicSummary? in
            let name = topic.topicName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { return nil }
            let id = topic.topicId == 0 ? name : String(topic.topicId)
            return HotTopicSummary(
                id: id,
                name: name,
                description: topic.topicDesc.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Some server responses use a thread type that the normal timeline
        // filter does not recognize. Keep the raw records when filtering
        // would otherwise make a valid hot page appear empty.
        let rawThreads = data.threadInfo
        let filteredThreads = rawThreads.filter(TiebaContentFilter.shouldMap(thread:))
        let mappedThreads = filteredThreads.isEmpty && rawThreads.isEmpty == false
            ? rawThreads
            : filteredThreads
        let threads = mappedThreads.map { ThreadMapper.fromThreadInfo($0, usersByID: [:]) }
        return HotThreadFeedPage(topics: topics, tabs: tabs, threads: threads)
    }
}
