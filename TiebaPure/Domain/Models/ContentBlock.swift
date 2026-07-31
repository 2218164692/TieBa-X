import Foundation

enum ContentBlock: Equatable, Sendable {
    case text(String)
    case link(title: String, url: URL?)
    case mention(userID: Int64?, text: String)
    case emoticon(code: String)
    case image(ImageContent)
    case video(VideoContent)
    case voice(VoiceContent)

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

struct VoiceContent: Equatable, Sendable {
    let md5: String
    let durationMilliseconds: Int

    init?(md5: String, durationMilliseconds: Int) {
        let normalizedMD5 = md5
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedMD5.utf8.count == 32,
              normalizedMD5.utf8.allSatisfy(Self.isLowercaseHexDigit) else {
            return nil
        }

        self.md5 = normalizedMD5
        self.durationMilliseconds = max(durationMilliseconds, 0)
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

struct ImageContent: Equatable, Sendable {
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

struct VideoContent: Equatable, Sendable {
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
