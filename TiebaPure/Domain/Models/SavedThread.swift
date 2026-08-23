import Foundation

struct SavedThreadPost: Identifiable, Equatable, Codable, Sendable {
    var post: Post
    var subposts: [Subpost]

    var id: UInt64 { post.id }

    var displayPost: Post {
        var value = post
        value.subpostCount = subposts.count
        value.previewSubposts = Array(subposts.prefix(3))
        return value
    }
}

struct SavedThreadSnapshot: Identifiable, Equatable, Codable, Sendable {
    static let currentFormatVersion = 2

    var formatVersion: Int = currentFormatVersion
    var thread: ThreadSummary
    var forum: Forum
    var posts: [SavedThreadPost]
    var savedAt: Date
    var mediaMode: SavedThreadMediaMode?
    var mediaAssets: [SavedThreadMediaAsset]?
    var latestCheckedAt: Date?
    var latestReplyCount: Int?

    var id: Int64 { thread.id }
    var mainPost: SavedThreadPost? { posts.first { $0.post.floor == 1 } }
    var replyCount: Int { posts.reduce(0) { $0 + ($1.post.floor == 1 ? 0 : 1) } }
    var subpostCount: Int { posts.reduce(0) { $0 + $1.subposts.count } }
    var effectiveMediaMode: SavedThreadMediaMode { mediaMode ?? .textOnly }
    var effectiveMediaAssets: [SavedThreadMediaAsset] { mediaAssets ?? [] }
    var newReplyCount: Int {
        max((latestReplyCount ?? thread.replyCount) - thread.replyCount, 0)
    }

    func validated() throws -> SavedThreadSnapshot {
        guard (1...Self.currentFormatVersion).contains(formatVersion) else {
            throw SavedThreadError.unsupportedFormat
        }
        guard thread.id > 0,
              forum.id > 0,
              let mainPost,
              mainPost.post.id > 0,
              mainPost.post.threadID == thread.id,
              posts.allSatisfy({ $0.post.id > 0 && $0.post.threadID == thread.id }) else {
            throw SavedThreadError.incompleteThread
        }
        let postIDs = posts.map(\.post.id)
        guard Set(postIDs).count == postIDs.count else {
            throw SavedThreadError.inconsistentPagination
        }
        guard effectiveMediaAssets.allSatisfy(\.isValid) else {
            throw SavedThreadError.invalidMediaManifest
        }
        let groupedFiles = Dictionary(grouping: effectiveMediaAssets, by: \.fileName)
        guard groupedFiles.values.allSatisfy({ assets in
            guard let first = assets.first else { return false }
            return assets.allSatisfy {
                $0.byteCount == first.byteCount && $0.sha256 == first.sha256
            }
        }) else {
            throw SavedThreadError.invalidMediaManifest
        }
        let groupedSources = Dictionary(
            grouping: effectiveMediaAssets.flatMap { asset in
                asset.sourceIdentities.map { ($0, asset) }
            },
            by: { $0.0 }
        )
        guard groupedSources.values.allSatisfy({ values in
            guard let first = values.first?.1 else { return false }
            return values.allSatisfy {
                $0.1.byteCount == first.byteCount && $0.1.sha256 == first.sha256
            }
        }) else {
            throw SavedThreadError.invalidMediaManifest
        }
        let uniqueMediaBytes = groupedFiles.values.compactMap(\.first).reduce(0) {
            $0 + $1.byteCount
        }
        guard uniqueMediaBytes <= SavedThreadPolicy.maximumMediaBytesPerThread,
              effectiveMediaMode != .textOnly || effectiveMediaAssets.isEmpty else {
            throw SavedThreadError.invalidMediaManifest
        }
        var result = self
        result.formatVersion = Self.currentFormatVersion
        result.mediaMode = effectiveMediaMode
        result.mediaAssets = effectiveMediaAssets
        return result
    }
}

