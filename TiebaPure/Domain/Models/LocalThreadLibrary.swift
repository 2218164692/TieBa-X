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

struct ThreadFavoriteEntry: Codable, Equatable, Identifiable, Sendable {
    var threadID: Int64
    var forumID: Int64?
    var title: String
    var authorDisplayName: String
    var forumDisplayName: String?
    var savedAt: Date

    var id: Int64 { threadID }

    init(
        threadID: Int64,
        forumID: Int64? = nil,
        title: String,
        authorDisplayName: String,
        forumDisplayName: String? = nil,
        savedAt: Date
    ) {
        self.threadID = threadID
        self.forumID = forumID
        self.title = title
        self.authorDisplayName = authorDisplayName
        self.forumDisplayName = forumDisplayName
        self.savedAt = savedAt
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
    static let maximumFavoriteEntries = 500
    static let maximumReadingPositions = 500

    static func favorite(
        for thread: ThreadSummary,
        forum: Forum?,
        fallbackForumID: Int64?,
        savedAt: Date
    ) -> ThreadFavoriteEntry? {
        guard let reference = BrowsingHistoryPolicy.entry(
            for: thread,
            forum: forum,
            fallbackForumID: fallbackForumID,
            visitedAt: savedAt
        ) else { return nil }

        return ThreadFavoriteEntry(
            threadID: reference.threadID,
            forumID: reference.forumID,
            title: reference.title,
            authorDisplayName: reference.authorDisplayName,
            forumDisplayName: reference.forumDisplayName,
            savedAt: savedAt
        )
    }

    static func addingFavorite(
        _ favorite: ThreadFavoriteEntry,
        to favorites: [ThreadFavoriteEntry],
        limit: Int
    ) -> [ThreadFavoriteEntry] {
        let effectiveLimit = min(max(limit, 0), maximumFavoriteEntries)
        guard effectiveLimit > 0 else { return [] }
        var updated = favorites.filter { $0.threadID != favorite.threadID }
        updated.insert(favorite, at: 0)
        return Array(updated.prefix(effectiveLimit))
    }

    static func removingFavorites(
        threadIDs: Set<Int64>,
        from favorites: [ThreadFavoriteEntry]
    ) -> [ThreadFavoriteEntry] {
        favorites.filter { threadIDs.contains($0.threadID) == false }
    }

    static func sanitizedFavorites(
        _ favorites: [ThreadFavoriteEntry],
        limit: Int
    ) -> [ThreadFavoriteEntry] {
        let effectiveLimit = min(max(limit, 0), maximumFavoriteEntries)
        guard effectiveLimit > 0 else { return [] }
        var seenThreadIDs = Set<Int64>()
        var result: [ThreadFavoriteEntry] = []

        let ordered = favorites.sorted {
            if $0.savedAt != $1.savedAt {
                return $0.savedAt > $1.savedAt
            }
            return $0.threadID > $1.threadID
        }
        for favorite in ordered where
            favorite.threadID > 0 &&
            favorite.savedAt.timeIntervalSinceReferenceDate.isFinite
        {
            guard seenThreadIDs.insert(favorite.threadID).inserted else { continue }
            let title = normalized(favorite.title, maximumLength: 200)
            let author = normalized(favorite.authorDisplayName, maximumLength: 80)
            let forum = favorite.forumDisplayName.map { normalized($0, maximumLength: 80) }
            result.append(ThreadFavoriteEntry(
                threadID: favorite.threadID,
                forumID: favorite.forumID.flatMap { $0 > 0 ? $0 : nil },
                title: title.isEmpty ? "帖子 \(favorite.threadID)" : title,
                authorDisplayName: author.isEmpty ? "未知用户" : author,
                forumDisplayName: forum?.isEmpty == false ? forum : nil,
                savedAt: favorite.savedAt
            ))
            if result.count == effectiveLimit { break }
        }

        return result
    }

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
    private let favoriteLimit: Int
    private let readingPositionLimit: Int
    private let now: () -> Date
    private let modelContext: ModelContext
    private let persistentBackendIsAvailable: Bool
    private let faultInjector: PersistenceFaultInjector

    @Published private(set) var favorites: [ThreadFavoriteEntry]
    @Published private(set) var readingPositions: [ThreadReadingPosition]
    @Published private(set) var persistenceAvailability: PersistenceAvailability

    init(
        defaults: UserDefaults = .standard,
        favoritesKey: String = "dev.infinityf4p.tiebapure.threadFavorites",
        readingPositionsKey: String = "dev.infinityf4p.tiebapure.threadReadingPositions",
        favoriteLimit: Int = LocalThreadLibraryPolicy.maximumFavoriteEntries,
        readingPositionLimit: Int = LocalThreadLibraryPolicy.maximumReadingPositions,
        modelContainer: ModelContainer = AppModelContainer.shared,
        persistenceAvailability: PersistenceAvailability? = nil,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.favoritesKey = favoritesKey
        self.readingPositionsKey = readingPositionsKey
        self.favoriteLimit = min(
            max(favoriteLimit, 0),
            LocalThreadLibraryPolicy.maximumFavoriteEntries
        )
        self.readingPositionLimit = min(
            max(readingPositionLimit, 0),
            LocalThreadLibraryPolicy.maximumReadingPositions
        )
        self.now = now
        self.faultInjector = faultInjector
        let context = modelContainer.mainContext
        modelContext = context
        let initialAvailability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        persistentBackendIsAvailable = initialAvailability.canPersist
        self.persistenceAvailability = initialAvailability
        let destinationIsDurable = initialAvailability.canPersist
            && AppModelContainer.allowsLegacyCleanup(for: modelContainer)
        var legacyFavoritesFallback: [ThreadFavoriteEntry]?
        var legacyFavoritesMigrationFailed = false
        do {
            try Self.migrateLegacyFavorites(
                defaults: defaults,
                key: favoritesKey,
                context: context,
                limit: self.favoriteLimit,
                destinationIsDurable: destinationIsDurable,
                legacyFallback: &legacyFavoritesFallback,
                faultInjector: faultInjector
            )
        } catch {
            PersistenceDiagnostics.report(error, operation: "migrate thread favorites")
            self.persistenceAvailability = .unavailable
            legacyFavoritesMigrationFailed = true
        }
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
        var loadedFavorites: [ThreadFavoriteEntry]
        do {
            let result = try Self.loadAndRepairFavorites(
                context: context,
                limit: self.favoriteLimit,
                canRepair: persistentBackendIsAvailable,
                faultInjector: faultInjector
            )
            loadedFavorites = result.value
            if let error = result.repairError {
                PersistenceDiagnostics.report(error, operation: "repair thread favorites")
                self.persistenceAvailability = .unavailable
            }
        } catch {
            PersistenceDiagnostics.report(error, operation: "load thread favorites")
            loadedFavorites = legacyFavoritesMigrationFailed ? (legacyFavoritesFallback ?? []) : []
            self.persistenceAvailability = .unavailable
        }
        if legacyFavoritesMigrationFailed, loadedFavorites.isEmpty,
           let legacyFavoritesFallback {
            loadedFavorites = legacyFavoritesFallback
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
        favorites = loadedFavorites
        readingPositions = loadedReadingPositions
    }

    @discardableResult
    func reload() -> Bool {
        var succeeded = true
        do {
            let result = try Self.loadAndRepairFavorites(
                context: modelContext,
                limit: favoriteLimit,
                canRepair: persistentBackendIsAvailable,
                faultInjector: faultInjector
            )
            favorites = result.value
            if let error = result.repairError {
                PersistenceDiagnostics.report(error, operation: "repair thread favorites")
                succeeded = false
            }
        } catch {
            PersistenceDiagnostics.report(error, operation: "reload thread favorites")
            succeeded = false
        }
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

    func isFavorite(threadID: Int64) -> Bool {
        favorites.contains { $0.threadID == threadID }
    }

    @discardableResult
    func toggleFavorite(
        thread: ThreadSummary,
        forum: Forum? = nil,
        fallbackForumID: Int64? = nil
    ) -> Bool {
        if isFavorite(threadID: thread.id) {
            _ = removeFavorites(threadIDs: [thread.id])
            return isFavorite(threadID: thread.id)
        }
        _ = addFavorite(thread: thread, forum: forum, fallbackForumID: fallbackForumID)
        return isFavorite(threadID: thread.id)
    }

    @discardableResult
    func addFavorite(
        thread: ThreadSummary,
        forum: Forum? = nil,
        fallbackForumID: Int64? = nil
    ) -> Bool {
        guard let favorite = LocalThreadLibraryPolicy.favorite(
            for: thread,
            forum: forum,
            fallbackForumID: fallbackForumID,
            savedAt: now()
        ) else { return false }
        return persistFavorites(LocalThreadLibraryPolicy.addingFavorite(
            favorite,
            to: favorites,
            limit: favoriteLimit
        ))
    }

    @discardableResult
    func refreshFavoriteMetadata(
        thread: ThreadSummary,
        forum: Forum? = nil,
        fallbackForumID: Int64? = nil
    ) -> Bool {
        guard let index = favorites.firstIndex(where: { $0.threadID == thread.id }),
              let refreshed = LocalThreadLibraryPolicy.favorite(
                for: thread,
                forum: forum,
                fallbackForumID: fallbackForumID,
                  savedAt: favorites[index].savedAt
              ),
              refreshed != favorites[index] else { return true }
        var updated = favorites
        updated[index] = refreshed
        return persistFavorites(updated)
    }

    @discardableResult
    func removeFavorites(threadIDs: Set<Int64>) -> Bool {
        guard threadIDs.isEmpty == false else { return true }
        return persistFavorites(LocalThreadLibraryPolicy.removingFavorites(
            threadIDs: threadIDs,
            from: favorites
        ))
    }

    @discardableResult
    func clearFavorites() -> Bool {
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try PersistedRecordStore.replaceAll(
                ThreadFavoriteRecord.self,
                with: [],
                in: modelContext
            )
            defaults.removeObject(forKey: favoritesKey)
            favorites = []
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear thread favorites")
            persistenceAvailability = .unavailable
            return false
        }
    }

    func position(for threadID: Int64) -> ThreadReadingPosition? {
        readingPositions.first { $0.threadID == threadID }
    }

    @discardableResult
    func recordReadingPosition(threadID: Int64, postID: UInt64, floor: Int) -> Bool {
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
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try PersistedRecordStore.clearThreadLibrary(in: modelContext) {
                try faultInjector.check(.clearAll)
            }
            defaults.removeObject(forKey: favoritesKey)
            defaults.removeObject(forKey: readingPositionsKey)
            favorites = []
            readingPositions = []
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear local thread library")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    private func persistFavorites(_ updated: [ThreadFavoriteEntry]) -> Bool {
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        guard updated.isEmpty == false else {
            return clearFavorites()
        }
        do {
            try PersistedRecordStore.replaceAll(
                ThreadFavoriteRecord.self,
                with: updated.enumerated().map {
                    ThreadFavoriteRecord(entry: $0.element, sortIndex: $0.offset)
                },
                in: modelContext
            )
            favorites = updated
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "save thread favorites")
            persistenceAvailability = .unavailable
            return false
        }
    }

    private func markPersistenceSucceeded() {
        guard persistentBackendIsAvailable else { return }
        persistenceAvailability = .available
    }

    private static func loadAndRepairFavorites(
        context: ModelContext,
        limit: Int,
        canRepair: Bool,
        faultInjector: PersistenceFaultInjector = .none
    ) throws -> PersistenceLoadResult<[ThreadFavoriteEntry]> {
        let raw = try PersistedRecordStore.fetchOrdered(
            ThreadFavoriteRecord.self,
            in: context
        ).map(\.entry)
        let sanitized = LocalThreadLibraryPolicy.sanitizedFavorites(
            raw,
            limit: limit
        )
        if canRepair, raw != sanitized {
            do {
                try PersistedRecordStore.replaceAll(
                    ThreadFavoriteRecord.self,
                    with: sanitized.enumerated().map {
                        ThreadFavoriteRecord(entry: $0.element, sortIndex: $0.offset)
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

    // One-time import of the pre-SwiftData UserDefaults JSON blobs.
    private static func migrateLegacyFavorites(
        defaults: UserDefaults,
        key: String,
        context: ModelContext,
        limit: Int,
        destinationIsDurable: Bool,
        legacyFallback: inout [ThreadFavoriteEntry]?,
        faultInjector: PersistenceFaultInjector
    ) throws {
        guard let data = defaults.data(forKey: key) else { return }
        let existing = try PersistedRecordStore.fetchOrdered(
            ThreadFavoriteRecord.self,
            in: context
        ).map(\.entry)
        let source: [ThreadFavoriteEntry]
        if existing.isEmpty {
            guard let decoded = PersistedArrayDecoder.decode(ThreadFavoriteEntry.self, from: data) else {
                throw LegacyStorageMigration.DecodeError.invalidTopLevelArray
            }
            source = LocalThreadLibraryPolicy.sanitizedFavorites(decoded, limit: limit)
            legacyFallback = source
        } else {
            source = existing
        }
        let sanitized = LocalThreadLibraryPolicy.sanitizedFavorites(source, limit: limit)
        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: destinationIsDurable
        ) {
            try PersistedRecordStore.replaceAll(
                ThreadFavoriteRecord.self,
                with: sanitized.enumerated().map {
                    ThreadFavoriteRecord(entry: $0.element, sortIndex: $0.offset)
                },
                in: context
            ) {
                try faultInjector.check(.legacyMigration)
            }
        }
    }

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
