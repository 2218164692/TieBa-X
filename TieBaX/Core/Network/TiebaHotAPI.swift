import Foundation

extension TiebaAPI {
    /// Loads the same public hot-topic directory used by TiebaLite's Explore
    /// tab. The endpoint is intentionally kept separate from the protobuf
    /// thread reader because Baidu returns this directory as JSON.
    func hotTopics() async throws -> [HotTopicSummary] {
        let data = try await client.getRaw(
            .hotMessageList,
            queryItems: [],
            headers: [
                "Accept": "application/json, text/plain, */*",
                "User-Agent": "bdtb for Android \(TieBaXRequestPolicy.miniClientVersion)",
                "Referer": "https://tieba.baidu.com/index/tbwise/hot?source=index"
            ]
        )
        guard let root = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw TiebaAPIError.emptyResponse
        }

        let errorCode = HotTopicJSON.integer(
            root["no"] ?? root["error_code"] ?? root["errno"]
        ) ?? 0
        let errorMessage = HotTopicJSON.string(
            root["error"] ?? root["error_msg"] ?? root["errmsg"]
        ) ?? ""
        try TiebaResponseValidator.validate(code: errorCode, message: errorMessage)

        let ret = HotTopicJSON.items(in: root)
        var seen = Set<String>()
        return ret.compactMap { item in
            let info = item["topic_info"] as? [String: Any]
            let id = HotTopicJSON.string(
                item["mul_id"] ?? item["topic_id"] ?? item["id"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = HotTopicJSON.string(
                item["mul_name"] ?? item["topic_name"] ?? item["name"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = HotTopicJSON.string(
                info?["topic_desc"]
                    ?? info?["description"]
                    ?? item["topic_desc"]
                    ?? item["description"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard id.isEmpty == false,
                  name.isEmpty == false,
                  seen.insert(id).inserted else {
                return nil
            }
            return HotTopicSummary(id: id, name: name, description: description)
        }
    }
}

private enum HotTopicJSON {
    static func items(in root: [String: Any]) -> [[String: Any]] {
        if let data = root["data"] as? [String: Any],
           let list = data["list"] as? [String: Any],
           let array = list["ret"] as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let data = root["data"] as? [String: Any],
           let array = data["ret"] as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let array = root["ret"] as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case let value as Int:
            return String(value)
        case let value as Int64:
            return String(value)
        default:
            return nil
        }
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Int64 {
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
