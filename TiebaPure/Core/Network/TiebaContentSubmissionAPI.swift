import CryptoKit
import Foundation
import SwiftProtobuf
import UIKit

struct TiebaAppUploadedImage: Equatable, Sendable {
    let picID: String
    let pixelWidth: Int
    let pixelHeight: Int

    var contentTag: String {
        "#(pic,\(picID),\(pixelWidth),\(pixelHeight))"
    }
}

struct TiebaImageUploadResponseDTO: Decodable, Equatable {
    private struct InfoDTO: Decodable, Equatable {
        let picID: String

        private enum CodingKeys: String, CodingKey {
            case picID = "pic_id"
            case fallbackPicID = "picId"
        }

        init(from decoder: Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            picID = container.submissionString(forKey: .picID)
                ?? container.submissionString(forKey: .fallbackPicID)
                ?? ""
        }
    }

    let errorCode: Int?
    let errorMessage: String
    let picID: String

    private enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case fallbackErrorCode = "err_code"
        case errorMessage = "error_msg"
        case fallbackErrorMessage = "err_msg"
        case picID = "picId"
        case fallbackPicID = "pic_id"
        case info
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = container.submissionInt(forKey: .errorCode)
            ?? container.submissionInt(forKey: .fallbackErrorCode)
        errorMessage = container.submissionString(forKey: .errorMessage)
            ?? container.submissionString(forKey: .fallbackErrorMessage)
            ?? ""
        let info = try? container.decodeIfPresent(InfoDTO.self, forKey: .info)
        picID = container.submissionString(forKey: .picID)
            ?? container.submissionString(forKey: .fallbackPicID)
            ?? info?.picID
            ?? ""
    }

    func validatedPicID() throws -> String {
        guard let errorCode else {
            throw ContentSubmissionError.business(code: -1, message: "图片上传响应缺少状态码。")
        }
        guard errorCode == 0 else {
            if TiebaAPIError.sessionExpiredCodes.contains(errorCode) {
                throw ContentSubmissionError.sessionExpired
            }
            throw ContentSubmissionError.business(
                code: errorCode,
                message: errorMessage.isEmpty ? "图片上传失败。" : errorMessage
            )
        }

        let value = picID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false,
              value.utf8.count <= 2_048,
              value.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || byte == 45
                      || byte == 95
              }) else {
            throw ContentSubmissionError.business(code: -1, message: "贴吧没有返回有效的图片标识。")
        }
        return value
    }
}

