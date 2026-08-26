import Foundation

extension TiebaAPI {
    /// Loads the same public hot-topic directory used by TiebaLite's Explore
    /// tab. The endpoint is intentionally kept separate from the protobuf
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
    var errorCode = 0
    var errorMessage = ""
    var data = DataDTO()

    enum CodingKeys: String, CodingKey {
        case errorCode = "no"
        case errorMessage = "error"
        case data
    }

    init() {}

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            return
        }
        errorCode = Int(container.decodeStringIfPresent(forKey: .errorCode) ?? "") ?? 0
        errorMessage = container.decodeStringIfPresent(forKey: .errorMessage) ?? ""
        data = (try? container.decode(DataDTO.self, forKey: .data)) ?? DataDTO()
    }

    struct DataDTO: Decodable {
        var list = ListDTO()

        enum CodingKeys: String, CodingKey {
            case list
            case ret
        }

        init() {}

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                return
            }
            if let object = try? container.decode(ListDTO.self, forKey: .list) {
                list = object
            } else if let array = try? container.decode([TopicDTO].self, forKey: .list) {
                list = ListDTO(ret: array)
            } else if let array = try? container.decode([TopicDTO].self, forKey: .ret) {
                list = ListDTO(ret: array)
            }
        }
    }

    struct ListDTO: Decodable {
        var ret: [TopicDTO] = []

        enum CodingKeys: String, CodingKey {
            case ret
        }

        init() {}

        init(ret: [TopicDTO]) {
            self.ret = ret
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                return
            }
            // TopicDTO is deliberately loss-tolerant. This keeps valid
            // entries when a future server response contains one malformed
            // or non-object item in the same array.
            ret = (try? container.decode([TopicDTO].self, forKey: .ret)) ?? []
        }
    }

    struct TopicDTO: Decodable {
        var topicID = ""
        var topicName = ""
        var topicDescription = ""

        enum CodingKeys: String, CodingKey {
            case topicID = "mul_id"
            case topicIDAlt = "topic_id"
            case id
            case topicName = "mul_name"
            case topicNameAlt = "topic_name"
            case name
            case topicInfo = "topic_info"
            case topicDescription = "topic_desc"
            case description
        }

        enum TopicInfoCodingKeys: String, CodingKey {
            case topicDescription = "topic_desc"
            case description
        }

        init() {}

        init(from decoder: Decoder) throws {
            // Some deployments have returned a null/string placeholder in
            // ret. Treat that item as empty instead of failing the whole list.
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                return
            }

            topicID = container.decodeStringIfPresent(forKey: .topicID)
                ?? container.decodeStringIfPresent(forKey: .topicIDAlt)
                ?? container.decodeStringIfPresent(forKey: .id)
                ?? ""
            topicName = container.decodeStringIfPresent(forKey: .topicName)
                ?? container.decodeStringIfPresent(forKey: .topicNameAlt)
                ?? container.decodeStringIfPresent(forKey: .name)
                ?? ""

            if let topicInfo = try? container.nestedContainer(
                keyedBy: TopicInfoCodingKeys.self,
                forKey: .topicInfo
            ) {
                topicDescription = topicInfo.decodeStringIfPresent(forKey: .topicDescription)
                    ?? topicInfo.decodeStringIfPresent(forKey: .description)
                    ?? ""
            }
            if topicDescription.isEmpty {
                topicDescription = container.decodeStringIfPresent(forKey: .topicDescription)
                    ?? container.decodeStringIfPresent(forKey: .description)
                    ?? ""
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
