import Foundation
import OSLog
import SwiftData

enum PersistenceAvailability: Equatable, Sendable {
    case available
    case unavailable

    var canPersist: Bool {
        self == .available
    }
}

enum PersistenceFaultPoint: Equatable {
    case legacyMigration
    case repair
    case clearAll
}

struct PersistenceFaultInjector {
    static let none = PersistenceFaultInjector { _ in }

    private let handler: (PersistenceFaultPoint) throws -> Void

    init(_ handler: @escaping (PersistenceFaultPoint) throws -> Void) {
        self.handler = handler
    }

    func check(_ point: PersistenceFaultPoint) throws {
        try handler(point)
    }
}

struct PersistenceLoadResult<Value> {
    let value: Value
    let repairError: Error?
}

// Single app-wide SwiftData container shared by every persisted store. Tests
// build their own container from `models` with an in-memory configuration.
enum AppModelContainer {
    struct Resolution {
        let container: ModelContainer
        let availability: PersistenceAvailability

        var isDurable: Bool {
            availability.canPersist
        }
    }

    static let models: [any PersistentModel.Type] = [
        ThreadFavoriteRecord.self,
        ThreadReadingPositionRecord.self,
        BrowsingHistoryRecord.self,
        RecentForumRecord.self,
        SearchHistoryRecord.self,
        ContentDraftRecord.self
    ]

    private static let sharedResolution: Resolution = {
        let schema = Schema(models)
        do {
            return try resolve(
                persistent: {
                    try ModelContainer(
                        for: schema,
                        configurations: ModelConfiguration(schema: schema)
                    )
                },
                fallback: {
                    try ModelContainer(
                        for: schema,
                        configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    )
                }
            )
        } catch {
            fatalError("ModelContainer creation failed: \(error)")
        }
    }()

    static let shared = sharedResolution.container
    static var sharedAvailability: PersistenceAvailability {
        sharedResolution.availability
    }

    /// Resolves a durable container first and degrades to an in-memory
    /// container only when opening the on-disk store fails. The durability bit
    /// is kept alongside the container so a fallback session can import legacy
    /// values for display without deleting their only durable copy.
    static func resolve(
        persistent: () throws -> ModelContainer,
        fallback: () throws -> ModelContainer
    ) throws -> Resolution {
        do {
            return Resolution(container: try persistent(), availability: .available)
        } catch {
            PersistenceDiagnostics.report(error, operation: "open persistent model container")
            return Resolution(container: try fallback(), availability: .unavailable)
        }
    }

    static func persistenceAvailability(for container: ModelContainer) -> PersistenceAvailability {
        persistenceAvailability(for: container, resolvedSharedContainer: sharedResolution)
    }

    static func persistenceAvailability(
        for container: ModelContainer,
        resolvedSharedContainer: Resolution
    ) -> PersistenceAvailability {
        guard container === resolvedSharedContainer.container else {
            // Explicitly injected containers are owned by their caller (tests
            // use this path) and are considered writable unless the store
            // initializer is given an unavailable override.
            return .available
        }
        return resolvedSharedContainer.availability
    }

    static func allowsLegacyCleanup(for container: ModelContainer) -> Bool {
        allowsLegacyCleanup(for: container, resolvedSharedContainer: sharedResolution)
    }

    static func allowsLegacyCleanup(
        for container: ModelContainer,
        resolvedSharedContainer: Resolution
    ) -> Bool {
        persistenceAvailability(
            for: container,
            resolvedSharedContainer: resolvedSharedContainer
        ).canPersist
    }
}

// Each store persists a full snapshot of its in-memory array; sortIndex
// preserves the array order across relaunches exactly as the legacy JSON
// encoding did.
protocol OrderedPersistentRecord: PersistentModel {
    var sortIndex: Int { get }
}

enum PersistenceDiagnostics {
    private static let logger = Logger(
        subsystem: "dev.infinityf4p.tiebapure",
        category: "Persistence"
    )

    static func report(_ error: Error, operation: String) {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}

enum LegacyStorageMigration {
    enum DecodeError: Error {
        case invalidTopLevelArray
    }

