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
        var bestEmptyPage: HotThreadFeedPage?
        var firstError: Error?

        do {
            let page = try await hotThreadsV11(code: code, identity: nil)
            if page.threads.isEmpty == false { return page }
            bestEmptyPage = page
        } catch {
            try Task.checkCancellation()
            firstError = error
        }

        // TiebaLite initializes ClientUtils through the public /c/s/sync
        // route. On a fresh install the first hotThreadList call can return a
        // successful but empty envelope until that server-issued client_id
        // and sample_id are present. Keep the board anonymous: synchronize a
        // device identity only after an empty V11 response, then retry the
        // exact same public endpoint without BDUSS/STOKEN.
        do {
            let identity = try await synchronizeHotThreadIdentity()
            let page = try await hotThreadsV11(code: code, identity: identity)
            if page.threads.isEmpty == false { return page }
            if Self.hotThreadMetadataCount(page) > Self.hotThreadMetadataCount(bestEmptyPage) {
                bestEmptyPage = page
            }
        } catch {
            try Task.checkCancellation()
            if firstError == nil { firstError = error }
        }

        do {
            let page = try await hotThreadsV12Fallback(code: code)
            if page.threads.isEmpty == false { return page }
            if Self.hotThreadMetadataCount(page) > Self.hotThreadMetadataCount(bestEmptyPage) {
                bestEmptyPage = page
            }
        } catch {
            try Task.checkCancellation()
            if firstError == nil { firstError = error }
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

private struct TiebaHotThreadClientIdentity: Sendable {
    let clientID: String
    let sampleID: String
}

private extension TiebaAPI {
    func hotThreadsV11(
        code: String,
        identity: TiebaHotThreadClientIdentity?
    ) async throws -> HotThreadFeedPage {
        var requestData = Tieba_HotThreadList_HotThreadListRequestData()
        requestData.common = requestBuilder.v11Common(
            account: nil,
            clientID: identity?.clientID,
            sampleID: identity?.sampleID ?? ""
        )
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
            additionalFields: requestBuilder.v11CommonFields(
                account: nil,
                clientID: identity?.clientID
            ),
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
                "Cookie": "CUID=\(cuid);ka=open;TBBRAND=\(UIDevice.current.model);",
                "CUID": cuid,
                "cuid_galaxy2": cuid,
                "c3_aid": requestBuilder.officialAID,
                "cuid_gid": "",
                "User-Agent": "bdtb for Android \(TieBaXRequestPolicy.officialClientVersion)",
                "x_bd_data_type": "protobuf"
            ],
            as: Tieba_HotThreadList_HotThreadListResponse.self
        )
        return try Self.decodeHotThreadPage(from: response)
    }

    func synchronizeHotThreadIdentity() async throws -> TiebaHotThreadClientIdentity {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let imei = "000000000000000"
        let androidID = String(requestBuilder.clientID.prefix(16)).padding(
            toLength: 16,
            withPad: "0",
            startingAt: 0
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMdd"

        // This is the deterministic no-error branch of TiebaLite's
        // StParamInterceptor. All remaining names mirror OfficialTiebaApi.sync
        // plus OFFICIAL_TIEBA_API's common form interceptor.
        let fields: [String: String] = [
            "_client_type": "2",
            "_client_version": TieBaXRequestPolicy.officialClientVersion,
            "_msg_status": "1",
            "_os_version": TiebaRequestBuilder.v11AndroidSDKVersion,
            "_phone_screen": "\(requestBuilder.screenWidth),\(requestBuilder.screenHeight)",
            "_pic_quality": "0",
            "active_timestamp": "\(timestamp)",
            "board": "iPhone",
            "brand": "Apple",
            "c3_aid": requestBuilder.officialAID,
            "cam": Data("02:00:00:00:00:00".utf8).base64EncodedString(),
            "cmode": "1",
            "cuid": requestBuilder.officialCUID,
            "cuid_galaxy2": requestBuilder.officialCUID,
            "cuid_gid": "",
            "di_diordna": Data(androidID.utf8).base64EncodedString(),
            "event_day": formatter.string(from: Date()),
            "extra": "",
            "first_install_time": "0",
            "framework_ver": "3340042",
            "from": "tieba",
            "iemi": Data(imei.utf8).base64EncodedString(),
            "incremental": "0",
            "is_teenager": "0",
            "last_update_time": "0",
            "md5": "F86F4C238491AB3BEBFA33AC42C1582B",
            "model": UIDevice.current.model,
            "net_type": "1",
            "package": "com.baidu.tieba",
            "running_abi": "64",
            "scr_dip": "\(requestBuilder.screenScale)",
            "scr_h": "\(requestBuilder.screenHeight)",
            "scr_w": "\(requestBuilder.screenWidth)",
            "signmd5": "225172691",
            "stErrorNums": "0",
            "start_scheme": "",
            "start_type": "1",
            "support_abi": "64",
            "timestamp": "\(timestamp)",
            "versioncode": "202965248"
        ]
        // TiebaLite appends sign after the sorted ordinary FormBody fields.
        let signature = TiebaFormSigner.sign(fields: fields, secret: "tiebaclient!!!")
        var orderedFields = fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        orderedFields.append(("sign", signature))

        let data = try await client.postRaw(
            .sync,
            body: TiebaPostingCrypto.formBody(orderedFields),
            contentType: "application/x-www-form-urlencoded",
            headers: [
                "Cookie": "ka=open",
                "User-Agent": "bdtb for Android \(TieBaXRequestPolicy.officialClientVersion)",
                "cuid": requestBuilder.officialCUID,
                "cuid_galaxy2": requestBuilder.officialCUID,
                "cuid_gid": "",
                "c3_aid": requestBuilder.officialAID,
                "client_logid": "\(timestamp)"
            ]
        )
        let object = try Self.hotThreadJSONObject(data)
        let code = Self.hotThreadFlexibleInt(object["error_code"])
        guard code == 0,
              let clientObject = object["client"] as? [String: Any],
              let configObject = object["wl_config"] as? [String: Any],
              let clientID = Self.validHotThreadIdentityValue(
                  clientObject["client_id"],
                  maximumBytes: 512
              ),
              let sampleID = Self.validHotThreadIdentityValue(
                  configObject["sample_id"],
                  maximumBytes: 8_192
              ) else {
            throw TiebaAPIError.emptyResponse
        }
        return TiebaHotThreadClientIdentity(clientID: clientID, sampleID: sampleID)
    }

    static func hotThreadJSONObject(_ data: Data) throws -> [String: Any] {
        guard data.isEmpty == false,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TiebaAPIError.emptyResponse
        }
        return object
    }

    static func hotThreadFlexibleInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func validHotThreadIdentityValue(
        _ value: Any?,
        maximumBytes: Int
    ) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.utf8.count <= maximumBytes,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return nil
        }
        return trimmed
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
        headers["x_bd_data_type"] = "protobuf"

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
