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

        // TiebaLite renders this one V11 response verbatim. Do not issue a
        // second V12 request when the response is empty or has no data: that
        // changes the ranked collection and makes the visible count differ
        // from the server's `threadInfo` repeated field.
        return try Self.decodeHotThreadPage(from: response)
    }
}

private extension TiebaAPI {
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
        // no entries. TiebaLite treats that as an empty page, so preserve the
        // same cardinality instead of falling back to another API contract.
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
