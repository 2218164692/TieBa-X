import Foundation
import SwiftData

// Legacy UserDefaults blobs are decoded element by element during the one-time
// migration into SwiftData: a single corrupt entry must not drop the rest.
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

enum PersistedArrayDecoder {
    /// Returns `nil` only when the top-level payload cannot be decoded as an
    /// array. A valid empty array returns `[]`, while corrupt elements inside a
    /// valid array are still discarded individually.
    static func decode<Element: Decodable>(_ type: Element.Type, from data: Data) -> [Element]? {
        guard let boxes = try? JSONDecoder().decode(
            [FailableDecodable<Element>].self,
            from: data
        ) else {
            return nil
        }
        return boxes.compactMap(\.value)
    }
}

enum LocalThreadListSearchPolicy {
    static func matches(query: String, fields: [String?]) -> Bool {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard terms.isEmpty == false else { return true }

        let searchableText = fields.compactMap { $0 }.joined(separator: "\n")
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive
        ]
        return terms.allSatisfy { term in
            searchableText.range(of: term, options: options) != nil
        }
    }
}

enum LocalThreadListSelectionPolicy {
    static func retainedSelection(
        _ selection: Set<Int64>,
        visibleThreadIDs: [Int64]
    ) -> Set<Int64> {
        selection.intersection(Set(visibleThreadIDs))
    }

    static func selectionByTogglingAll(
        _ selection: Set<Int64>,
        visibleThreadIDs: [Int64]
    ) -> Set<Int64> {
        let visible = Set(visibleThreadIDs)
        guard visible.isEmpty == false else { return [] }
        let retained = selection.intersection(visible)
        return retained == visible ? [] : visible
    }
}

private enum ThreadReadingPositionDatabaseMutation: Sendable {
    case upsert(ThreadReadingPosition, limit: Int)
    case delete(threadID: Int64)
    case deleteAll
}

@ModelActor
private actor ThreadReadingPositionDatabaseActor {
    func apply(
        _ mutation: ThreadReadingPositionDatabaseMutation
    ) throws -> [ThreadReadingPosition] {
        switch mutation {
        case let .upsert(position, limit):
            return try upsert(position, limit: limit)
        case let .delete(threadID):
            return try delete(threadID: threadID)
        case .deleteAll:
            return try deleteAll()
        }
    }

    private func upsert(
        _ position: ThreadReadingPosition,
        limit: Int
    ) throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        let effectiveLimit = min(
            max(limit, 0),
            LocalThreadLibraryPolicy.maximumReadingPositions
        )

        do {
            var records = try modelContext.fetch(
                FetchDescriptor<ThreadReadingPositionRecord>()
            )
            guard effectiveLimit > 0 else {
                for record in records {
                    modelContext.delete(record)
                }
                try Task.checkCancellation()
                try save()
                return []
            }

            if let existing = records.first(where: { $0.threadID == position.threadID }) {
                existing.postIDBitPattern = Int64(bitPattern: position.postID)
                existing.floor = position.floor
                existing.updatedAt = position.updatedAt
            } else {
                let inserted = ThreadReadingPositionRecord(entry: position, sortIndex: 0)
                modelContext.insert(inserted)
                records.append(inserted)
            }

            records.sort {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.threadID < $1.threadID
            }

            var seenThreadIDs = Set<Int64>()
            var retained: [ThreadReadingPositionRecord] = []
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
            try save()
            return retained.map(\.entry)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func delete(threadID: Int64) throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        let requestedThreadID = threadID
        do {
            let records = try modelContext.fetch(FetchDescriptor<ThreadReadingPositionRecord>(
                predicate: #Predicate { record in
                    record.threadID == requestedThreadID
                }
            ))
            for record in records {
                modelContext.delete(record)
            }
            try Task.checkCancellation()
            try save()
            return try orderedPositions()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func deleteAll() throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        do {
            let records = try modelContext.fetch(
                FetchDescriptor<ThreadReadingPositionRecord>()
            )
            for record in records {
                modelContext.delete(record)
            }
            try Task.checkCancellation()
            try save()
            return []
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func orderedPositions() throws -> [ThreadReadingPosition] {
        try modelContext.fetch(FetchDescriptor<ThreadReadingPositionRecord>())
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.entry)
    }

    private func save() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }
}

