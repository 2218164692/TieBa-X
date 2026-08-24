import Foundation

#if TIEBAX_ENABLE_SWIFTDATA
import SwiftData

@available(iOS 17.0, *)
@Model
final class OrderedCollectionBackendMarkerRecord {
    var key: String
    var formatVersion: Int
    var generationID: String

    init(key: String, formatVersion: Int, generationID: String) {
        self.key = key
        self.formatVersion = formatVersion
        self.generationID = generationID
    }
}

@MainActor
@available(iOS 17.0, *)
final class SwiftDataOrderedCollectionBackendMarkerPersistence:
    OrderedCollectionBackendMarkerPersistence
{
    private static let markerKey = "ordered-collections"
    private static let markerFormatVersion = 1

    let capability: PersistenceCapability

    private let modelContext: ModelContext

    init(
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil
    ) {
        modelContext = modelContainer.mainContext
        let resolvedAvailability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        guard resolvedAvailability.canPersist else {
            capability = .fallback
            return
        }
        capability = AppModelContainer.allowsLegacyCleanup(for: modelContainer)
            ? .durable
            : .fallback
    }

    func loadGeneration() throws -> String? {
        let markers = try modelContext.fetch(
            FetchDescriptor<OrderedCollectionBackendMarkerRecord>()
        ).filter { $0.key == Self.markerKey }
        guard markers.count <= 1 else {
            throw OrderedCollectionPersistenceFactoryError.destinationMarkerMismatch
        }
        guard let marker = markers.first else { return nil }
        guard marker.formatVersion == Self.markerFormatVersion,
              UUID(uuidString: marker.generationID) != nil else {
            throw OrderedCollectionPersistenceFactoryError.destinationMarkerMismatch
        }
        return marker.generationID
    }

    func replaceGeneration(_ generation: String) throws {
        guard capability.isDurable else {
            throw OrderedCollectionPersistenceFactoryError.destinationMarkerUnavailable
        }
        guard UUID(uuidString: generation) != nil else {
            throw OrderedCollectionPersistenceFactoryError.destinationMarkerMismatch
        }

        do {
            let markers = try modelContext.fetch(
                FetchDescriptor<OrderedCollectionBackendMarkerRecord>()
            ).filter { $0.key == Self.markerKey }
            for marker in markers {
                modelContext.delete(marker)
            }
            modelContext.insert(OrderedCollectionBackendMarkerRecord(
                key: Self.markerKey,
                formatVersion: Self.markerFormatVersion,
                generationID: generation
            ))
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

private enum BrowsingHistoryDatabaseMutation: Sendable {
    case upsert(BrowsingHistoryEntry, limit: Int)
    case delete(threadIDs: Set<Int64>)
    case deleteAll
}

@available(iOS 17.0, *)
@ModelActor
private actor BrowsingHistoryDatabaseActor {
    func apply(_ mutation: BrowsingHistoryDatabaseMutation) throws -> [BrowsingHistoryEntry] {
        switch mutation {
        case let .upsert(entry, limit):
            return try upsert(entry, limit: limit)
        case let .delete(threadIDs):
            return try delete(threadIDs: threadIDs)
        case .deleteAll:
            return try deleteAll()
        }
    }

    private func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) throws -> [BrowsingHistoryEntry] {
        try Task.checkCancellation()
        let effectiveLimit = min(max(limit, 0), BrowsingHistoryPolicy.maximumStoredEntries)

        do {
            var records = try modelContext.fetch(FetchDescriptor<BrowsingHistoryRecord>())
            guard effectiveLimit > 0 else {
                for record in records {
                    modelContext.delete(record)
                }
                try Task.checkCancellation()
                try modelContext.save()
                return []
            }

            if let existing = records.first(where: { $0.threadID == entry.threadID }) {
                existing.forumID = entry.forumID
                existing.title = entry.title
                existing.authorDisplayName = entry.authorDisplayName
                existing.forumDisplayName = entry.forumDisplayName
                existing.visitedAt = entry.visitedAt
            } else {
                let inserted = BrowsingHistoryRecord(entry: entry, sortIndex: 0)
                modelContext.insert(inserted)
                records.append(inserted)
            }

            records.sort(by: Self.isOrderedBefore)
            var seenThreadIDs = Set<Int64>()
            var retained: [BrowsingHistoryRecord] = []
            retained.reserveCapacity(min(records.count, effectiveLimit))
            for record in records {
                guard seenThreadIDs.insert(record.threadID).inserted,
                      retained.count < effectiveLimit else {
                    modelContext.delete(record)
                    continue
                }
                record.sortIndex = retained.count
                retained.append(record)
            }
            try Task.checkCancellation()
            try modelContext.save()
            return retained.map(\.entry)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func delete(threadIDs: Set<Int64>) throws -> [BrowsingHistoryEntry] {
        try Task.checkCancellation()
        do {
            var records = try modelContext.fetch(FetchDescriptor<BrowsingHistoryRecord>())
            for record in records where threadIDs.contains(record.threadID) {
                modelContext.delete(record)
            }
            records.removeAll { threadIDs.contains($0.threadID) }
            records.sort(by: Self.isOrderedBefore)
            for (index, record) in records.enumerated() {
                record.sortIndex = index
            }
            try Task.checkCancellation()
            try modelContext.save()
            return records.map(\.entry)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func deleteAll() throws -> [BrowsingHistoryEntry] {
        try Task.checkCancellation()
        do {
            let records = try modelContext.fetch(FetchDescriptor<BrowsingHistoryRecord>())
            for record in records {
                modelContext.delete(record)
            }
            try Task.checkCancellation()
            try modelContext.save()
            return []
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func isOrderedBefore(
        _ lhs: BrowsingHistoryRecord,
        _ rhs: BrowsingHistoryRecord
    ) -> Bool {
        if lhs.visitedAt != rhs.visitedAt {
            return lhs.visitedAt > rhs.visitedAt
        }
        return lhs.threadID > rhs.threadID
    }
}

@MainActor
@available(iOS 17.0, *)
final class SwiftDataBrowsingHistoryPersistence: BrowsingHistoryPersistence {
    let capability: PersistenceCapability

    private let modelContext: ModelContext
    private let databaseActorTask: Task<BrowsingHistoryDatabaseActor, Never>

    init(
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil
    ) {
        modelContext = modelContainer.mainContext
        let resolvedAvailability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        capability = Self.capability(
            availability: resolvedAvailability,
            modelContainer: modelContainer
        )
        databaseActorTask = Task.detached(priority: .utility) {
            BrowsingHistoryDatabaseActor(modelContainer: modelContainer)
        }
    }

    func load() throws -> [BrowsingHistoryEntry] {
        try PersistedRecordStore.fetchOrdered(
            BrowsingHistoryRecord.self,
            in: modelContext
        ).map(\.entry)
    }

    func replaceAll(
        _ entries: [BrowsingHistoryEntry],
        beforeCommit: () throws -> Void
    ) throws {
        try PersistedRecordStore.replaceAll(
            BrowsingHistoryRecord.self,
            with: entries.enumerated().map {
                BrowsingHistoryRecord(entry: $0.element, sortIndex: $0.offset)
            },
            in: modelContext,
            beforeSave: beforeCommit
        )
    }

    func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) async throws -> [BrowsingHistoryEntry] {
        let databaseActor = await databaseActorTask.value
        return try await databaseActor.apply(.upsert(entry, limit: limit))
    }

    func remove(threadIDs: Set<Int64>) async throws -> [BrowsingHistoryEntry] {
        let databaseActor = await databaseActorTask.value
        return try await databaseActor.apply(.delete(threadIDs: threadIDs))
    }

    func removeAll() async throws -> [BrowsingHistoryEntry] {
        let databaseActor = await databaseActorTask.value
        return try await databaseActor.apply(.deleteAll)
    }

    private static func capability(
        availability: PersistenceAvailability,
        modelContainer: ModelContainer
    ) -> PersistenceCapability {
        guard availability.canPersist else { return .fallback }
        return AppModelContainer.allowsLegacyCleanup(for: modelContainer)
            ? .durable
            : .fallback
    }
}

@MainActor
@available(iOS 17.0, *)
final class SwiftDataRecentForumPersistence: RecentForumPersistence {
    let capability: PersistenceCapability

    private let modelContext: ModelContext

    init(
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil
    ) {
        modelContext = modelContainer.mainContext
        let resolvedAvailability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        guard resolvedAvailability.canPersist else {
            capability = .fallback
            return
        }
        capability = AppModelContainer.allowsLegacyCleanup(for: modelContainer)
            ? .durable
            : .fallback
    }

    func load() throws -> [RecentForum] {
        try PersistedRecordStore.fetchOrdered(
            RecentForumRecord.self,
            in: modelContext
        ).map(\.entry)
    }

    func replaceAll(
        _ entries: [RecentForum],
        beforeCommit: () throws -> Void
    ) throws {
        try PersistedRecordStore.replaceAll(
            RecentForumRecord.self,
            with: entries.enumerated().map {
                RecentForumRecord(entry: $0.element, sortIndex: $0.offset)
            },
            in: modelContext,
            beforeSave: beforeCommit
        )
    }
}

@MainActor
@available(iOS 17.0, *)
final class SwiftDataSearchHistoryPersistence: SearchHistoryPersistence {
    let capability: PersistenceCapability

    private let modelContext: ModelContext

    init(
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil
    ) {
        modelContext = modelContainer.mainContext
        let resolvedAvailability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        guard resolvedAvailability.canPersist else {
            capability = .fallback
            return
        }
        capability = AppModelContainer.allowsLegacyCleanup(for: modelContainer)
            ? .durable
            : .fallback
    }

    func load() throws -> [String] {
        try PersistedRecordStore.fetchOrdered(
            SearchHistoryRecord.self,
            in: modelContext
        ).map(\.keyword)
    }

    func replaceAll(
        _ entries: [String],
        beforeCommit: () throws -> Void
    ) throws {
        try PersistedRecordStore.replaceAll(
            SearchHistoryRecord.self,
            with: entries.enumerated().map {
                SearchHistoryRecord(keyword: $0.element, sortIndex: $0.offset)
            },
            in: modelContext,
            beforeSave: beforeCommit
        )
    }
}

extension BrowsingHistoryStore {
    @available(iOS 17.0, *)
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "com.tiebax.browsingHistory",
        limit: Int = BrowsingHistoryPolicy.maximumStoredEntries,
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: SwiftDataBrowsingHistoryPersistence(
                modelContainer: modelContainer,
                persistenceAvailability: persistenceAvailability
            ),
            faultInjector: faultInjector,
            now: now
        )
    }
}

extension RecentForumStore {
    @available(iOS 17.0, *)
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "com.tiebax.recentForums",
        limit: Int = RecentForumPolicy.maximumStoredEntries,
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: SwiftDataRecentForumPersistence(
                modelContainer: modelContainer,
                persistenceAvailability: persistenceAvailability
            ),
            faultInjector: faultInjector,
            now: now
        )
    }
}

extension SearchHistoryStore {
    @available(iOS 17.0, *)
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "com.tiebax.searchHistory",
        limit: Int = SearchHistoryPolicy.maximumStoredEntries,
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil,
        faultInjector: PersistenceFaultInjector = .none
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: SwiftDataSearchHistoryPersistence(
                modelContainer: modelContainer,
                persistenceAvailability: persistenceAvailability
            ),
            faultInjector: faultInjector
        )
    }
}
#endif
