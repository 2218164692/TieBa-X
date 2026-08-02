import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ContentSubmissionKind: String, Codable, CaseIterable, Sendable {
    case newThread
    case threadReply
    case postReply
    case subpostReply

    var navigationTitle: String {
        switch self {
        case .newThread:
            return "发布新帖"
        case .threadReply:
            return "回复帖子"
        case .postReply, .subpostReply:
            return "回复用户"
        }
    }
}

struct ContentSubmissionTarget: Codable, Equatable, Hashable, Sendable {
    var kind: ContentSubmissionKind
    var forumID: Int64
    var forumName: String
    var forumDisplayName: String
    var threadID: Int64?
    var threadTitle: String?
    var parentPostID: UInt64?
    var parentFloor: Int?
    var subpostID: UInt64?
    var replyUserID: Int64?
    var replyUserDisplayName: String?
    var replyUserPortrait: String? = nil

    var draftKey: String {
        let components: [String] = [
            kind.rawValue,
            String(forumID),
            threadID.map(String.init) ?? "0",
            parentPostID.map(String.init) ?? "0",
            subpostID.map(String.init) ?? "0",
            replyUserID.map(String.init) ?? "0"
        ]
        return components.joined(separator: ":")
    }

    var prompt: String {
        switch kind {
        case .newThread:
            return "发布到 \(forumDisplayName)"
        case .threadReply:
            return threadTitle.map { "回复《\($0)》" } ?? "回复帖子"
        case .postReply, .subpostReply:
            if let replyUserDisplayName, replyUserDisplayName.isEmpty == false {
                return "回复 \(replyUserDisplayName)"
            }
            if let parentFloor, parentFloor > 0 {
                return "回复第 \(parentFloor) 楼"
            }
            return "回复用户"
        }
    }

    static func newThread(in forum: Forum) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: .newThread,
            forumID: forum.id,
            forumName: forum.name,
            forumDisplayName: forum.displayName,
            threadID: nil,
            threadTitle: nil,
            parentPostID: nil,
            parentFloor: nil,
            subpostID: nil,
            replyUserID: nil,
            replyUserDisplayName: nil
        )
    }

    static func threadReply(thread: ThreadSummary, forum: Forum) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: .threadReply,
            forumID: forum.id,
            forumName: forum.name,
            forumDisplayName: forum.displayName,
            threadID: thread.id,
            threadTitle: thread.title,
            parentPostID: nil,
            parentFloor: nil,
            subpostID: nil,
            replyUserID: nil,
            replyUserDisplayName: nil
        )
    }

    static func postReply(thread: ThreadSummary, forum: Forum, post: Post) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: .postReply,
            forumID: forum.id,
            forumName: forum.name,
            forumDisplayName: forum.displayName,
            threadID: thread.id,
            threadTitle: thread.title,
            parentPostID: post.id,
            parentFloor: post.floor,
            subpostID: nil,
            replyUserID: post.author.id > 0 ? post.author.id : nil,
            replyUserDisplayName: post.author.displayNameResolved,
            replyUserPortrait: post.author.portrait
        )
    }

    static func subpostReply(
        thread: ThreadSummary,
        forum: Forum,
        parentPost: Post,
        subpost: Subpost
    ) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: .subpostReply,
            forumID: forum.id,
            forumName: forum.name,
            forumDisplayName: forum.displayName,
            threadID: thread.id,
            threadTitle: thread.title,
            parentPostID: parentPost.id,
            parentFloor: parentPost.floor,
            subpostID: subpost.id,
            replyUserID: subpost.author.id > 0 ? subpost.author.id : nil,
            replyUserDisplayName: subpost.author.displayNameResolved,
            replyUserPortrait: subpost.author.portrait
        )
    }
}

struct ContentSubmissionImage: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var mimeType: String

    init(
        id: UUID = UUID(),
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        mimeType: String = "image/jpeg"
    ) {
        self.id = id
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mimeType = mimeType
    }
}

struct ContentSubmissionRequest: Equatable, Sendable {
    var target: ContentSubmissionTarget
    var title: String
    var body: String
    var images: [ContentSubmissionImage]
}

struct ContentSubmissionReceipt: Equatable, Sendable {
    var threadID: Int64
    var postID: UInt64?
}

enum ContentSubmissionValidationError: Error, Equatable, LocalizedError {
    case invalidForum
    case invalidThread
    case missingTitle
    case titleTooLong(limit: Int)
    case emptyBody
    case bodyTooLong(limit: Int)
    case tooManyImages(limit: Int)
    case imageTooLarge(limit: Int)
    case invalidImage
    case imagesUnsupportedForNewThread

    var errorDescription: String? {
        switch self {
        case .invalidForum:
            return "贴吧信息不完整，暂时无法发布。"
        case .invalidThread:
            return "帖子信息不完整，暂时无法回复。"
        case .missingTitle:
            return "请输入帖子标题。"
        case let .titleTooLong(limit):
            return "标题不能超过 \(limit) 个字符。"
        case .emptyBody:
            return "请输入正文或添加图片。"
        case let .bodyTooLong(limit):
            return "正文不能超过 \(limit) 个字符。"
        case let .tooManyImages(limit):
            return "一次最多添加 \(limit) 张图片。"
        case let .imageTooLarge(limit):
            return "单张图片不能超过 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))。"
        case .invalidImage:
            return "所选图片无法读取，请重新选择。"
        case .imagesUnsupportedForNewThread:
            return "当前发布新主题仅支持文字和贴吧表情。"
        }
    }
}