struct ThreadReadingPosition: Codable, Equatable, Identifiable, Sendable {
    var threadID: Int64
    var postID: UInt64
    var floor: Int
    var updatedAt: Date

    var id: Int64 { threadID }
}

enum LocalThreadLibraryPolicy {
    static let maximumReadingPositions = 500

    static func readingPosition(
        threadID: Int64,
        postID: UInt64,
        floor: Int,
        updatedAt: Date
    ) -> ThreadReadingPosition? {
        // Restore targets the post ID; floor is display-only and hot-sorted
        // responses legitimately omit it (floor == 0).
        guard threadID > 0, postID > 0, floor >= 0 else { return nil }
        return ThreadReadingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor,
            updatedAt: updatedAt
        )
    }

    static func addingReadingPosition(
        _ position: ThreadReadingPosition,
        to positions: [ThreadReadingPosition],
        limit: Int
    ) -> [ThreadReadingPosition] {
        let effectiveLimit = min(max(limit, 0), maximumReadingPositions)
        guard effectiveLimit > 0 else { return [] }
        var updated = positions.filter { $0.threadID != position.threadID }
        updated.insert(position, at: 0)
        return Array(updated.prefix(effectiveLimit))
    }

    static func sanitizedReadingPositions(
        _ positions: [ThreadReadingPosition],
        limit: Int
    ) -> [ThreadReadingPosition] {
        let effectiveLimit = min(max(limit, 0), maximumReadingPositions)
        guard effectiveLimit > 0 else { return [] }
        var seenThreadIDs = Set<Int64>()
        var result: [ThreadReadingPosition] = []

        let ordered = positions.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.threadID > $1.threadID
        }
        for position in ordered {
            guard position.threadID > 0,
                  position.postID > 0,
                  position.floor >= 0,
                  position.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  seenThreadIDs.insert(position.threadID).inserted else { continue }
            result.append(position)
            if result.count == effectiveLimit { break }
        }

        return result
    }

    private static func normalized(_ value: String, maximumLength: Int) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return String(collapsed.prefix(maximumLength))
    }
}

@MainActor
final class LocalThreadLibraryStore: ObservableObject {
    static let shared = LocalThreadLibraryStore()

    private let defaults: UserDefaults
    private let favoritesKey: String
    private let readingPositionsKey: String
    private let readingPositionLimit: Int
    private let now: () -> Date
    private let modelContext: ModelContext
    private let readingPositionDatabaseActorTask: Task<ThreadReadingPositionDatabaseActor, Never>
    private let persistentBackendIsAvailable: Bool
    private let faultInjector: PersistenceFaultInjector
    private var readingPositionMutationTail: Task<Bool, Never>?
    private var readingPositionMutationTailID: UUID?
    private var pendingReadingPositionMutationCount = 0

    @Published private(set) var readingPositions: [ThreadReadingPosition]
    @Published private(set) var persistenceAvailability: PersistenceAvailability

