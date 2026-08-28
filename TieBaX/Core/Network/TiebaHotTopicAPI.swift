import Foundation
import UIKit

/// JSON transport for Explore > 热榜 > 话题详情. TiebaLite uses this public
/// endpoint instead of turning a topic into a global search query.
extension TiebaAPI {
    func hotTopicDetail(
        account: Account?,
        topicID: String,
        topicName: String,
        page: Int,
        pageSize: Int,
        offset: Int,
        lastID: String
    ) async throws -> HotTopicDetailPage {
        let requestedID = topicID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = topicName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedID.isEmpty == false, requestedName.isEmpty == false else {
            throw TiebaAPIError.emptyResponse
        }

        let safePage = min(max(page, 1), Int(Int32.max))
        let safePageSize = min(max(pageSize, 1), 100)
        let safeOffset = max(offset, 0)
        // Keep the header ASCII-only; the topic values are already carried
        // in the encoded query items below.
        let referer = "https://tieba.baidu.com/mo/q/newtopic/topicDetail"
        let queryItems = [
            URLQueryItem(name: "topic_id", value: requestedID),
            URLQueryItem(name: "topic_name", value: requestedName),
            URLQueryItem(name: "is_new", value: "1"),
            URLQueryItem(name: "is_share", value: "1"),
            URLQueryItem(name: "pn", value: String(safePage)),
            URLQueryItem(name: "rn", value: String(safePageSize)),
            URLQueryItem(name: "offset", value: String(safeOffset)),
            URLQueryItem(name: "last_id", value: lastID),
            URLQueryItem(name: "derivative_to_pic_id", value: "")
        ]

        var headers = requestBuilder.officialJSONHeaders(
            baiduID: account?.baiduID,
            clientVersion: TieBaXRequestPolicy.officialJSONClientVersion,
            accountUID: account?.uid
        )
        var cookie = account?.minimalCookieHeader ?? ""
        if cookie.isEmpty == false {
            cookie += "; "
        }
        cookie += "CUID=\(requestBuilder.officialCUID); ka=open; TBBRAND=\(UIDevice.current.model)"
        headers["Cookie"] = cookie
        headers["Accept"] = "application/json, text/plain, */*"
        headers["Referer"] = referer

        let raw = try await client.getRaw(
            .hotTopicDetail,
            queryItems: queryItems,
            headers: headers
        )
        guard let root = try JSONSerialization.jsonObject(
            with: raw,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw TiebaAPIError.emptyResponse
        }

        let code = HotTopicDetailJSON.integer(root["no"] ?? root["error_code"] ?? root["errno"]) ?? 0
        let message = HotTopicDetailJSON.string(
            root["error"] ?? root["error_msg"] ?? root["errmsg"]
        ) ?? ""
        try TiebaResponseValidator.validate(code: code, message: message)

        let payload = HotTopicDetailJSON.dictionary(root["data"]) ?? root
        let topicInfo = HotTopicDetailJSON.dictionary(payload["topic_info"])
            ?? HotTopicDetailJSON.dictionary(payload["topicInfo"])
            ?? HotTopicDetailJSON.dictionary(payload["topic"])
            ?? [:]
        let topic = HotTopicDetailJSON.topic(
            from: topicInfo,
            fallbackID: requestedID,
            fallbackName: requestedName
        )

        let relateThread = HotTopicDetailJSON.dictionary(payload["relate_thread"])
            ?? HotTopicDetailJSON.dictionary(payload["relateThread"])
        let rawThreads = HotTopicDetailJSON.dictionaries(
            relateThread?["thread_list"]
                ?? relateThread?["threadList"]
                ?? payload["thread_list"]
                ?? payload["threadList"]
        )
        let threads = rawThreads.compactMap(HotTopicDetailJSON.thread)
        let wreq = HotTopicDetailJSON.dictionary(payload["wreq"])
        let currentPage = HotTopicDetailJSON.integer(
            wreq?["pn"] ?? wreq?["page"] ?? payload["pn"] ?? payload["page"]
        ) ?? safePage
        let hasMore = HotTopicDetailJSON.boolean(
            payload["has_more"] ?? payload["hasMore"]
                ?? wreq?["has_more"] ?? wreq?["hasMore"]
                ?? relateThread?["has_more"] ?? relateThread?["hasMore"]
        ) ?? false
        let responseLastID = HotTopicDetailJSON.string(
            payload["last_id"] ?? payload["lastId"]
                ?? wreq?["last_id"] ?? wreq?["lastId"]
                ?? relateThread?["last_id"] ?? relateThread?["lastId"]
        ) ?? threads.last.map { String($0.id) } ?? ""

        return HotTopicDetailPage(
            topic: topic,
            threads: threads,
            currentPage: max(currentPage, 1),
            hasMore: hasMore,
            lastID: responseLastID
        )
    }
}