    /// The legacy value is removed only after the SwiftData save completes and
    /// only when the destination is durable. A successful write to the
    /// in-memory fallback is useful for the current session but is not a
    /// migration because it cannot survive relaunch.
    static func persistThenRemoveLegacyValue(
        defaults: UserDefaults,
        key: String,
        destinationIsDurable: Bool,
        persist: () throws -> Void
    ) throws {
        try persist()
        guard destinationIsDurable else { return }
        defaults.removeObject(forKey: key)
    }
}

@MainActor
enum PersistedRecordStore {
    static func fetchOrdered<Record: OrderedPersistentRecord>(
        _ type: Record.Type,
        in context: ModelContext
    ) throws -> [Record] {
        let records = try context.fetch(FetchDescriptor<Record>())
        return records.sorted { $0.sortIndex < $1.sortIndex }
    }

    static func fetchAll<Record: PersistentModel>(
        _ type: Record.Type,
        in context: ModelContext
    ) throws -> [Record] {
        try context.fetch(FetchDescriptor<Record>())
    }

    static func replaceAll<Record: OrderedPersistentRecord>(
        _ type: Record.Type,
        with records: [Record],
        in context: ModelContext,
        beforeSave: () throws -> Void = {}
    ) throws {
        do {
            let existing = try context.fetch(FetchDescriptor<Record>())
            for record in existing {
                context.delete(record)
            }
            for record in records {
                context.insert(record)
            }
            try beforeSave()
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Updates one reading-position row in place and prunes only duplicates or
    /// rows beyond the retention limit. Scrolling no longer deletes and
    /// reinserts the entire 500-row table for every visible-floor change.
    static func upsertReadingPosition(
        _ position: ThreadReadingPosition,
        limit: Int,
        in context: ModelContext
    ) throws {
        let effectiveLimit = min(
            max(limit, 0),
            LocalThreadLibraryPolicy.maximumReadingPositions
        )
        var records = try context.fetch(FetchDescriptor<ThreadReadingPositionRecord>())
        guard effectiveLimit > 0 else {
            for record in records {
                context.delete(record)
            }
            try save(context)
            return
        }

        if let existing = records.first(where: { $0.threadID == position.threadID }) {
            existing.postIDBitPattern = Int64(bitPattern: position.postID)
            existing.floor = position.floor
            existing.updatedAt = position.updatedAt
        } else {
            let inserted = ThreadReadingPositionRecord(entry: position, sortIndex: 0)
            context.insert(inserted)
            records.append(inserted)
        }

        records.sort {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.threadID < $1.threadID
        }

        var seenThreadIDs = Set<Int64>()
        var retainedCount = 0
        for record in records {
            guard seenThreadIDs.insert(record.threadID).inserted,
                  retainedCount < effectiveLimit else {
                context.delete(record)
                continue
            }
            record.sortIndex = retainedCount
            retainedCount += 1
        }
        try save(context)
    }

    static func deleteReadingPosition(
        threadID: Int64,
        in context: ModelContext
    ) throws {
        let requestedThreadID = threadID
        let records = try context.fetch(FetchDescriptor<ThreadReadingPositionRecord>(
            predicate: #Predicate { record in
                record.threadID == requestedThreadID
            }
        ))
        for record in records {
            context.delete(record)
        }
        try save(context)
    }

    static func clearThreadLibrary(
        in context: ModelContext,
        beforeSave: () throws -> Void = {}
    ) throws {
        do {
            let favorites = try context.fetch(FetchDescriptor<ThreadFavoriteRecord>())
            let positions = try context.fetch(FetchDescriptor<ThreadReadingPositionRecord>())
            for favorite in favorites {
                context.delete(favorite)
            }
            for position in positions {
                context.delete(position)
            }
            try beforeSave()
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

@Model
final class ThreadFavoriteRecord {
    var threadID: Int64
    var forumID: Int64?
    var title: String
    var authorDisplayName: String
    var forumDisplayName: String?
    var savedAt: Date
    var sortIndex: Int

    init(entry: ThreadFavoriteEntry, sortIndex: Int) {
        self.threadID = entry.threadID
        self.forumID = entry.forumID
        self.title = entry.title
        self.authorDisplayName = entry.authorDisplayName
        self.forumDisplayName = entry.forumDisplayName
        self.savedAt = entry.savedAt
        self.sortIndex = sortIndex
    }

    var entry: ThreadFavoriteEntry {
        ThreadFavoriteEntry(
            threadID: threadID,
            forumID: forumID,
            title: title,
            authorDisplayName: authorDisplayName,
            forumDisplayName: forumDisplayName,
            savedAt: savedAt
        )
    }
}

extension ThreadFavoriteRecord: OrderedPersistentRecord {}

@Model
final class ThreadReadingPositionRecord {
    var threadID: Int64
    // UInt64 bit pattern; the backing store has no unsigned 64-bit column.
    var postIDBitPattern: Int64
    var floor: Int
    var updatedAt: Date
    var sortIndex: Int

    init(entry: ThreadReadingPosition, sortIndex: Int) {
        self.threadID = entry.threadID
        self.postIDBitPattern = Int64(bitPattern: entry.postID)
        self.floor = entry.floor
        self.updatedAt = entry.updatedAt
        self.sortIndex = sortIndex
    }

    var entry: ThreadReadingPosition {
        ThreadReadingPosition(
            threadID: threadID,
            postID: UInt64(bitPattern: postIDBitPattern),
            floor: floor,
            updatedAt: updatedAt
        )
    }
}

extension ThreadReadingPositionRecord: OrderedPersistentRecord {}

@Model
final class BrowsingHistoryRecord {
    var threadID: Int64
    var forumID: Int64?
    var title: String
    var authorDisplayName: String
    var forumDisplayName: String?
    var visitedAt: Date
    var sortIndex: Int

    init(entry: BrowsingHistoryEntry, sortIndex: Int) {
        self.threadID = entry.threadID
        self.forumID = entry.forumID
        self.title = entry.title
        self.authorDisplayName = entry.authorDisplayName
        self.forumDisplayName = entry.forumDisplayName
        self.visitedAt = entry.visitedAt
        self.sortIndex = sortIndex
    }

    var entry: BrowsingHistoryEntry {
        BrowsingHistoryEntry(
            threadID: threadID,
            forumID: forumID,
            title: title,
            authorDisplayName: authorDisplayName,
            forumDisplayName: forumDisplayName,
            visitedAt: visitedAt
        )
    }
}

extension BrowsingHistoryRecord: OrderedPersistentRecord {}

@Model
final class RecentForumRecord {
    var name: String
    var displayName: String
    var avatarURL: URL?
    var updatedAt: Date
    var sortIndex: Int

    init(entry: RecentForum, sortIndex: Int) {
        self.name = entry.name
        self.displayName = entry.displayName
        self.avatarURL = entry.avatarURL
        self.updatedAt = entry.updatedAt
        self.sortIndex = sortIndex
    }

    var entry: RecentForum {
        RecentForum(
            name: name,
            displayName: displayName,
            avatarURL: avatarURL,
            updatedAt: updatedAt
        )
    }
}

extension RecentForumRecord: OrderedPersistentRecord {}

@Model
final class SearchHistoryRecord {
    var keyword: String
    var sortIndex: Int

    init(keyword: String, sortIndex: Int) {
        self.keyword = keyword
        self.sortIndex = sortIndex
    }
}

extension SearchHistoryRecord: OrderedPersistentRecord {}

@Model
final class ContentDraftRecord {
    var accountID: String
    var targetKey: String
    var targetData: Data
    var title: String
    var body: String
    @Attribute(.externalStorage) var imagesBlob: Data
    // Optional so existing stores can migrate without materializing external
    // attachment blobs. Legacy rows are backfilled off the main actor.
    var imagesByteCount: Int?
    var updatedAt: Date

    init(
        accountID: String,
        targetKey: String,
        targetData: Data,
        title: String,
        body: String,
        imagesBlob: Data,
        imagesByteCount: Int? = nil,
        updatedAt: Date
    ) {
        self.accountID = accountID
        self.targetKey = targetKey
        self.targetData = targetData
        self.title = title
        self.body = body
        self.imagesBlob = imagesBlob
        self.imagesByteCount = imagesByteCount ?? imagesBlob.count
        self.updatedAt = updatedAt
    }
}
