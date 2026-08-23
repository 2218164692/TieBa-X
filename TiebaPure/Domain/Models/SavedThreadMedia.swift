import CryptoKit
import Foundation

enum SavedThreadMediaMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case textOnly
    case images
    case complete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textOnly: return "仅正文"
        case .images: return "正文和图片"
        case .complete: return "完整媒体"
        }
    }

    var detail: String {
        switch self {
        case .textOnly: return "保存主楼、回复和楼中楼，媒体仍需联网"
        case .images: return "同时离线保存正文、头像、图片和视频封面"
        case .complete: return "同时离线保存图片、视频和语音"
        }
    }
}

enum SavedThreadMediaKind: String, Codable, Sendable {
    case image
    case avatar
    case videoCover
    case video
    case audio
}

struct SavedThreadMediaAsset: Identifiable, Equatable, Codable, Sendable {
    var sourceIdentities: [String]
    var kind: SavedThreadMediaKind
    var fileName: String
    var byteCount: Int
    var sha256: String

    var id: String { "\(kind.rawValue):\(fileName):\(sourceIdentities.joined(separator: "|"))" }

    var isValid: Bool {
        let sourcesAreValid = sourceIdentities.allSatisfy { source in
            source.isEmpty == false && source.utf8.count <= 8_192
        }
        return sourceIdentities.isEmpty == false
            && sourcesAreValid
            && Set(sourceIdentities).count == sourceIdentities.count
            && fileName.isEmpty == false
            && fileName.utf8.count <= 100
            && fileName != "."
            && fileName != ".."
            && fileName == URL(fileURLWithPath: fileName).lastPathComponent
            && fileName.contains("/") == false
            && fileName.contains("\\") == false
            && fileName.utf8.allSatisfy(Self.isAllowedFileNameByte)
            && byteCount > 0
            && byteCount <= TiebaVideoDownloadClient.maximumVideoBytes
            && sha256.utf8.count == 64
            && sha256.utf8.allSatisfy(Self.isLowercaseHexDigit)
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    private static func isAllowedFileNameByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || byte == 45
            || byte == 46
            || byte == 95
    }
}

final class SavedThreadMediaAuthorization: @unchecked Sendable {
    static let shared = SavedThreadMediaAuthorization()

    private let lock = NSLock()
    private var rootPaths = Set<String>()

    private init() {}

    func register(rootURL: URL) {
        let path = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        _ = lock.withLock { rootPaths.insert(path) }
    }

    func allows(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        let roots = lock.withLock { rootPaths }
        guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        do {
            let values = try resolved.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            return values.isRegularFile == true
                && values.isSymbolicLink != true
                && (values.fileSize ?? 0) > 0
                && (values.fileSize ?? 0) <= TiebaVideoDownloadClient.maximumVideoBytes
        } catch {
            return false
        }
    }
}

final class PreparedSavedThreadMedia: @unchecked Sendable {
    let assets: [SavedThreadMediaAsset]

    private let fileManager: FileManager
    private let stagingURL: URL
    private let finalURL: URL
    private let rollbackURL: URL
    private let lock = NSLock()
    private var state: State = .prepared
    private var hadPreviousDirectory = false

    private enum State {
        case prepared
        case committed
        case finished
        case rolledBack
    }