    init(
        defaults: UserDefaults = .standard,
        favoritesKey: String = "dev.infinityf4p.tiebapure.threadFavorites",
        readingPositionsKey: String = "dev.infinityf4p.tiebapure.threadReadingPositions",
        readingPositionLimit: Int = LocalThreadLibraryPolicy.maximumReadingPositions,
        modelContainer: ModelContainer = AppModelContainer.shared,
        persistenceAvailability: PersistenceAvailability? = nil,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.favoritesKey = favoritesKey
        self.readingPositionsKey = readingPositionsKey
        self.readingPositionLimit = min(
            max(readingPositionLimit, 0),
            LocalThreadLibraryPolicy.maximumReadingPositions
        )
        self.now = now
        self.faultInjector = faultInjector
        let context = modelContainer.mainContext
        modelContext = context
        readingPositionDatabaseActorTask = Task.detached(priority: .utility) {
            ThreadReadingPositionDatabaseActor(modelContainer: modelContainer)
        }
        let initialAvailability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        persistentBackendIsAvailable = initialAvailability.canPersist
        self.persistenceAvailability = initialAvailability
        let destinationIsDurable = initialAvailability.canPersist
            && AppModelContainer.allowsLegacyCleanup(for: modelContainer)
        var legacyPositionsFallback: [ThreadReadingPosition]?
        var legacyPositionsMigrationFailed = false
        do {
            try Self.migrateLegacyReadingPositions(
                defaults: defaults,
                key: readingPositionsKey,
                context: context,
                limit: self.readingPositionLimit,
                destinationIsDurable: destinationIsDurable,
                legacyFallback: &legacyPositionsFallback,
                faultInjector: faultInjector
            )
        } catch {
            PersistenceDiagnostics.report(error, operation: "migrate reading positions")
            self.persistenceAvailability = .unavailable
            legacyPositionsMigrationFailed = true
        }
        var loadedReadingPositions: [ThreadReadingPosition]
        do {
            let result = try Self.loadAndRepairReadingPositions(
                context: context,
                limit: self.readingPositionLimit,
                canRepair: persistentBackendIsAvailable,
                faultInjector: faultInjector
            )
            loadedReadingPositions = result.value
            if let error = result.repairError {
                PersistenceDiagnostics.report(error, operation: "repair reading positions")
                self.persistenceAvailability = .unavailable
            }
        } catch {
            PersistenceDiagnostics.report(error, operation: "load reading positions")
            loadedReadingPositions = legacyPositionsMigrationFailed ? (legacyPositionsFallback ?? []) : []
            self.persistenceAvailability = .unavailable
        }
        if legacyPositionsMigrationFailed, loadedReadingPositions.isEmpty,
           let legacyPositionsFallback {
            loadedReadingPositions = legacyPositionsFallback
        }
        readingPositions = loadedReadingPositions
        // Collections live on the Baidu account now; the rows this app used to
        // keep are dropped once so they stop taking up space.
        Self.purgeRetiredFavorites(
            defaults: defaults,
            key: favoritesKey,
            context: context,
            canWrite: persistentBackendIsAvailable
        )
    }

