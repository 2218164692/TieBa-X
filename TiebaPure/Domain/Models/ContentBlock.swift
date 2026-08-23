import Foundation

enum ContentBlock: Equatable, Codable, Sendable {
    case text(String)
    case link(title: String, url: URL?)
    case mention(userID: Int64?, text: String)
    case emoticon(code: String)
    case image(ImageContent)
    case video(VideoContent)
    case voice(VoiceContent)

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case title
        case url
        case userID
        case code
        case image
        case video
        case voice
    }

    private enum Kind: String, Codable {
        case text
        case link
        case mention
        case emoticon
        case image
        case video
        case voice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .link:
            self = .link(
                title: try container.decode(String.self, forKey: .title),
                url: try container.decodeIfPresent(URL.self, forKey: .url)
            )
        case .mention:
            self = .mention(
                userID: try container.decodeIfPresent(Int64.self, forKey: .userID),
                text: try container.decode(String.self, forKey: .text)
            )
        case .emoticon:
            self = .emoticon(code: try container.decode(String.self, forKey: .code))
        case .image:
            self = .image(try container.decode(ImageContent.self, forKey: .image))
        case .video:
            self = .video(try container.decode(VideoContent.self, forKey: .video))
        case .voice:
            self = .voice(try container.decode(VoiceContent.self, forKey: .voice))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case let .link(title, url):
            try container.encode(Kind.link, forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(url, forKey: .url)
        case let .mention(userID, text):
            try container.encode(Kind.mention, forKey: .kind)
            try container.encodeIfPresent(userID, forKey: .userID)
            try container.encode(text, forKey: .text)
        case let .emoticon(code):
            try container.encode(Kind.emoticon, forKey: .kind)
            try container.encode(code, forKey: .code)
        case let .image(image):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(image, forKey: .image)
        case let .video(video):
            try container.encode(Kind.video, forKey: .kind)
            try container.encode(video, forKey: .video)
        case let .voice(voice):
            try container.encode(Kind.voice, forKey: .kind)
            try container.encode(voice, forKey: .voice)
        }
    }

    var plainText: String? {
        switch self {
        case let .text(text):
            return text
        case let .link(title, url):
            return title.isEmpty ? url?.absoluteString : title
        case let .mention(_, text):
            return text
        case let .emoticon(code):
            return TiebaEmoticon.displayText(for: code)
        case .voice:
            return "[语音]"
        case .image, .video:
            return nil
        }
    }
}

struct VoiceContent: Equatable, Codable, Sendable {
    let md5: String
    let durationMilliseconds: Int
    var localURL: URL?
    var offlineOnly: Bool?

    init?(
        md5: String,
        durationMilliseconds: Int,
        localURL: URL? = nil,
        offlineOnly: Bool? = nil
    ) {
        let normalizedMD5 = md5
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedMD5.utf8.count == 32,
              normalizedMD5.utf8.allSatisfy(Self.isLowercaseHexDigit) else {
            return nil
        }

        self.md5 = normalizedMD5
        self.durationMilliseconds = max(durationMilliseconds, 0)
        self.localURL = localURL
        self.offlineOnly = offlineOnly
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

struct ImageContent: Equatable, Codable, Sendable {
    var thumbnailURL: URL?
    var originalURL: URL?
    var width: Int
    var height: Int
    var showOriginalButton: Bool

    var aspectRatio: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }
}

struct VideoContent: Equatable, Codable, Sendable {
    var videoURL: URL?
    var coverURL: URL?
    var webURL: URL?
    var width: Int
    var height: Int
    var duration: Int

    var aspectRatio: Double {
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return Double(width) / Double(height)
    }
}