enum TiebaContentSubmissionRequestFactory {
    static let clientVersion = "12.35.1.0"
    static let packageVersion = "hybrid-main-pb_1.0.324.1"

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.6"
    }

    static func common(
        account: Account,
        tbs: String,
        bootstrap: TiebaPostingBootstrapResult,
        requestBuilder: TiebaRequestBuilder,
        now: Date = Date()
    ) -> Tieba_CommonRequest {
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let firstRunTimestamp = max(1, timestamp - 30 * 24 * 60 * 60 * 1_000)
        let dateComponents = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: now
        )

        var common = Tieba_CommonRequest()
        common.clientType = 2
        common.clientVersion = clientVersion
        common.clientID = bootstrap.clientID
        common.phoneImei = "000000000000000"
        common.from = "1008621x"
        common.cuid = bootstrap.identity.cuidGalaxy2
        common.timestamp = timestamp
        common.model = UIDevice.current.model
        common.bduss = account.bduss
        common.tbs = tbs
        common.netType = 1
        common.pversion = "1.0.3"
        common.osVersion = UIDevice.current.systemVersion
        common.brand = "Apple"
        common.legoLibVersion = "3.0.0"
        common.applist = ""
        common.stoken = account.stoken
        common.zID = bootstrap.zID
        common.cuidGalaxy2 = bootstrap.identity.cuidGalaxy2
        common.cuidGid = ""
        common.c3Aid = bootstrap.identity.c3AID
        common.sampleID = bootstrap.sampleID
        common.scrW = Int32(clamping: requestBuilder.screenWidth)
        common.scrH = Int32(clamping: requestBuilder.screenHeight)
        common.scrDip = requestBuilder.screenScale
        common.qType = 0
        common.isTeenager = 0
        common.sdkVer = "2.34.0"
        common.frameworkVer = "3340042"
        common.nawsGameVer = "1038000"
        common.activeTimestamp = firstRunTimestamp
        common.firstInstallTime = firstRunTimestamp
        common.lastUpdateTime = firstRunTimestamp
        common.eventDay = [dateComponents.year, dateComponents.month, dateComponents.day]
            .compactMap { $0.map(String.init) }
            .joined()
        common.androidID = bootstrap.identity.androidID
        common.cmode = 1
        common.startScheme = ""
        common.startType = 1
        common.idfv = "0"
        common.extra = ""
        common.userAgent = "TiebaPure/\(appVersion) tieba/\(clientVersion)"
        common.personalizedRecSwitch = 1
        common.deviceScore = "0.4"
        common.packageVersion = packageVersion
        return common
    }

    static func addPost(
        account: Account,
        tbs: String,
        request: ContentSubmissionRequest,
        uploadedImages: [TiebaAppUploadedImage],
        bootstrap: TiebaPostingBootstrapResult,
        requestBuilder: TiebaRequestBuilder,
        now: Date = Date()
    ) throws -> Tieba_AddPostRequest {
        guard let threadID = request.target.threadID, threadID > 0 else {
            throw ContentSubmissionValidationError.invalidThread
        }

        var data = Tieba_AddPostRequest.DataMessage()
        data.common = common(
            account: account,
            tbs: tbs,
            bootstrap: bootstrap,
            requestBuilder: requestBuilder,
            now: now
        )
        data.anonymous = "1"
        data.canNoForum = "0"
        data.isFeedback = "0"
        data.takephotoNum = String(uploadedImages.count)
        data.entranceType = "0"
        data.vcodeTag = "12"
        data.newVcode = "1"
        let body = request.target.kind == .subpostReply
            ? subpostReplyBody(request.body, target: request.target)
            : request.body
        data.content = content(body: body, uploadedImages: uploadedImages)
        data.fid = String(request.target.forumID)
        data.vFid = ""
        data.vFname = ""
        data.kw = request.target.forumName
        data.isBarrage = "0"
        data.fromFourmID = String(request.target.forumID)
        data.tid = String(threadID)
        data.floorNum = "0"
        data.isAd = "0"
        data.isAddition = "0"
        data.isGiftpost = "0"
        data.nameShow = account.displayName.isEmpty ? account.name : account.displayName
        data.isPictxt = uploadedImages.isEmpty ? "0" : "1"
        data.showCustomFigure = 0
        data.isShowBless = 0

        switch request.target.kind {
        case .threadReply:
            data.barrageTime = "0"
            data.postFrom = "3"
        case .postReply:
            try applyFloorReplyTarget(request.target, to: &data)
            data.postFrom = "0"
        case .subpostReply:
            try applyFloorReplyTarget(request.target, to: &data)
            guard let subpostID = request.target.subpostID, subpostID > 0 else {
                throw ContentSubmissionValidationError.invalidThread
            }
            data.subPostID = String(subpostID)
        case .newThread:
            throw ContentSubmissionError.unsupported(message: "新主题必须使用发帖协议。")
        }

        var protobuf = Tieba_AddPostRequest()
        protobuf.data = data
        return protobuf
    }

    static func addThread(
        account: Account,
        tbs: String,
        request: ContentSubmissionRequest,
        bootstrap: TiebaPostingBootstrapResult,
        requestBuilder: TiebaRequestBuilder,
        now: Date = Date()
    ) throws -> Tieba_AddThreadRequest {
        guard request.target.kind == .newThread else {
            throw ContentSubmissionError.unsupported(message: "回复必须使用回帖协议。")
        }
        guard request.images.isEmpty else {
            throw ContentSubmissionValidationError.imagesUnsupportedForNewThread
        }

        var data = Tieba_AddThreadRequest.DataMessage()
        data.common = common(
            account: account,
            tbs: tbs,
            bootstrap: bootstrap,
            requestBuilder: requestBuilder,
            now: now
        )
        data.anonymous = "1"
        data.canNoForum = "0"
        data.isFeedback = "0"
        data.takephotoNum = "0"
        data.entranceType = "1"
        data.vcodeTag = "12"
        data.newVcode = "1"
        data.content = request.body
        data.fid = String(request.target.forumID)
        data.kw = request.target.forumName
        data.isHide = "0"
        data.isRepostToDynamic = "0"
        data.proZone = "0"
        data.callFrom = "2"
        data.title = request.title
        data.isNtitle = "0"
        data.isLinkThread = "0"
        data.isForumBusinessAccount = "0"
        data.nameShow = account.displayName.isEmpty ? account.name : account.displayName
        data.isPictxt = "0"
        data.isArticle = "0"
        data.showCustomFigure = 0
        data.isQuestion = 0
        data.isXiuxiuThread = 0
        data.isShowBless = 0
        data.ext = #"{"need_image":0,"is_hide":0,"need_follow_forum":0}"#

        var protobuf = Tieba_AddThreadRequest()
        protobuf.data = data
        return protobuf
    }

    static func appHeaders(
        bootstrap: TiebaPostingBootstrapResult,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [String: String] {
        [
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Pragma": "no-cache",
            "User-Agent": "tieba/\(clientVersion) skin/default TiebaPure/\(appVersion)",
            "client_logid": String(timestamp),
            "client_type": "2",
            "cuid": bootstrap.identity.cuidGalaxy2,
            "cuid_galaxy2": bootstrap.identity.cuidGalaxy2,
            "cuid_gid": ""
        ]
    }

    static func protobufHeaders(
        bootstrap: TiebaPostingBootstrapResult,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [String: String] {
        var headers = appHeaders(bootstrap: bootstrap, timestamp: timestamp)
        headers["x_bd_data_type"] = "protobuf"
        return headers
    }

    private static func applyFloorReplyTarget(
        _ target: ContentSubmissionTarget,
        to data: inout Tieba_AddPostRequest.DataMessage
    ) throws {
        guard let parentPostID = target.parentPostID, parentPostID > 0 else {
            throw ContentSubmissionValidationError.invalidThread
        }
        data.quoteID = String(parentPostID)
        data.repostid = String(parentPostID)
        if let replyUserID = target.replyUserID, replyUserID > 0 {
            data.replyUid = String(replyUserID)
        }
    }

    private static func content(
        body: String,
        uploadedImages: [TiebaAppUploadedImage]
    ) -> String {
        let imageTags = uploadedImages.map(\.contentTag)
        if body.isEmpty { return imageTags.joined(separator: "\n") }
        if imageTags.isEmpty { return body }
        return ([body] + imageTags).joined(separator: "\n")
    }

    private static func subpostReplyBody(
        _ body: String,
        target: ContentSubmissionTarget
    ) -> String {
        guard let displayName = protocolReplyComponent(target.replyUserDisplayName) else {
            return body
        }
        // Drafts written before reply portraits were persisted still carry the
        // target UID and display name. Keep the three-component protocol shape;
        // reply_uid lets the server restore ownership when portrait is absent.
        let portrait = protocolReplyComponent(target.replyUserPortrait) ?? ""
        return "回复 #(reply, \(portrait), \(displayName)) :\(body)"
    }

    private static func protocolReplyComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.utf8.count <= 512,
              normalized.contains(",") == false,
              normalized.contains(")") == false,
              normalized.contains("\r") == false,
              normalized.contains("\n") == false else {
            return nil
        }
        return normalized
    }
}

