import Foundation

private actor FileBrowsingHistoryMutationActor {
    private let file: SecureCodableFile<[BrowsingHistoryEntry]>

    init(file: SecureCodableFile<[BrowsingHistoryEntry]>) {
        self.file = file
    }

    func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) throws -> [BrowsingHistoryEntry] {
        try Task.checkCancellation()
        return try file.update(
            default: [],
            beforeCommit: { try Task.checkCancellation() }
        ) { entries in
            try Task.checkCancellation()
            entries = BrowsingHistoryPolicy.adding(entry, to: entries, limit: limit)
        }
    }

    func remove(threadIDs: Set<Int64>) throws -> [BrowsingHistoryEntry] {
        try Task.checkCancellation()
        return try file.update(
            default: [],
            beforeCommit: { try Task.checkCancellation() }
        ) { entries in
            try Task.checkCancellation()
            entries = BrowsingHistoryPolicy.removing(threadIDs: threadIDs, from: entries)
        }
    }

    func removeAll() throws -> [BrowsingHistoryEntry] {
        try Task.checkCancellation()
        return try file.update(
            default: [],
            beforeCommit: { try Task.checkCancellation() }
        ) { entries in
            try Task.checkCancellation()
            entries = []
        }
    }
}

@MainActor
final class FileBrowsingHistoryPersistence: BrowsingHistoryPersistence {
    let capability: PersistenceCapability = .durable

    private let file: SecureCodableFile<[BrowsingHistoryEntry]>
    private let mutationActor: FileBrowsingHistoryMutationActor

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        fileName: String = "browsing-history.json"
    ) throws {
        let file = try SecureCodableFile<[BrowsingHistoryEntry]>(
            directoryURL: directoryURL,
            fileName: fileName,
            fileManager: fileManager
        )
        self.file = file
        mutationActor = FileBrowsingHistoryMutationActor(file: file)
    }

    func load() throws -> [BrowsingHistoryEntry] {
        try file.load() ?? []
    }

    func replaceAll(
        _ entries: [BrowsingHistoryEntry],
        beforeCommit: () throws -> Void
    ) throws {
        try file.replace(entries, beforeCommit: beforeCommit)
    }

    func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) async throws -> [BrowsingHistoryEntry] {
        try await mutationActor.upsert(entry, limit: limit)
    }

    func remove(threadIDs: Set<Int64>) async throws -> [BrowsingHistoryEntry] {
        try await mutationActor.remove(threadIDs: threadIDs)
    }

    func removeAll() async throws -> [BrowsingHistoryEntry] {
        try await mutationActor.removeAll()
    }

    func recoverCorruptedStorage() throws {
        try file.quarantineCorruptedGenerations()
    }
}

@MainActor
final class FileRecentForumPersistence: RecentForumPersistence {
    let capability: PersistenceCapability = .durable

    private let file: SecureCodableFile<[RecentForum]>

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        fileName: String = "recent-forums.json"
    ) throws {
        file = try SecureCodableFile<[RecentForum]>(
            directoryURL: directoryURL,
            fileName: fileName,
            fileManager: fileManager
        )
    }

    func load() throws -> [RecentForum] {
        try file.load() ?? []
    }

    func replaceAll(
        _ entries: [RecentForum],
        beforeCommit: () throws -> Void
    ) throws {
        try file.replace(entries, beforeCommit: beforeCommit)
    }

    func recoverCorruptedStorage() throws {
        try file.quarantineCorruptedGenerations()
    }
}

@MainActor
final class FileSearchHistoryPersistence: SearchHistoryPersistence {
    let capability: PersistenceCapability = .durable

    private let file: SecureCodableFile<[String]>

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        fileName: String = "search-history.json"
    ) throws {
        file = try SecureCodableFile<[String]>(
            directoryURL: directoryURL,
            fileName: fileName,
            fileManager: fileManager
        )
    }

    func load() throws -> [String] {
        try file.load() ?? []
    }

    func replaceAll(
        _ entries: [String],
        beforeCommit: () throws -> Void
    ) throws {
        try file.replace(entries, beforeCommit: beforeCommit)
    }

    func recoverCorruptedStorage() throws {
        try file.quarantineCorruptedGenerations()
    }
}

@MainActor
struct FileOrderedCollectionPersistenceBundle {
    let browsingHistory: FileBrowsingHistoryPersistence
    let recentForums: FileRecentForumPersistence
    let searchHistory: FileSearchHistoryPersistence

    init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        browsingHistory = try FileBrowsingHistoryPersistence(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
        recentForums = try FileRecentForumPersistence(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
        searchHistory = try FileSearchHistoryPersistence(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
    }

    var erased: OrderedCollectionPersistenceBundle {
        OrderedCollectionPersistenceBundle(
            browsingHistory: browsingHistory,
            recentForums: recentForums,
            searchHistory: searchHistory
        )
    }
}