enum SavedThreadError: LocalizedError, Equatable {
    case persistenceUnavailable
    case incompleteThread
    case inconsistentPagination
    case tooManyPages
    case unsupportedFormat
    case invalidMediaManifest
    case mediaDownloadFailed
    case mediaStorageLimitExceeded
    case backupStorageLimitExceeded
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            return "本机保存空间暂不可用。"
        case .incompleteThread:
            return "没有拿到完整主楼，未写入本地保存。"
        case .inconsistentPagination:
            return "帖子分页在保存期间发生变化，请稍后重试。"
        case .tooManyPages:
            return "帖子页数超出本机保存上限。"
        case .unsupportedFormat:
            return "本地保存的数据版本无法读取。"
        case .invalidMediaManifest:
            return "离线媒体清单已损坏。"
        case .mediaDownloadFailed:
            return "部分媒体无法安全下载，原有保存未被覆盖。"
        case .mediaStorageLimitExceeded:
            return "这个帖子的离线媒体超过 512 MB 保存上限。"
        case .backupStorageLimitExceeded:
            return "备份内容超过 128 MB。请减少完整媒体保存后再试。"
        case .invalidBackup:
            return "备份文件无效或已损坏。"
        }
    }
}

enum SavedThreadPolicy {
    static let maximumSavedThreads = 100
    static let maximumThreadPages = 10_000
    static let maximumSubpostPages = 10_000
    static let subpostPageSize = 10
    static let maximumStorageByteCount = 128 * 1_024 * 1_024
    static let maximumMediaBytesPerThread = 512 * 1_024 * 1_024
    // FileDocument materializes package contents while handing them to the
    // document picker. Keep a hard ceiling that remains safe on older devices.
    static let maximumBackupBytes = 128 * 1_024 * 1_024
}

@MainActor
final class SavedThreadStore: ObservableObject {
    static let shared = SavedThreadStore()

    @Published private(set) var entries: [SavedThreadSnapshot] = []
    @Published private(set) var persistenceError: String?

    private var file: SecureCodableFile<[SavedThreadSnapshot]>?
    let mediaStore: SavedThreadMediaStore

    private struct BackupImportPlan {
        var entries: [SavedThreadSnapshot]
        var importedThreadIDs: Set<Int64>
    }