    init(
        assets: [SavedThreadMediaAsset],
        stagingURL: URL,
        finalURL: URL,
        rootURL: URL,
        fileManager: FileManager
    ) {
        self.assets = assets
        self.stagingURL = stagingURL
        self.finalURL = finalURL
        rollbackURL = rootURL.appendingPathComponent(
            ".rollback-\(finalURL.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
        self.fileManager = fileManager
    }

    func commit() throws {
        try lock.withLock {
            guard state == .prepared else { return }
            hadPreviousDirectory = fileManager.fileExists(atPath: finalURL.path)
            if hadPreviousDirectory {
                try fileManager.moveItem(at: finalURL, to: rollbackURL)
            } else {
                try fileManager.createDirectory(
                    at: rollbackURL,
                    withIntermediateDirectories: false
                )
            }
            do {
                try fileManager.moveItem(at: stagingURL, to: finalURL)
                state = .committed
            } catch {
                if hadPreviousDirectory,
                   fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.moveItem(at: rollbackURL, to: finalURL)
                } else if fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.removeItem(at: rollbackURL)
                }
                throw error
            }
        }
    }

    func finish() {
        lock.withLock {
            guard state == .committed else { return }
            if fileManager.fileExists(atPath: rollbackURL.path) {
                try? fileManager.removeItem(at: rollbackURL)
            }
            state = .finished
        }
    }

    func rollback() {
        lock.withLock {
            switch state {
            case .prepared:
                if fileManager.fileExists(atPath: stagingURL.path) {
                    try? fileManager.removeItem(at: stagingURL)
                }
                if hadPreviousDirectory,
                   fileManager.fileExists(atPath: finalURL.path) == false,
                   fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.moveItem(at: rollbackURL, to: finalURL)
                } else if hadPreviousDirectory == false,
                          fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.removeItem(at: rollbackURL)
                }
            case .committed:
                if fileManager.fileExists(atPath: finalURL.path) {
                    try? fileManager.removeItem(at: finalURL)
                }
                if hadPreviousDirectory,
                   fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.moveItem(at: rollbackURL, to: finalURL)
                } else if fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.removeItem(at: rollbackURL)
                }
            case .finished, .rolledBack:
                break
            }
            state = .rolledBack
        }
    }

    deinit {
        rollback()
    }
}

final class SavedThreadMediaStore: @unchecked Sendable {
    static let unavailable = SavedThreadMediaStore()

    private struct CaptureRequest {
        var kind: SavedThreadMediaKind
        var sourceIdentities: [String]
        var candidates: [URL]
        var voiceMD5: String?
    }

    private let fileManager: FileManager
    private let rootURL: URL?

    private init() {
        fileManager = .default
        rootURL = nil
    }

