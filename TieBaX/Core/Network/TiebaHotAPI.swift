import Foundation

extension TiebaAPI {
    /// Loads the same public hot-topic directory used by TiebaLite's Explore
    /// tab.  The endpoint is intentionally kept separate from the protobuf
    /// thread reader because Baidu returns this directory as JSON.
    func hotTopics() async throws -> [HotTopicSummary] {
        let response = try await client.getJSON(
            .hotMessageList,
            queryItems: [],
            headers: [
                "User-Agent": "bdtb for Android \(TieBaXRequestPolicy.miniClientVersion)",
                "Referer": "https://tieba.baidu.com/index/tbwise/hot?source=index"
            ],
            as: HotMessageListResponseDTO.self
        )
        try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)

        var seen = Set<String>()
        return response.data.list.ret.compactMap { item in
            let id = item.topicID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = item.topicName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.isEmpty == false, name.isEmpty == false, seen.insert(id).inserted else {
                return nil
            }
            return HotTopicSummary(
                id: id,
                name: name,
                description: item.topicDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

private struct HotMessageListResponseDTO: Decodable {
    var errorCode: Int
    var errorMessage: String
    var data: DataDTO

    enum CodingKeys: String, CodingKey {
        case errorCode = "no"
        case errorMessage = "error"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = Int(container.decodeStringIfPresent(forKey: .errorCode) ?? "") ?? 0
        errorMessage = container.decodeStringIfPresent(forKey: .errorMessage) ?? ""
        data = try container.decodeIfPresent(DataDTO.self, forKey: .data) ?? DataDTO()
    }

    struct DataDTO: Decodable {
        var list = ListDTO()

        enum CodingKeys: String, CodingKey { case list }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            list = try container.decodeIfPresent(ListDTO.self, forKey: .list) ?? ListDTO()
        }
    }

    struct ListDTO: Decodable {
        var ret: [TopicDTO] = []

        enum CodingKeys: String, CodingKey { case ret }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ret = (try? container.decode([TopicDTO].self, forKey: .ret)) ?? []
        }
    }

    struct TopicDTO: Decodable {
        var topicID = ""
        var topicName = ""
        var topicDescription = ""

        enum CodingKeys: String, CodingKey {
            case topicID = "mul_id"
            case topicName = "mul_name"
            case topicInfo = "topic_info"
        }

        enum TopicInfoCodingKeys: String, CodingKey { case topicDescription = "topic_desc" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            topicID = container.decodeStringIfPresent(forKey: .topicID) ?? ""
            topicName = container.decodeStringIfPresent(forKey: .topicName) ?? ""
            if let topicInfo = try? container.nestedContainer(
                keyedBy: TopicInfoCodingKeys.self,
                forKey: .topicInfo
            ) {
                topicDescription = topicInfo.decodeStringIfPresent(forKey: .topicDescription) ?? ""
            }
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        return nil
    }
}
