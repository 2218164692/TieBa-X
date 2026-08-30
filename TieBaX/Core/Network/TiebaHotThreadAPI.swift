import Foundation
import UIKit

/// Official protobuf hot-thread feed used by TiebaLite's Explore > 热门 page.
/// The older `hotTopics()` JSON call is kept for a separate topic directory;
/// it is not used as the primary hot feed anymore.
extension TiebaAPI {
    func hotThreads(account: Account?, tabCode: String) async throws -> HotThreadFeedPage {
        let requestedCode = tabCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = requestedCode.isEmpty ? "all" : String(requestedCode.prefix(32))

        // hotThreadList is a public board in TiebaLite. The service protocol
        // still carries `account` for API compatibility, but this endpoint
        // must not send BDUSS/STOKEN or depend on the current login session.
        _ = account
        let variants: [HotThreadRequestVariant] = [.v11, .v12]

        var bestEmptyPage: HotThreadFeedPage?
        var firstError: Error?
        for variant in variants {
            do {
                let page: HotThreadFeedPage
                switch variant {
                case .v11:
                    page = try await hotThreadsV11(code: code)
                case .v12:
                    page = try await hotThreadsV12Fallback(code: code)
                }

                if page.threads.isEmpty == false {
                    return page
                }
                if Self.hotThreadMetadataCount(page) > Self.hotThreadMetadataCount(bestEmptyPage) {
                    bestEmptyPage = page
                }
            } catch {
                try Task.checkCancellation()
                if firstError == nil {
                    firstError = error
                }
            }
        }

        // A successful empty response is more precise than a later transport
        // failure. Keep its topic/tab metadata so the UI can still render the
        // server board instead of showing a misleading network error.
        if let bestEmptyPage {
            return bestEmptyPage
        }
        throw firstError ?? TiebaAPIError.emptyResponse
    }
}

private enum HotThreadRequestVariant {
    case v11
    case v12
}

private extension TiebaAPI {
    func hotThreadsV11(code: String) async throws -> HotThreadFeedPage {
        var requestData = Tieba_HotThreadList_HotThreadListRequestData()
        requestData.common = requestBuilder.v11Common(account: nil)
        requestData.tabId = "1"
        requestData.tabCode = code

        var request = Tieba_HotThreadList_HotThreadListRequest()
        request.data = requestData

        // TiebaLite uses the V11 protobuf envelope for hotThreadList. The
        // endpoint expects the signed common form fields appended to the
        // multipart body by its Android interceptors.
        let multipart = try requestBuilder.multipart(
            protobuf: request,
            account: nil,
            includeSToken: false,
            clientVersion: TieBaXRequestPolicy.officialClientVersion,
            additionalFields: requestBuilder.v11CommonFields(account: nil),
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
                "client_user_token": "",
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
        return try Self.decodeHotThreadPage(from: response)
    }

    static func hotThreadMetadataCount(_ page: HotThreadFeedPage?) -> Int {
        guard let page else { return -1 }
        return page.topics.count + page.tabs.count
    }

    /// V12-compatible retry for installations whose V11 hotThreadList reply
    /// omits the ranked payload. This is the same protobuf endpoint and
    /// request shape used by the previous TiebaLite-compatible implementation;
    /// it is deliberately only attempted after an empty/undecodable V11 page.
    func hotThreadsV12Fallback(code: String) async throws -> HotThreadFeedPage {
        var requestData = Tieba_HotThreadList_HotThreadListRequestData()
        requestData.common = requestBuilder.common(account: nil)
        requestData.tabId = "1"
        requestData.tabCode = code

        var request = Tieba_HotThreadList_HotThreadListRequest()
        request.data = requestData

        let multipart = try requestBuilder.multipart(
            protobuf: request,
            account: nil,
            includeSToken: false,
            clientVersion: TieBaXRequestPolicy.appClientVersion,
            additionalFields: requestBuilder.officialCommonFields(
                bduss: nil,
                baiduID: nil,
                clientVersion: TieBaXRequestPolicy.appClientVersion
            ),
            signingSecret: "tiebaclient!!!",
            fileContentType: nil
        )
        var headers = requestBuilder.officialHeaders(
            baiduID: nil,
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
