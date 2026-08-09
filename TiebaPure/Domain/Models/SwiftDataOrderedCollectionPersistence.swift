import Foundation
import SwiftData

private enum BrowsingHistoryDatabaseMutation: Sendable {
    case upsert(BrowsingHistoryEntry, limit: Int)
    case delete(threadIDs: Set<Int64>)
    case deleteAll
}

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

@MainActor
enum AppOrderedCollectionPersistence {
    static let browsingHistory: any BrowsingHistoryPersistence =
        SwiftDataBrowsingHistoryPersistence(modelContainer: AppModelContainer.shared)
    static let recentForums: any RecentForumPersistence =
        SwiftDataRecentForumPersistence(modelContainer: AppModelContainer.shared)
    static let searchHistory: any SearchHistoryPersistence =
        SwiftDataSearchHistoryPersistence(modelContainer: AppModelContainer.shared)
}

extension BrowsingHistoryStore {
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.browsingHistory",
        limit: Int = BrowsingHistoryPolicy.maximumStoredEntries,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: AppOrderedCollectionPersistence.browsingHistory,
            faultInjector: faultInjector,
            now: now
        )
    }

    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.browsingHistory",
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
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.recentForums",
        limit: Int = RecentForumPolicy.maximumStoredEntries,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: AppOrderedCollectionPersistence.recentForums,
            faultInjector: faultInjector,
            now: now
        )
    }

    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.recentForums",
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
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.searchHistory",
        limit: Int = SearchHistoryPolicy.maximumStoredEntries,
        faultInjector: PersistenceFaultInjector = .none
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: AppOrderedCollectionPersistence.searchHistory,
            faultInjector: faultInjector
        )
    }

    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.searchHistory",
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