    init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let location = try SecurePersistenceLocation.applicationSupport(
            fileManager: fileManager,
            baseDirectoryURL: baseDirectoryURL
        )
        let root = location.directoryURL.appendingPathComponent(
            "saved-thread-media",
            isDirectory: true
        )
        try Self.prepareProtectedDirectory(root, fileManager: fileManager)
        self.fileManager = fileManager
        rootURL = root
        SavedThreadMediaAuthorization.shared.register(rootURL: root)
    }

    func prepareCapture(
        snapshot: SavedThreadSnapshot,
        mode: SavedThreadMediaMode
    ) async throws -> PreparedSavedThreadMedia {
        guard let rootURL else { throw SavedThreadError.persistenceUnavailable }
        let stagingURL = try makeStagingDirectory(threadID: snapshot.id, rootURL: rootURL)
        do {
            var assets: [SavedThreadMediaAsset] = []
            var capturedFileNames = Set<String>()
            var totalBytes = 0
            for request in try captureRequests(snapshot: snapshot, mode: mode) {
                try Task.checkCancellation()
                let captured = try await capture(request, into: stagingURL)
                if capturedFileNames.insert(captured.fileName).inserted {
                    totalBytes += captured.byteCount
                }
                guard totalBytes <= SavedThreadPolicy.maximumMediaBytesPerThread else {
                    throw SavedThreadError.mediaStorageLimitExceeded
                }
                assets.append(captured)
            }
            return PreparedSavedThreadMedia(
                assets: assets,
                stagingURL: stagingURL,
                finalURL: directoryURL(threadID: snapshot.id, rootURL: rootURL),
                rootURL: rootURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            if error is CancellationError { throw error }
            if let savedError = error as? SavedThreadError { throw savedError }
            throw SavedThreadError.mediaDownloadFailed
        }
    }

    func prepareImport(
        snapshot: SavedThreadSnapshot,
        files: [String: Data]
    ) throws -> PreparedSavedThreadMedia {
        guard let rootURL else { throw SavedThreadError.persistenceUnavailable }
        let assets = snapshot.effectiveMediaAssets
        let expectedNames = Set(assets.map(\.fileName))
        guard Set(files.keys) == expectedNames else { throw SavedThreadError.invalidBackup }
        let stagingURL = try makeStagingDirectory(threadID: snapshot.id, rootURL: rootURL)
        do {
            var totalBytes = 0
            for fileName in expectedNames {
                guard let data = files[fileName] else { throw SavedThreadError.invalidBackup }
                let matching = assets.filter { $0.fileName == fileName }
                guard let first = matching.first,
                      matching.allSatisfy({
                          $0.byteCount == first.byteCount && $0.sha256 == first.sha256
                      }),
                      data.count == first.byteCount,
                      SecurePersistenceDigest.sha256(data) == first.sha256 else {
                    throw SavedThreadError.invalidBackup
                }
                totalBytes += data.count
                guard totalBytes <= SavedThreadPolicy.maximumMediaBytesPerThread else {
                    throw SavedThreadError.mediaStorageLimitExceeded
                }
                try write(data, named: fileName, to: stagingURL)
            }
            return PreparedSavedThreadMedia(
                assets: assets,
                stagingURL: stagingURL,
                finalURL: directoryURL(threadID: snapshot.id, rootURL: rootURL),
                rootURL: rootURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    func resolvedSnapshot(_ snapshot: SavedThreadSnapshot) -> SavedThreadSnapshot {
        guard snapshot.effectiveMediaMode != .textOnly else { return snapshot }
        var resolved: [String: URL] = [:]
        for asset in snapshot.effectiveMediaAssets {
            guard let localURL = verifiedURL(for: asset, threadID: snapshot.id) else { continue }
            asset.sourceIdentities.forEach { resolved[$0] = localURL }
        }
        let mode = snapshot.effectiveMediaMode
        var result = snapshot
        result.thread.author = resolvedUser(result.thread.author, using: resolved)
        result.thread.forumAvatarURL = resolvedURL(result.thread.forumAvatarURL, using: resolved)
        result.thread.blocks = resolvedBlocks(result.thread.blocks, mode: mode, using: resolved)
        result.forum.avatarURL = resolvedURL(result.forum.avatarURL, using: resolved)
        result.posts = result.posts.map { savedPost in
            var savedPost = savedPost
            savedPost.post.author = resolvedUser(savedPost.post.author, using: resolved)
            savedPost.post.blocks = resolvedBlocks(savedPost.post.blocks, mode: mode, using: resolved)
            savedPost.post.previewSubposts = savedPost.post.previewSubposts.map {
                resolvedSubpost($0, mode: mode, using: resolved)
            }
            savedPost.subposts = savedPost.subposts.map {
                resolvedSubpost($0, mode: mode, using: resolved)
            }
            return savedPost
        }
        return result
    }

    func backupFiles(
        for snapshot: SavedThreadSnapshot,
        maximumTotalByteCount: Int = SavedThreadPolicy.maximumBackupBytes
    ) throws -> [String: Data] {
        let assetsByFileName = Dictionary(
            grouping: snapshot.effectiveMediaAssets,
            by: \.fileName
        )
        let expectedByteCount = assetsByFileName.values.compactMap(\.first).reduce(0) {
            $0 + $1.byteCount
        }
        guard expectedByteCount <= maximumTotalByteCount else {
            throw SavedThreadError.backupStorageLimitExceeded
        }
        var files: [String: Data] = [:]
        for asset in assetsByFileName.values.compactMap(\.first) {
            guard let url = verifiedURL(for: asset, threadID: snapshot.id) else {
                throw SavedThreadError.invalidMediaManifest
            }
            let data = try Data(
                contentsOf: url,
                options: [.mappedIfSafe, .uncached]
            )
            guard data.count == asset.byteCount,
                  SecurePersistenceDigest.sha256(data) == asset.sha256 else {
                throw SavedThreadError.invalidMediaManifest
            }
            files[asset.fileName] = data
        }
        return files
    }

    func storageByteCount() -> Int64 {
        guard let rootURL,
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
              ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    func remove(threadID: Int64) throws {
        guard let rootURL else { throw SavedThreadError.persistenceUnavailable }
        let url = directoryURL(threadID: threadID, rootURL: rootURL)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func clear() throws {
        guard let rootURL else { throw SavedThreadError.persistenceUnavailable }
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        try children.forEach(fileManager.removeItem)
    }

    func removeOrphans(keeping threadIDs: Set<Int64>) {
        guard let rootURL,
              let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        for url in children {
            guard let threadID = Int64(url.lastPathComponent),
                  threadIDs.contains(threadID) == false else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    func repairStorage(snapshots: [SavedThreadSnapshot]) throws {
        guard let rootURL else { return }
        let validated = try snapshots.map { try $0.validated() }
        let snapshotsByID = Dictionary(uniqueKeysWithValues: validated.map { ($0.id, $0) })
        let validThreadIDs = Set(snapshotsByID.keys)
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        for url in children where url.lastPathComponent.hasPrefix(".staging-") {
            try? fileManager.removeItem(at: url)
        }

        let rollbackGroups = Dictionary(grouping: children.filter {
            $0.lastPathComponent.hasPrefix(".rollback-")
        }) { Self.transactionThreadID(from: $0.lastPathComponent) }

        for (threadID, candidates) in rollbackGroups {
            guard let threadID, validThreadIDs.contains(threadID) else {
                candidates.forEach { try? fileManager.removeItem(at: $0) }
                continue
            }
            guard let snapshot = snapshotsByID[threadID] else { continue }
            let finalURL = directoryURL(threadID: threadID, rootURL: rootURL)
            if try Self.directory(finalURL, matches: snapshot, fileManager: fileManager) {
                candidates.forEach { try? fileManager.removeItem(at: $0) }
                continue
            }
            guard let restorable = try candidates.first(where: {
                try Self.directory($0, matches: snapshot, fileManager: fileManager)
            }) else {
                // Preserve unmatched rollback data. It may be the only copy left
                // after an interrupted filesystem operation.
                continue
            }
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: restorable, to: finalURL)
            candidates.filter { $0 != restorable }.forEach {
                try? fileManager.removeItem(at: $0)
            }
        }

        for snapshot in validated where snapshot.effectiveMediaMode == .textOnly {
            try? remove(threadID: snapshot.id)
        }
        removeOrphans(keeping: validThreadIDs)
    }

    private static func transactionThreadID(from name: String) -> Int64? {
        guard name.hasPrefix(".rollback-") else { return nil }
        return Int64(String(name.dropFirst(".rollback-".count).prefix { $0 != "-" }))
    }

    private static func directory(
        _ directoryURL: URL,
        matches snapshot: SavedThreadSnapshot,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return false }
        let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        let expected = Set(snapshot.effectiveMediaAssets.map(\.fileName))
        guard Set(children.map(\.lastPathComponent)) == expected else { return false }
        let assetsByName = Dictionary(grouping: snapshot.effectiveMediaAssets, by: \.fileName)
            .compactMapValues(\.first)
        return try children.allSatisfy { fileURL in
            guard let asset = assetsByName[fileURL.lastPathComponent] else { return false }
            let fileValues = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            let digest = try Self.sha256(fileURL: fileURL)
            return fileValues.isRegularFile == true
                && fileValues.isSymbolicLink != true
                && fileValues.fileSize == asset.byteCount
                && digest == asset.sha256
        }
    }

    private func capture(
        _ request: CaptureRequest,
        into directoryURL: URL
    ) async throws -> SavedThreadMediaAsset {
        switch request.kind {
        case .image, .avatar, .videoCover:
            var lastError: Error?
            for candidate in request.candidates {
                do {
                    let payload = try await TiebaImageDownloadClient.shared.download(from: candidate)
                    let digest = SecurePersistenceDigest.sha256(payload.data)
                    let fileName = Self.contentFileName(
                        digest: digest,
                        preferredExtension: URL(fileURLWithPath: payload.fileName).pathExtension,
                        fallbackExtension: "img"
                    )
                    try writeIfNeeded(payload.data, named: fileName, to: directoryURL)
                    return SavedThreadMediaAsset(
                        sourceIdentities: request.sourceIdentities,
                        kind: request.kind,
                        fileName: fileName,
                        byteCount: payload.data.count,
                        sha256: digest
                    )
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? SavedThreadError.mediaDownloadFailed
        case .audio:
            guard let md5 = request.voiceMD5 else { throw SavedThreadError.mediaDownloadFailed }
            let payload = try await VoiceAudioClient.shared.load(md5: md5, onProgress: nil)
            let digest = SecurePersistenceDigest.sha256(payload.data)
            let fileName = Self.contentFileName(
                digest: digest,
                preferredExtension: Self.audioExtension(mimeType: payload.mimeType),
                fallbackExtension: "audio"
            )
            try writeIfNeeded(payload.data, named: fileName, to: directoryURL)
            return SavedThreadMediaAsset(
                sourceIdentities: request.sourceIdentities,
                kind: .audio,
                fileName: fileName,
                byteCount: payload.data.count,
                sha256: digest
            )
        case .video:
            guard let source = request.candidates.first else {
                throw SavedThreadError.mediaDownloadFailed
            }
            let lease = try await TiebaVideoDownloadClient.shared.download(from: source)
            defer { lease.release() }
            let byteCount = try Self.regularFileByteCount(lease.fileURL)
            let digest = try Self.sha256(fileURL: lease.fileURL)
            let fileName = Self.contentFileName(
                digest: digest,
                preferredExtension: "mp4",
                fallbackExtension: "mp4"
            )
            let destination = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) == false {
                try fileManager.copyItem(at: lease.fileURL, to: destination)
                try Self.secureFile(destination, fileManager: fileManager)
            }
            return SavedThreadMediaAsset(
                sourceIdentities: request.sourceIdentities,
                kind: .video,
                fileName: fileName,
                byteCount: byteCount,
                sha256: digest
            )
        }
    }

    private func captureRequests(
        snapshot: SavedThreadSnapshot,
        mode: SavedThreadMediaMode
    ) throws -> [CaptureRequest] {
        guard mode != .textOnly else { return [] }
        var requests: [CaptureRequest] = []
        var visualAliasesToIndex: [String: Int] = [:]
        var mediaIdentities = Set<String>()

        func rebuildVisualAliasIndex() {
            visualAliasesToIndex = [:]
            for (index, request) in requests.enumerated()
            where [.image, .avatar, .videoCover].contains(request.kind) {
                request.sourceIdentities.forEach { visualAliasesToIndex[$0] = index }
            }
        }

        func appendImage(
            _ urls: [URL?],
            kind: SavedThreadMediaKind,
            required: Bool = false
        ) throws {
            let candidates = urls.compactMap { TiebaRemoteMediaPolicy.url($0?.absoluteString) }
            let aliases = Array(Set(candidates.map(\.absoluteString))).sorted()
            guard aliases.isEmpty == false else {
                if required {
                    throw SavedThreadError.mediaDownloadFailed
                }
                return
            }

            let existingIndices = Set(aliases.compactMap { visualAliasesToIndex[$0] })
            if let primary = existingIndices.min() {
                let matched = existingIndices.sorted()
                let existingSources = matched.flatMap { requests[$0].sourceIdentities }
                let existingCandidates = matched.flatMap { requests[$0].candidates }
                requests[primary].sourceIdentities = Array(Set(existingSources + aliases)).sorted()
                requests[primary].candidates = orderedUnique(existingCandidates + candidates)
                for index in matched.reversed() where index != primary {
                    requests.remove(at: index)
                }
                rebuildVisualAliasIndex()
                return
            }

            let index = requests.count
            requests.append(CaptureRequest(
                kind: kind,
                sourceIdentities: aliases,
                candidates: candidates,
                voiceMD5: nil
            ))
            aliases.forEach { visualAliasesToIndex[$0] = index }
        }

        func appendUser(_ user: UserSummary) throws {
            try appendImage([TiebaURL.avatar(user.portrait)], kind: .avatar)
        }

        func appendBlocks(_ blocks: [ContentBlock]) throws {
            for block in blocks {
                switch block {
                case let .image(image):
                    try appendImage(
                        [image.originalURL, image.thumbnailURL],
                        kind: .image,
                        required: true
                    )
                case let .video(video):
                    try appendImage(
                        [video.coverURL],
                        kind: .videoCover,
                        required: video.coverURL != nil
                    )
                    if mode == .complete {
                        guard let url = TiebaVideoRemotePolicy.url(video.videoURL?.absoluteString) else {
                            throw SavedThreadError.mediaDownloadFailed
                        }
                        let identity = url.absoluteString
                        if mediaIdentities.insert("video:\(identity)").inserted {
                            requests.append(CaptureRequest(
                                kind: .video,
                                sourceIdentities: [identity],
                                candidates: [url],
                                voiceMD5: nil
                            ))
                        }
                    }
                case let .voice(voice) where mode == .complete:
                    let identity = Self.voiceIdentity(md5: voice.md5)
                    if mediaIdentities.insert(identity).inserted {
                        requests.append(CaptureRequest(
                            kind: .audio,
                            sourceIdentities: [identity],
                            candidates: [],
                            voiceMD5: voice.md5
                        ))
                    }
                case .text, .link, .mention, .emoticon, .voice:
                    break
                }
            }
        }

        try appendUser(snapshot.thread.author)
        try appendImage([snapshot.thread.forumAvatarURL, snapshot.forum.avatarURL], kind: .avatar)
        try appendBlocks(snapshot.thread.blocks)
        for savedPost in snapshot.posts {
            try appendUser(savedPost.post.author)
            try appendBlocks(savedPost.post.blocks)
            for subpost in savedPost.subposts {
                try appendUser(subpost.author)
                try appendBlocks(subpost.blocks)
            }
        }
        return requests
    }

    private func orderedUnique(_ values: [URL]) -> [URL] {
        var known = Set<String>()
        return values.filter { known.insert($0.absoluteString).inserted }
    }

    private func resolvedBlocks(
        _ blocks: [ContentBlock],
        mode: SavedThreadMediaMode,
        using resolved: [String: URL]
    ) -> [ContentBlock] {
        blocks.map { block in
            switch block {
            case var .image(image):
                image.thumbnailURL = resolvedURL(image.thumbnailURL, using: resolved)
                    ?? resolvedURL(image.originalURL, using: resolved)
                image.originalURL = resolvedURL(image.originalURL, using: resolved)
                    ?? image.thumbnailURL
                return .image(image)
            case var .video(video):
                video.coverURL = resolvedURL(video.coverURL, using: resolved)
                video.videoURL = mode == .complete
                    ? resolvedURL(video.videoURL, using: resolved)
                    : nil
                video.webURL = nil
                return .video(video)
            case let .voice(voice):
                guard let localURL = resolved[Self.voiceIdentity(md5: voice.md5)] else {
                    var voice = voice
                    voice.localURL = nil
                    voice.offlineOnly = true
                    return .voice(voice)
                }
                var voice = voice
                voice.localURL = localURL
                voice.offlineOnly = true
                return .voice(voice)
            case .text, .link, .mention, .emoticon:
                return block
            }
        }
    }

    private func resolvedSubpost(
        _ subpost: Subpost,
        mode: SavedThreadMediaMode,
        using resolved: [String: URL]
    ) -> Subpost {
        var result = subpost
        result.author = resolvedUser(result.author, using: resolved)
        result.blocks = resolvedBlocks(result.blocks, mode: mode, using: resolved)
        return result
    }

    private func resolvedUser(_ user: UserSummary, using resolved: [String: URL]) -> UserSummary {
        var result = user
        result.portrait = TiebaURL.avatar(user.portrait)
            .flatMap { resolved[$0.absoluteString] }?
            .absoluteString ?? ""
        return result
    }

    private func resolvedURL(_ url: URL?, using resolved: [String: URL]) -> URL? {
        guard let url else { return nil }
        if let safeURL = TiebaURL.make(url.absoluteString) {
            return resolved[safeURL.absoluteString]
        }
        return nil
    }

    private func verifiedURL(for asset: SavedThreadMediaAsset, threadID: Int64) -> URL? {
        guard let rootURL, asset.isValid else { return nil }
        let url = directoryURL(threadID: threadID, rootURL: rootURL)
            .appendingPathComponent(asset.fileName, isDirectory: false)
        guard SavedThreadMediaAuthorization.shared.allows(url),
              (try? Self.regularFileByteCount(url)) == asset.byteCount else { return nil }
        return url
    }

    private func makeStagingDirectory(threadID: Int64, rootURL: URL) throws -> URL {
        guard threadID > 0 else { throw SavedThreadError.incompleteThread }
        let url = rootURL.appendingPathComponent(
            ".staging-\(threadID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try Self.prepareProtectedDirectory(url, fileManager: fileManager)
        return url
    }

    private func directoryURL(threadID: Int64, rootURL: URL) -> URL {
        rootURL.appendingPathComponent(String(threadID), isDirectory: true)
    }

    private func writeIfNeeded(_ data: Data, named name: String, to directory: URL) throws {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) == false else { return }
        try write(data, named: name, to: directory)
    }

    private func write(_ data: Data, named name: String, to directory: URL) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              name.contains("/") == false,
              name.contains("\\") == false else {
            throw SavedThreadError.invalidBackup
        }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try Self.secureFile(url, fileManager: fileManager)
    }

    private static func voiceIdentity(md5: String) -> String { "voice:\(md5)" }

    private static func contentFileName(
        digest: String,
        preferredExtension: String,
        fallbackExtension: String
    ) -> String {
        let candidate = preferredExtension.lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        return "\(digest).\(candidate.isEmpty ? fallbackExtension : candidate)"
    }

    private static func audioExtension(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        default: return "audio"
        }
    }

    private static func regularFileByteCount(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let count = values.fileSize,
              count > 0,
              count <= TiebaVideoDownloadClient.maximumVideoBytes else {
            throw SavedThreadError.invalidMediaManifest
        }
        return count
    }

    private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), data.isEmpty == false {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func prepareProtectedDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SavedThreadError.persistenceUnavailable
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [
                    .posixPermissions: NSNumber(value: Int16(0o700)),
                    .protectionKey: FileProtectionType.complete
                ]
            )
        }
    }

    private static func secureFile(_ url: URL, fileManager: FileManager) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SavedThreadError.invalidMediaManifest
        }
        try fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
            .protectionKey: FileProtectionType.complete
        ], ofItemAtPath: url.path)
    }
}

struct SavedThreadUpdateService {
    let api: any TiebaAPIService

    func latestReplyCount(snapshot: SavedThreadSnapshot, account: Account?) async throws -> Int {
        let page = try await api.threadPage(
            account: account,
            threadID: snapshot.id,
            page: 1,
            forumID: snapshot.forum.id,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
        guard page.thread.id == snapshot.id else { throw SavedThreadError.inconsistentPagination }
        return max(page.thread.replyCount, snapshot.thread.replyCount)
    }
}