private enum HotTopicDetailJSON {
    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func dictionaries(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let dictionary = value as? [String: Any] {
            for key in ["list", "items", "media", "media_list", "pic_list", "thread_list"] {
                if let nested = dictionary[key] {
                    let values = dictionaries(nested)
                    if values.isEmpty == false {
                        return values
                    }
                }
            }
            return dictionary.values.compactMap { $0 as? [String: Any] }
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
        case let value as Double:
            return String(Int64(value))
        default:
            return nil
        }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let value = integer64(value) else { return nil }
        return Int(exactly: value) ?? Int(value)
    }

    static func integer64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int32:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as UInt64:
            return value <= UInt64(Int64.max) ? Int64(value) : nil
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int64(trimmed) ?? (Double(trimmed).map { Int64($0) })
        default:
            return nil
        }
    }

    static func boolean(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    static func text(_ value: Any?) -> String? {
        if let string = string(value) { return string }
        if let dictionary = dictionary(value) {
            for key in ["text", "content", "abstract", "desc", "description", "title"] {
                if let result = text(dictionary[key]), result.isEmpty == false {
                    return result
                }
            }
        }
        if let values = value as? [Any] {
            let result = values.compactMap(text).joined()
            return result.isEmpty ? nil : result
        }
        return nil
    }

    static func topic(
        from info: [String: Any],
        fallbackID: String,
        fallbackName: String
    ) -> HotTopicSummary {
        let id = (string(
            info["topic_id"] ?? info["topicId"] ?? info["mul_id"] ?? info["id"]
        ) ?? fallbackID).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (string(
            info["topic_name"] ?? info["topicName"] ?? info["mul_name"] ?? info["name"]
        ) ?? fallbackName).trimmingCharacters(in: .whitespacesAndNewlines)
        let description = text(
            info["topic_desc"] ?? info["topicDesc"] ?? info["description"] ?? info["desc"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HotTopicSummary(
            id: id.isEmpty ? fallbackID : id,
            name: name.isEmpty ? fallbackName : name,
            description: description,
            tag: integer(info["tag"] ?? info["topic_tag"]) ?? 0,
            discussCount: integer(
                info["discuss_num"] ?? info["discussNum"] ?? info["discuss_count"]
            ) ?? 0,
            imageURL: TiebaURL.image(
                string(info["topic_image"] ?? info["topicImage"] ?? info["topic_pic"])
            )
        )
    }

    static func thread(_ item: [String: Any]) -> ThreadSummary? {
        let info = dictionary(item["thread_info"] ?? item["threadInfo"]) ?? item
        let threadID = integer64(
            info["tid"] ?? info["thread_id"] ?? info["threadId"] ?? info["id"]
                ?? info["feed_id"] ?? item["feed_id"] ?? item["tid"]
        ) ?? 0
        guard threadID != 0 else { return nil }

        let authorInfo = dictionary(info["author"])
            ?? dictionary(item["author"])
            ?? dictionary(info["user"])
            ?? dictionary(item["user"])
            ?? [:]
        let authorID = integer64(
            info["user_id"] ?? info["userId"] ?? authorInfo["user_id"]
                ?? authorInfo["userId"] ?? authorInfo["id"]
        ) ?? 0
        let name = string(
            authorInfo["name"] ?? authorInfo["name_show"] ?? authorInfo["nameShow"]
                ?? info["user_name"] ?? info["username"]
        ) ?? ""
        let displayName = string(
            authorInfo["name_show"] ?? authorInfo["nameShow"] ?? authorInfo["name"]
        ) ?? name
        let portrait = string(
            authorInfo["portrait"] ?? authorInfo["portraith"] ?? authorInfo["portrait_h"]
                ?? info["portrait"]
        ) ?? ""
        let author = UserSummary(
            id: authorID,
            name: name,
            displayName: displayName,
            portrait: portrait
        )

        let title = text(info["title"] ?? item["title"]) ?? ""
        let abstract = text(
            info["abstract"] ?? info["content"] ?? info["summary"]
                ?? item["abstract"] ?? item["content"]
        ) ?? ""
        var blocks = abstract.isEmpty ? [] : TiebaEmoticon.blocks(from: abstract)
        let mediaValue = info["media"] ?? info["media_list"] ?? item["media"]
        blocks.append(contentsOf: dictionaries(mediaValue).compactMap(mediaBlock))

        let forumInfo = dictionary(info["forum_info"] ?? item["forum_info"])
        let forumID = integer64(
            info["forum_id"] ?? info["forumId"] ?? forumInfo?["id"]
        )
        let forumName = string(
            info["forum_name"] ?? info["forumName"] ?? forumInfo?["name"]
        )
        let forumAvatar = TiebaURL.avatar(
            string(forumInfo?["avatar"] ?? forumInfo?["avatar_url"] ?? info["forum_avatar"])
        )
        let agree = dictionary(info["agree"] ?? item["agree"])
        let liked = boolean(
            info["user_agree"] ?? info["userAgree"] ?? agree?["has_agree"] ?? agree?["hasAgree"]
        ) ?? false
        let likeCount = integer(
            info["agree_num"] ?? info["agreeNum"] ?? agree?["agree_num"] ?? agree?["agreeNum"]
        ) ?? 0
        let replyCount = integer(info["reply_num"] ?? info["replyNum"]) ?? 0
        let firstPostID = integer64(info["first_post_id"] ?? info["firstPostId"])
            .flatMap { $0 > 0 ? UInt64($0) : nil }
        let createdAt = date(info["create_time"] ?? info["createTime"])
        let lastReplyAt = date(info["last_time_int"] ?? info["lastTimeInt"])
        let hasVideo = blocks.contains { block in
            if case .video = block { return true }
            return false
        }
        let hotNum = integer(info["hot_num"] ?? info["hotNum"])

        return ThreadSummary(
            id: threadID,
            forumID: forumID,
            title: title,
            author: author,
            forumName: forumName,
            forumAvatarURL: forumAvatar,
            replyCount: max(replyCount, 0),
            viewCount: max(integer(info["view_num"] ?? info["viewNum"]) ?? 0, 0),
            likeCount: max(likeCount, 0),
            firstPostID: firstPostID,
            isLiked: liked,
            createdAt: createdAt,
            lastReplyAt: lastReplyAt,
            blocks: blocks,
            isTop: false,
            isGood: false,
            hasVideo: hasVideo,
            hotNum: hotNum
        )
    }

    static func mediaBlock(_ value: [String: Any]) -> ContentBlock? {
        let type = (string(value["type"] ?? value["media_type"] ?? value["mediaType"]) ?? "")
            .lowercased()
        let width = max(integer(value["width"] ?? value["w"]) ?? 1, 1)
        let height = max(integer(value["height"] ?? value["h"]) ?? 1, 1)
        let videoURL = TiebaURL.video(string(
            value["vhsrc"] ?? value["vsrc"] ?? value["video_url"] ?? value["videoURL"]
        ))
        let coverURL = TiebaURL.image(string(
            value["vpic"] ?? value["video_pic"] ?? value["videoPic"]
                ?? value["big_pic"] ?? value["small_pic"]
        ))
        if type == "flash" || type == "video" || videoURL != nil {
            return .video(VideoContent(
                videoURL: videoURL,
                coverURL: coverURL,
                webURL: nil,
                width: width,
                height: height,
                duration: max(integer(value["duration"] ?? value["during_time"]) ?? 0, 0)
            ))
        }

        let thumbnailURL = TiebaURL.image(string(
            value["small_pic"] ?? value["big_pic"] ?? value["water_pic"]
                ?? value["origin_pic"] ?? value["src"]
        ))
        let originalURL = TiebaURL.image(string(
            value["big_pic"] ?? value["origin_pic"] ?? value["src"]
                ?? value["small_pic"]
        ))
        guard thumbnailURL != nil || originalURL != nil else { return nil }
        return .image(ImageContent(
            thumbnailURL: thumbnailURL,
            originalURL: originalURL,
            width: width,
            height: height,
            showOriginalButton: true
        ))
    }

    static func date(_ value: Any?) -> Date? {
        guard let timestamp = integer64(value), timestamp > 0 else { return nil }
        let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1_000 : Double(timestamp)
        return Date(timeIntervalSince1970: seconds)
    }
}