    init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        mediaStore = (try? SavedThreadMediaStore(
            baseDirectoryURL: baseDirectoryURL,
            fileManager: fileManager
        )) ?? .unavailable
        do {
            let location = try SecurePersistenceLocation.applicationSupport(
                fileManager: fileManager,
                baseDirectoryURL: baseDirectoryURL
            )
            let file = try SecureCodableFile<[SavedThreadSnapshot]>(
                directoryURL: location.directoryURL,
                fileName: "saved-threads.json",
                fileManager: fileManager,
                maximumByteCount: SavedThreadPolicy.maximumStorageByteCount
            )
            self.file = file
            entries = try Self.normalized(file.load() ?? [])
        } catch {
            file = nil
            persistenceError = error.localizedDescription
        }
    }

    func contains(threadID: Int64) -> Bool {
        entries.contains { $0.id == threadID }
    }

    func snapshot(threadID: Int64) -> SavedThreadSnapshot? {
        entries.first { $0.id == threadID }
    }

    func save(_ snapshot: SavedThreadSnapshot) throws {
        try save(snapshot, preparedMedia: nil)
    }

    func save(
        _ snapshot: SavedThreadSnapshot,
        preparedMedia: PreparedSavedThreadMedia?
    ) throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        let validated = try snapshot.validated()
        try preparedMedia?.commit()
        do {
            entries = try file.update(default: []) { values in
                values.removeAll { $0.id == validated.id }
                values.insert(validated, at: 0)
                values = Array(try Self.normalized(values).prefix(SavedThreadPolicy.maximumSavedThreads))
            }
            preparedMedia?.finish()
            if validated.effectiveMediaMode == .textOnly {
                try? mediaStore.remove(threadID: validated.id)
            }
        } catch {
            preparedMedia?.rollback()
            throw error
        }
        mediaStore.removeOrphans(keeping: Set(entries.map(\.id)))
        persistenceError = nil
    }

    func recordUpdateCheck(
        threadID: Int64,
        latestReplyCount: Int,
        checkedAt: Date = Date()
    ) throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        entries = try file.update(default: []) { values in
            guard let index = values.firstIndex(where: { $0.id == threadID }) else { return }
            values[index].latestCheckedAt = checkedAt
            values[index].latestReplyCount = max(latestReplyCount, values[index].thread.replyCount)
            values = try Self.normalized(values)
        }
        persistenceError = nil
    }

    func importBackup(
        snapshots: [SavedThreadSnapshot],
        mediaFiles: [Int64: [String: Data]],
        replacingExisting: Bool
    ) throws {
        let imported = try Self.normalized(snapshots)
        guard imported.count <= SavedThreadPolicy.maximumSavedThreads else {
            throw SavedThreadError.invalidBackup
        }
        var prepared: [PreparedSavedThreadMedia] = []
        do {
            for snapshot in imported {
                prepared.append(try mediaStore.prepareImport(
                    snapshot: snapshot,
                    files: mediaFiles[snapshot.id] ?? [:]
                ))
            }
            try commitBackupImport(
                imported: imported,
                prepared: prepared,
                replacingExisting: replacingExisting
            )
        } catch {
            prepared.reversed().forEach { $0.rollback() }
            throw error
        }
    }

    func importBackupWithoutBlocking(
        snapshots: [SavedThreadSnapshot],
        mediaFiles: [Int64: [String: Data]],
        replacingExisting: Bool
    ) async throws {
        let imported = try Self.normalized(snapshots)
        guard imported.count <= SavedThreadPolicy.maximumSavedThreads else {
            throw SavedThreadError.invalidBackup
        }
        let mediaStore = mediaStore
        let prepared = try await Task.detached(priority: .userInitiated) {
            var values: [PreparedSavedThreadMedia] = []
            do {
                for snapshot in imported {
                    try Task.checkCancellation()
                    values.append(try mediaStore.prepareImport(
                        snapshot: snapshot,
                        files: mediaFiles[snapshot.id] ?? [:]
                    ))
                }
                return values
            } catch {
                values.reversed().forEach { $0.rollback() }
                throw error
            }
        }.value
        do {
            try commitBackupImport(
                imported: imported,
                prepared: prepared,
                replacingExisting: replacingExisting
            )
        } catch {
            prepared.reversed().forEach { $0.rollback() }
            throw error
        }
    }

    func remove(threadID: Int64) throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        entries = try file.update(default: []) { values in
            values.removeAll { $0.id == threadID }
            values = try Self.normalized(values)
        }
        try mediaStore.remove(threadID: threadID)
        persistenceError = nil
    }

    func clear() throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        try file.replace([])
        try mediaStore.clear()
        entries = []
        persistenceError = nil
    }

    private func commitBackupImport(
        imported: [SavedThreadSnapshot],
        prepared: [PreparedSavedThreadMedia],
        replacingExisting: Bool
    ) throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        guard imported.count == prepared.count else { throw SavedThreadError.invalidBackup }

        // Preparation can run off the main actor. Recompute the winner against
        // the latest store state so an older backup cannot replace newer media.
        let plan = try Self.backupImportPlan(
            imported: imported,
            existing: entries,
            replacingExisting: replacingExisting
        )
        let preparedBySnapshot = Array(zip(imported, prepared))
        let selected = preparedBySnapshot.compactMap { snapshot, media in
            plan.importedThreadIDs.contains(snapshot.id) ? media : nil
        }
        preparedBySnapshot
            .filter { plan.importedThreadIDs.contains($0.0.id) == false }
            .forEach { $0.1.rollback() }

        try selected.forEach { try $0.commit() }
        try file.replace(plan.entries)
        entries = plan.entries
        selected.forEach { $0.finish() }
        mediaStore.removeOrphans(keeping: Set(entries.map(\.id)))
        persistenceError = nil
    }

    private static func backupImportPlan(
        imported: [SavedThreadSnapshot],
        existing: [SavedThreadSnapshot],
        replacingExisting: Bool
    ) throws -> BackupImportPlan {
        if replacingExisting {
            let limited = Array(imported.prefix(SavedThreadPolicy.maximumSavedThreads))
            return BackupImportPlan(
                entries: limited,
                importedThreadIDs: Set(limited.map(\.id))
            )
        }

        var valuesByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var importedThreadIDs = Set<Int64>()
        for snapshot in imported {
            if let current = valuesByID[snapshot.id], current.savedAt >= snapshot.savedAt {
                continue
            }
            valuesByID[snapshot.id] = snapshot
            importedThreadIDs.insert(snapshot.id)
        }

        let limited = Array(
            try normalized(Array(valuesByID.values))
                .prefix(SavedThreadPolicy.maximumSavedThreads)
        )
        importedThreadIDs.formIntersection(limited.map(\.id))
        return BackupImportPlan(entries: limited, importedThreadIDs: importedThreadIDs)
    }

    private static func normalized(_ values: [SavedThreadSnapshot]) throws -> [SavedThreadSnapshot] {
        var knownIDs = Set<Int64>()
        return try values
            .map { try $0.validated() }
            .sorted {
                if $0.savedAt == $1.savedAt { return $0.id > $1.id }
                return $0.savedAt > $1.savedAt
            }
            .filter { knownIDs.insert($0.id).inserted }
    }
}