enum ContentSubmissionPolicy {
    static let maximumTitleCharacters = 64
    static let maximumBodyCharacters = 10_000
    static let maximumImages = 9
    static let maximumImageBytes = 10 * 1_024 * 1_024
    static let maximumPixelDimension = 20_000
    static let maximumPixelCount = 80_000_000
    static let allowedImageMIMETypes: Set<String> = [
        "image/gif",
        "image/heic",
        "image/heif",
        "image/jpeg",
        "image/png",
        "image/tiff",
        "image/webp"
    ]

    static func validate(_ request: ContentSubmissionRequest) throws {
        try validateFields(request)
        for image in request.images {
            let mimeType = image.mimeType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard image.data.isEmpty == false,
                  image.pixelWidth > 0,
                  image.pixelHeight > 0,
                  allowedImageMIMETypes.contains(mimeType) else {
                throw ContentSubmissionValidationError.invalidImage
            }
            guard image.data.count <= maximumImageBytes else {
                throw ContentSubmissionValidationError.imageTooLarge(limit: maximumImageBytes)
            }
        }
    }

    static func validateForNetwork(_ request: ContentSubmissionRequest) throws {
        try validateFields(request)
        for image in request.images {
            _ = try ContentSubmissionImageInspector.inspect(image.data)
        }
    }

    private static func validateFields(_ request: ContentSubmissionRequest) throws {
        guard request.target.forumID > 0,
              request.target.forumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ContentSubmissionValidationError.invalidForum
        }
        switch request.target.kind {
        case .newThread:
            break
        case .threadReply:
            guard let threadID = request.target.threadID, threadID > 0 else {
                throw ContentSubmissionValidationError.invalidThread
            }
        case .postReply:
            guard let threadID = request.target.threadID, threadID > 0,
                  let parentPostID = request.target.parentPostID, parentPostID > 0 else {
                throw ContentSubmissionValidationError.invalidThread
            }
        case .subpostReply:
            guard let threadID = request.target.threadID, threadID > 0,
                  let parentPostID = request.target.parentPostID, parentPostID > 0,
                  let subpostID = request.target.subpostID, subpostID > 0 else {
                throw ContentSubmissionValidationError.invalidThread
            }
        }

        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.target.kind == .newThread {
            guard title.isEmpty == false else {
                throw ContentSubmissionValidationError.missingTitle
            }
            guard title.count <= maximumTitleCharacters else {
                throw ContentSubmissionValidationError.titleTooLong(limit: maximumTitleCharacters)
            }
            guard request.images.isEmpty else {
                throw ContentSubmissionValidationError.imagesUnsupportedForNewThread
            }
        }

        let body = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false || request.images.isEmpty == false else {
            throw ContentSubmissionValidationError.emptyBody
        }
        guard request.body.count <= maximumBodyCharacters else {
            throw ContentSubmissionValidationError.bodyTooLong(limit: maximumBodyCharacters)
        }
        guard request.images.count <= maximumImages else {
            throw ContentSubmissionValidationError.tooManyImages(limit: maximumImages)
        }
    }
}

struct ContentSubmissionImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let mimeType: String
}

enum ContentSubmissionImageInspector {
    static func inspect(_ data: Data) throws -> ContentSubmissionImageMetadata {
        guard data.isEmpty == false else {
            throw ContentSubmissionValidationError.invalidImage
        }
        guard data.count <= ContentSubmissionPolicy.maximumImageBytes else {
            throw ContentSubmissionValidationError.imageTooLarge(
                limit: ContentSubmissionPolicy.maximumImageBytes
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= ContentSubmissionPolicy.maximumPixelDimension,
              height <= ContentSubmissionPolicy.maximumPixelDimension,
              Int64(width) * Int64(height) <= Int64(ContentSubmissionPolicy.maximumPixelCount),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let mimeType = type.preferredMIMEType?.lowercased(),
              ContentSubmissionPolicy.allowedImageMIMETypes.contains(mimeType) else {
            throw ContentSubmissionValidationError.invalidImage
        }

        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) != nil else {
            throw ContentSubmissionValidationError.invalidImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let displayDimensions = displayPixelDimensions(
            width: width,
            height: height,
            orientation: orientation
        )
        return ContentSubmissionImageMetadata(
            pixelWidth: displayDimensions.width,
            pixelHeight: displayDimensions.height,
            mimeType: mimeType
        )
    }

    static func displayPixelDimensions(
        width: Int,
        height: Int,
        orientation: Int
    ) -> (width: Int, height: Int) {
        (5...8).contains(orientation)
            ? (width: height, height: width)
            : (width: width, height: height)
    }
}

enum ContentSubmissionError: Error, Equatable, LocalizedError {
    case notLoggedIn
    case sessionExpired
    case verificationRequired(message: String)
    case business(code: Int, message: String)
    case outcomeUnknown
    case unsupported(message: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "请先登录后再发布。"
        case .sessionExpired:
            return "登录已失效，请重新登录后再试。"
        case let .verificationRequired(message):
            return message.isEmpty ? "贴吧要求完成安全验证，当前版本暂时无法继续。" : message
        case let .business(_, message):
            return message.isEmpty ? "贴吧未接受这次发布，请稍后再试。" : message
        case .outcomeUnknown:
            return "发送结果无法确认。应用不会自动重发，请先刷新确认，避免重复发布。"
        case let .unsupported(message):
            return message
        }
    }
}