extension TiebaAPI {
    func submitContent(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt {
        try ContentSubmissionPolicy.validateForNetwork(request)
        try Task.checkCancellation()

        let bootstrap: TiebaPostingBootstrapResult
        do {
            bootstrap = try await postingBootstrap.bootstrap(bduss: account.bduss)
        } catch is CancellationError {
            throw CancellationError()
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch let error as TiebaPostingBootstrapError {
            if error.invalidatesPostingSession {
                throw ContentSubmissionError.sessionExpired
            }
            throw error
        } catch {
            throw error
        }
        try Task.checkCancellation()

        let uploadedImages = try await uploadImages(
            request.images,
            account: account,
            bootstrap: bootstrap
        )
        try Task.checkCancellation()

        let refreshedTBS: String
        do {
            refreshedTBS = try await strictlyRefreshedClientTBS(for: account)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TiebaAPIError {
            if case .sessionExpired = error {
                throw ContentSubmissionError.sessionExpired
            }
            throw error
        }
        try Task.checkCancellation()

        switch request.target.kind {
        case .newThread:
            let protobuf = try TiebaContentSubmissionRequestFactory.addThread(
                account: account,
                tbs: refreshedTBS,
                request: request,
                bootstrap: bootstrap,
                requestBuilder: requestBuilder
            )
            let multipart = try requestBuilder.multipart(
                protobuf: protobuf,
                account: account,
                includeSToken: false
            )
            let response: Tieba_AddThreadResponse = try await sendFinalMutation(
                endpoint: .addThread,
                body: multipart.body,
                contentType: multipart.contentType,
                headers: TiebaContentSubmissionRequestFactory.protobufHeaders(bootstrap: bootstrap)
            )
            return try response.submissionReceipt

        case .threadReply, .postReply, .subpostReply:
            let protobuf = try TiebaContentSubmissionRequestFactory.addPost(
                account: account,
                tbs: refreshedTBS,
                request: request,
                uploadedImages: uploadedImages,
                bootstrap: bootstrap,
                requestBuilder: requestBuilder
            )
            let multipart = try requestBuilder.multipart(
                protobuf: protobuf,
                account: account,
                includeSToken: false
            )
            let response: Tieba_AddPostResponse = try await sendFinalMutation(
                endpoint: .addPost,
                body: multipart.body,
                contentType: multipart.contentType,
                headers: TiebaContentSubmissionRequestFactory.protobufHeaders(bootstrap: bootstrap)
            )
            return try response.submissionReceipt(for: request.target)
        }
    }

    private func sendFinalMutation<Response: SwiftProtobuf.Message>(
        endpoint: TiebaEndpoint,
        body: Data,
        contentType: String,
        headers: [String: String]
    ) async throws -> Response {
        // Before this point cancellation is known to be safe. Once the POST is
        // dispatched the server may have accepted it even if the client task is
        // cancelled or loses its response, so the operation must never look
        // retryable to the caller.
        try Task.checkCancellation()
        do {
            return try await client.postProtobuf(
                endpoint,
                body: body,
                contentType: contentType,
                headers: headers,
                as: Response.self
            )
        } catch {
            // The write may already have reached Tieba. Never retry it automatically.
            throw ContentSubmissionError.outcomeUnknown
        }
    }

    private func uploadImages(
        _ images: [ContentSubmissionImage],
        account: Account,
        bootstrap: TiebaPostingBootstrapResult
    ) async throws -> [TiebaAppUploadedImage] {
        var result: [TiebaAppUploadedImage] = []
        result.reserveCapacity(images.count)
        for image in images {
            try Task.checkCancellation()
            let metadata = try ContentSubmissionImageInspector.inspect(image.data)
            let picID = try await uploadImage(
                image.data,
                metadata: metadata,
                account: account,
                bootstrap: bootstrap
            )
            result.append(TiebaAppUploadedImage(
                picID: picID,
                pixelWidth: metadata.pixelWidth,
                pixelHeight: metadata.pixelHeight
            ))
        }
        return result
    }

    private func uploadImage(
        _ image: Data,
        metadata: ContentSubmissionImageMetadata,
        account: Account,
        bootstrap: TiebaPostingBootstrapResult
    ) async throws -> String {
        let digest = Insecure.MD5.hash(data: image)
            .map { String(format: "%02X", $0) }
            .joined()
        let boundary = "TiebaPureImage-\(UUID().uuidString)"
        let form = MultipartFormData(boundary: boundary)
        form.addField(name: "BDUSS", value: account.bduss)
        form.addField(name: "_client_type", value: "2")
        form.addField(name: "_client_version", value: TiebaContentSubmissionRequestFactory.clientVersion)
        form.addField(name: "alt", value: "json")
        form.addField(name: "chunkNo", value: "1")
        form.addField(name: "groupId", value: "1")
        form.addField(name: "height", value: String(metadata.pixelHeight))
        form.addField(name: "isFinish", value: "1")
        form.addField(name: "is_bjh", value: "0")
        form.addField(name: "resourceId", value: digest)
        form.addField(name: "saveOrigin", value: "1")
        form.addField(name: "stoken", value: account.stoken)
        form.addField(name: "support_image", value: "jepgwebp")
        form.addField(name: "width", value: String(metadata.pixelWidth))
        form.addFile(name: "chunk", filename: "image_\(digest.lowercased())", data: image)

        do {
            var headers = TiebaContentSubmissionRequestFactory.appHeaders(bootstrap: bootstrap)
            headers["Cookie"] = "ka=open"
            let raw = try await client.postRaw(
                .uploadPicture,
                body: form.finalize(),
                contentType: "multipart/form-data; boundary=\(boundary)",
                headers: headers
            )
            let response = try JSONDecoder().decode(TiebaImageUploadResponseDTO.self, from: raw)
            return try response.validatedPicID()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ContentSubmissionError {
            throw error
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch {
            throw ContentSubmissionError.business(code: -1, message: "图片上传失败，请检查网络后重试。")
        }
    }
}

private extension TiebaPostingBootstrapError {
    var invalidatesPostingSession: Bool {
        switch self {
        case .invalidCredential:
            return true
        case let .server(code, _):
            return TiebaAPIError.sessionExpiredCodes.contains(code)
        default:
            return false
        }
    }
}

private extension Tieba_AddPostResponse {
    func submissionReceipt(for target: ContentSubmissionTarget) throws -> ContentSubmissionReceipt {
        guard hasError else {
            throw ContentSubmissionError.outcomeUnknown
        }
        let messages = submissionMessages
        try validateSubmissionStatus(
            error: error,
            verification: data.info,
            messages: messages
        )
        // AddPost success responses commonly contain only Error{error_code=0}.
        // The requested thread is therefore the stable source of the receipt;
        // returned identifiers are optional enrichment, not success evidence.
        guard let threadID = positiveInt64(data.tid) ?? target.threadID,
              threadID > 0 else {
            throw ContentSubmissionError.outcomeUnknown
        }
        return ContentSubmissionReceipt(
            threadID: threadID,
            postID: positiveUInt64(data.pid)
        )
    }

    var submissionMessages: [String] {
        normalizedSubmissionMessages([
            error.userMsg,
            error.errorMsg,
            data.msg,
            data.preMsg,
            data.colorMsg
        ])
    }
}

private extension Tieba_AddThreadResponse {
    var submissionReceipt: ContentSubmissionReceipt {
        get throws {
            let messages = submissionMessages
            try validateSubmissionStatus(
                error: error,
                verification: data.info,
                messages: messages
            )
            guard hasData, let threadID = positiveInt64(data.tid) else {
                throw ContentSubmissionError.outcomeUnknown
            }
            return ContentSubmissionReceipt(
                threadID: threadID,
                postID: positiveUInt64(data.pid)
            )
        }
    }

    var submissionMessages: [String] {
        normalizedSubmissionMessages([
            error.userMsg,
            error.errorMsg,
            data.msg,
            data.preMsg,
            data.colorMsg
        ])
    }
}

private func validateSubmissionStatus(
    error: Tieba_Error,
    verification: Tieba_SubmissionVerificationInfo,
    messages: [String]
) throws {
    let code = Int(error.errorCode)
    let message = messages.first ?? ""
    if TiebaAPIError.sessionExpiredCodes.contains(code) {
        throw ContentSubmissionError.sessionExpired
    }
    if verification.requiresVerification
        || messages.contains(where: \.requiresSubmissionVerification) {
        throw ContentSubmissionError.verificationRequired(message: message)
    }
    guard code == 0 else {
        throw ContentSubmissionError.business(code: code, message: message)
    }
}

private extension Tieba_SubmissionVerificationInfo {
    var requiresVerification: Bool {
        let value = needVcode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty == false && value != "0" && value != "false"
    }
}

private extension String {
    var requiresSubmissionVerification: Bool {
        let value = lowercased()
        return value.contains("验证码")
            || value.contains("安全验证")
            || value.contains("captcha")
            || value.contains("verify")
    }
}

private func normalizedSubmissionMessages(_ values: [String]) -> [String] {
    values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
}

private func positiveInt64(_ value: String) -> Int64? {
    guard let number = Int64(value), number > 0 else { return nil }
    return number
}

private func positiveUInt64(_ value: String) -> UInt64? {
    guard let number = UInt64(value), number > 0 else { return nil }
    return number
}

private extension KeyedDecodingContainer {
    func submissionString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "1" : "0"
        }
        return nil
    }

    func submissionInt(forKey key: Key) -> Int? {
        submissionString(forKey: key).flatMap(Int.init)
    }
}