struct SavedThreadCaptureService {
    let api: any TiebaAPIService

    func capture(
        account: Account?,
        threadID: Int64,
        forumID: Int64? = nil,
        savedAt: Date = Date()
    ) async throws -> SavedThreadSnapshot {
        try Task.checkCancellation()
        var firstPage = try await loadThreadPage(
            account: account,
            threadID: threadID,
            page: 1,
            forumID: forumID
        )
        if ThreadPageMainPostPolicy.mainPost(in: firstPage) == nil {
            firstPage = try await loadThreadPage(
                account: account,
                threadID: threadID,
                page: 1,
                forumID: forumID
            )
        }
        guard firstPage.thread.id == threadID,
              firstPage.totalPage > 0,
              firstPage.totalPage <= SavedThreadPolicy.maximumThreadPages,
              let mainPost = ThreadPageMainPostPolicy.mainPost(in: firstPage),
              mainPost.id > 0,
              firstPage.forum.id > 0 else {
            throw SavedThreadError.incompleteThread
        }

        var orderedPosts = [mainPost]
        var knownPostIDs = Set([mainPost.id])
        appendUnique(firstPage.posts, to: &orderedPosts, knownIDs: &knownPostIDs)

        if firstPage.totalPage > 1 {
            for pageNumber in 2...firstPage.totalPage {
                try Task.checkCancellation()
                let page = try await loadThreadPage(
                    account: account,
                    threadID: threadID,
                    page: pageNumber,
                    forumID: firstPage.forum.id
                )
                guard page.thread.id == threadID,
                      page.currentPage == pageNumber,
                      page.totalPage == firstPage.totalPage else {
                    throw SavedThreadError.inconsistentPagination
                }
                appendUnique(page.posts, to: &orderedPosts, knownIDs: &knownPostIDs)
            }
        }

        orderedPosts.sort {
            if $0.floor == $1.floor { return $0.id < $1.id }
            return $0.floor < $1.floor
        }
        guard orderedPosts.first?.id == mainPost.id else {
            throw SavedThreadError.incompleteThread
        }

        var savedPosts: [SavedThreadPost] = []
        savedPosts.reserveCapacity(orderedPosts.count)
        for post in orderedPosts {
            try Task.checkCancellation()
            let subposts = try await loadAllSubposts(
                account: account,
                threadID: threadID,
                forumID: firstPage.forum.id,
                post: post
            )
            savedPosts.append(SavedThreadPost(post: post, subposts: subposts))
        }

        return try SavedThreadSnapshot(
            thread: firstPage.thread,
            forum: firstPage.forum,
            posts: savedPosts,
            savedAt: savedAt
        ).validated()
    }

    private func loadThreadPage(
        account: Account?,
        threadID: Int64,
        page: Int,
        forumID: Int64?
    ) async throws -> ThreadPage {
        try await api.threadPage(
            account: account,
            threadID: threadID,
            page: page,
            forumID: forumID,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
    }

    private func loadAllSubposts(
        account: Account?,
        threadID: Int64,
        forumID: Int64,
        post: Post
    ) async throws -> [Subpost] {
        guard post.subpostCount > 0 || post.previewSubposts.isEmpty == false else { return [] }
        var result: [Subpost] = []
        var knownIDs = Set<UInt64>()

        for page in 1...SavedThreadPolicy.maximumSubpostPages {
            try Task.checkCancellation()
            let loaded = try await api.subposts(
                account: account,
                threadID: threadID,
                postID: post.id,
                forumID: forumID,
                page: page,
                subpostID: 0
            )
            let previousCount = result.count
            appendUnique(loaded, to: &result, knownIDs: &knownIDs)
            if loaded.count < SavedThreadPolicy.subpostPageSize {
                guard result.count >= max(post.subpostCount, post.previewSubposts.count) else {
                    throw SavedThreadError.incompleteThread
                }
                return result.sorted {
                    if $0.floor == $1.floor { return $0.id < $1.id }
                    return $0.floor < $1.floor
                }
            }
            guard result.count > previousCount else {
                throw SavedThreadError.inconsistentPagination
            }
        }
        throw SavedThreadError.tooManyPages
    }

    private func appendUnique<Element: Identifiable>(
        _ values: [Element],
        to result: inout [Element],
        knownIDs: inout Set<Element.ID>
    ) where Element.ID: Hashable {
        for value in values where knownIDs.insert(value.id).inserted {
            result.append(value)
        }
    }
}