    @discardableResult
    func reload() -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        var succeeded = true
        do {
            let result = try Self.loadAndRepairReadingPositions(
                context: modelContext,
                limit: readingPositionLimit,
                canRepair: persistentBackendIsAvailable,
                faultInjector: faultInjector
            )
            readingPositions = result.value
            if let error = result.repairError {
                PersistenceDiagnostics.report(error, operation: "repair reading positions")
                succeeded = false
            }
        } catch {
            PersistenceDiagnostics.report(error, operation: "reload reading positions")
            succeeded = false
        }
        if succeeded {
            markPersistenceSucceeded()
        } else {
            persistenceAvailability = .unavailable
        }
        return succeeded
    }

    func position(for threadID: Int64) -> ThreadReadingPosition? {
        readingPositions.first { $0.threadID == threadID }
    }

    @discardableResult
    func recordReadingPositionInBackground(
        threadID: Int64,
        postID: UInt64,
        floor: Int
    ) async -> Bool {
        await enqueueReadingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor
        ).value
    }

    func enqueueReadingPosition(
        threadID: Int64,
        postID: UInt64,
        floor: Int
    ) -> Task<Bool, Never> {
        guard let position = LocalThreadLibraryPolicy.readingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor,
            updatedAt: now()
        ) else { return completedReadingPositionMutation(false) }
        if pendingReadingPositionMutationCount == 0,
           let current = self.position(for: threadID),
           current.postID == postID,
           current.floor == floor {
            return completedReadingPositionMutation(true)
        }
        return enqueueReadingPositionMutation(
            .upsert(position, limit: readingPositionLimit),
            operation: "save reading position"
        )
    }

    @discardableResult
    func clearReadingPositionInBackground(threadID: Int64) async -> Bool {
        await enqueueClearReadingPosition(threadID: threadID).value
    }

    func enqueueClearReadingPosition(threadID: Int64) -> Task<Bool, Never> {
        guard pendingReadingPositionMutationCount > 0
                || readingPositions.contains(where: { $0.threadID == threadID }) else {
            return completedReadingPositionMutation(true)
        }
        return enqueueReadingPositionMutation(
            .delete(threadID: threadID),
            operation: "clear reading position"
        )
    }

    @discardableResult
    func clearReadingPositionsInBackground() async -> Bool {
        await enqueueClearReadingPositions().value
    }

    func enqueueClearReadingPositions() -> Task<Bool, Never> {
        enqueueReadingPositionMutation(
            .deleteAll,
            operation: "clear reading positions",
            removesLegacyValueOnSuccess: true
        )
    }

    func waitForPendingReadingPositionMutations() async {
        while let tail = readingPositionMutationTail {
            _ = await tail.value
        }
    }

    @discardableResult
    func recordReadingPosition(threadID: Int64, postID: UInt64, floor: Int) -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard let position = LocalThreadLibraryPolicy.readingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor,
            updatedAt: now()
        ) else { return false }
        if let current = self.position(for: threadID),
           current.postID == postID,
           current.floor == floor {
            return true
        }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        let updated = LocalThreadLibraryPolicy.addingReadingPosition(
            position,
            to: readingPositions,
            limit: readingPositionLimit
        )
        do {
            try PersistedRecordStore.upsertReadingPosition(
                position,
                limit: readingPositionLimit,
                in: modelContext
            )
            readingPositions = updated
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "save reading position")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    func clearReadingPosition(threadID: Int64) -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard readingPositions.contains(where: { $0.threadID == threadID }) else { return true }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try PersistedRecordStore.deleteReadingPosition(
                threadID: threadID,
                in: modelContext
            )
            readingPositions.removeAll { $0.threadID == threadID }
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear reading position")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    func clearReadingPositions() -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try PersistedRecordStore.replaceAll(
                ThreadReadingPositionRecord.self,
                with: [],
                in: modelContext
            )
            defaults.removeObject(forKey: readingPositionsKey)
            readingPositions = []
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear reading positions")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    func clearAll() -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try PersistedRecordStore.clearThreadLibrary(in: modelContext) {
                try faultInjector.check(.clearAll)
            }
            defaults.removeObject(forKey: readingPositionsKey)
            readingPositions = []
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear local thread library")
            persistenceAvailability = .unavailable
            return false
        }
    }

    private func enqueueReadingPositionMutation(
        _ mutation: ThreadReadingPositionDatabaseMutation,
        operation: String,
        removesLegacyValueOnSuccess: Bool = false
    ) -> Task<Bool, Never> {
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return completedReadingPositionMutation(false)
        }

        let previousMutation = readingPositionMutationTail
        let databaseActorTask = readingPositionDatabaseActorTask
        let mutationID = UUID()
        pendingReadingPositionMutationCount += 1
        readingPositionMutationTailID = mutationID

        let mutationTask = Task { @MainActor [weak self] in
            if let previousMutation {
                _ = await previousMutation.value
            }
            guard let self else { return false }
            defer {
                self.pendingReadingPositionMutationCount = max(
                    self.pendingReadingPositionMutationCount - 1,
                    0
                )
                if self.readingPositionMutationTailID == mutationID {
                    self.readingPositionMutationTail = nil
                    self.readingPositionMutationTailID = nil
                }
            }

            do {
                let databaseActor = await databaseActorTask.value
                let persisted = try await databaseActor.apply(mutation)
                self.readingPositions = persisted
                if removesLegacyValueOnSuccess {
                    self.defaults.removeObject(forKey: self.readingPositionsKey)
                }
                self.markPersistenceSucceeded()
                return true
            } catch {
                PersistenceDiagnostics.report(error, operation: operation)
                self.persistenceAvailability = .unavailable
                return false
            }
        }
        readingPositionMutationTail = mutationTask
        return mutationTask
    }

    private func completedReadingPositionMutation(_ result: Bool) -> Task<Bool, Never> {
        Task { result }
    }

    private func markPersistenceSucceeded() {
        guard persistentBackendIsAvailable else { return }
        persistenceAvailability = .available
    }

    private static func loadAndRepairReadingPositions(
        context: ModelContext,
        limit: Int,
        canRepair: Bool,
        faultInjector: PersistenceFaultInjector = .none
    ) throws -> PersistenceLoadResult<[ThreadReadingPosition]> {
        let raw = try PersistedRecordStore.fetchOrdered(
            ThreadReadingPositionRecord.self,
            in: context
        ).map(\.entry)
        let sanitized = LocalThreadLibraryPolicy.sanitizedReadingPositions(
            raw,
            limit: limit
        )
        if canRepair, raw != sanitized {
            do {
                try PersistedRecordStore.replaceAll(
                    ThreadReadingPositionRecord.self,
                    with: sanitized.enumerated().map {
                        ThreadReadingPositionRecord(entry: $0.element, sortIndex: $0.offset)
                    },
                    in: context
                ) {
                    try faultInjector.check(.repair)
                }
            } catch {
                return PersistenceLoadResult(value: sanitized, repairError: error)
            }
        }
        return PersistenceLoadResult(value: sanitized, repairError: nil)
    }

    /// Thread collections moved to the Baidu account, so the rows and the
    /// pre-SwiftData blob this app used to keep are deleted on the next launch.
    /// A failure here costs nothing but the space, so it never marks the store
    /// unavailable.
    private static func purgeRetiredFavorites(
        defaults: UserDefaults,
        key: String,
        context: ModelContext,
        canWrite: Bool
    ) {
        defaults.removeObject(forKey: key)
        guard canWrite else { return }
        do {
            try PersistedRecordStore.replaceAll(
                ThreadFavoriteRecord.self,
                with: [],
                in: context
            )
        } catch {
            PersistenceDiagnostics.report(error, operation: "purge retired thread favorites")
        }
    }

    // One-time import of the pre-SwiftData UserDefaults JSON blob.
    private static func migrateLegacyReadingPositions(
        defaults: UserDefaults,
        key: String,
        context: ModelContext,
        limit: Int,
        destinationIsDurable: Bool,
        legacyFallback: inout [ThreadReadingPosition]?,
        faultInjector: PersistenceFaultInjector
    ) throws {
        guard let data = defaults.data(forKey: key) else { return }
        let existing = try PersistedRecordStore.fetchOrdered(
            ThreadReadingPositionRecord.self,
            in: context
        ).map(\.entry)
        let source: [ThreadReadingPosition]
        if existing.isEmpty {
            guard let decoded = PersistedArrayDecoder.decode(
                ThreadReadingPosition.self,
                from: data
            ) else {
                throw LegacyStorageMigration.DecodeError.invalidTopLevelArray
            }
            source = LocalThreadLibraryPolicy.sanitizedReadingPositions(decoded, limit: limit)
            legacyFallback = source
        } else {
            source = existing
        }
        let sanitized = LocalThreadLibraryPolicy.sanitizedReadingPositions(source, limit: limit)
        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: destinationIsDurable
        ) {
            try PersistedRecordStore.replaceAll(
                ThreadReadingPositionRecord.self,
                with: sanitized.enumerated().map {
                    ThreadReadingPositionRecord(entry: $0.element, sortIndex: $0.offset)
                },
                in: context
            ) {
                try faultInjector.check(.legacyMigration)
            }
        }
    }
}
