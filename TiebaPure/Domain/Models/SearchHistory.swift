import Combine
import Foundation

enum SearchHistoryPolicy {
    static let maximumStoredEntries = 20
    private static let maximumKeywordLength = 200

    static func normalizedKeyword(_ keyword: String) -> String {
        String(
            keyword
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumKeywordLength)
        )
    }

    static func adding(_ keyword: String, to items: [String], limit: Int) -> [String] {
        let effectiveLimit = min(max(limit, 0), maximumStoredEntries)
        let normalized = normalizedKeyword(keyword)
        guard normalized.isEmpty == false, effectiveLimit > 0 else {
            return Array(items.prefix(effectiveLimit))
        }
        var updated = items.filter { isSameKeyword($0, normalized) == false }
        updated.insert(normalized, at: 0)
        return Array(updated.prefix(effectiveLimit))
    }

    static func removing(_ keyword: String, from items: [String]) -> [String] {
        let normalized = normalizedKeyword(keyword)
        return items.filter { isSameKeyword($0, normalized) == false }
    }

    static func sanitized(_ items: [String], limit: Int) -> [String] {
        let effectiveLimit = min(max(limit, 0), maximumStoredEntries)
        guard effectiveLimit > 0 else { return [] }
        var result: [String] = []
        for item in items {
            let normalized = normalizedKeyword(item)
            guard normalized.isEmpty == false,
                  result.contains(where: { isSameKeyword($0, normalized) }) == false else {
                continue
            }
            result.append(normalized)
            if result.count == effectiveLimit { break }
        }
        return result
    }

    private static func isSameKeyword(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let persistence: any SearchHistoryPersistence
    private let persistentBackendIsAvailable: Bool
    private let faultInjector: PersistenceFaultInjector
    @Published private(set) var items: [String]
    @Published private(set) var persistenceAvailability: PersistenceAvailability

    init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.searchHistory",
        limit: Int = SearchHistoryPolicy.maximumStoredEntries,
        persistence: any SearchHistoryPersistence,
        faultInjector: PersistenceFaultInjector = .none
    ) {
        let configuredLimit = min(max(limit, 0), SearchHistoryPolicy.maximumStoredEntries)
        self.defaults = defaults
        self.key = key
        self.limit = configuredLimit
        self.persistence = persistence
        self.faultInjector = faultInjector
        let initialAvailability = persistence.capability.availability
        persistentBackendIsAvailable = persistence.capability.acceptsUserMutations
        self.persistenceAvailability = initialAvailability
        var legacyFallback: [String]?
        var migrationFailed = false
        do {
            try Self.migrateLegacyStorage(
                defaults: defaults,
                key: key,
                persistence: persistence,
                limit: configuredLimit,
                legacyFallback: &legacyFallback,
                faultInjector: faultInjector
            )
        } catch {
            PersistenceDiagnostics.report(error, operation: "migrate search history")
            self.persistenceAvailability = .unavailable
            migrationFailed = true
        }
        if persistence.capability.canAccessBackend {
            do {
                let result = try Self.loadAndRepairItems(
                    persistence: persistence,
                    limit: configuredLimit,
                    canRepair: persistentBackendIsAvailable,
                    faultInjector: faultInjector
                )
                items = result.value
                if let error = result.repairError {
                    PersistenceDiagnostics.report(error, operation: "repair search history")
                    self.persistenceAvailability = .unavailable
                }
            } catch {
                PersistenceDiagnostics.report(error, operation: "load search history")
                items = migrationFailed ? (legacyFallback ?? []) : []
                self.persistenceAvailability = .unavailable
            }
        } else {
            items = legacyFallback ?? []
        }
        if migrationFailed, items.isEmpty, let legacyFallback {
            items = legacyFallback
        }
    }

    @discardableResult
    func reload() -> Bool {
        guard persistence.capability.canAccessBackend else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            let result = try Self.loadAndRepairItems(
                persistence: persistence,
                limit: limit,
                canRepair: persistentBackendIsAvailable,
                faultInjector: faultInjector
            )
            items = result.value
            if let error = result.repairError {
                PersistenceDiagnostics.report(error, operation: "repair search history")
                persistenceAvailability = .unavailable
                return false
            }
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "reload search history")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    func record(_ keyword: String) -> Bool {
        persist(SearchHistoryPolicy.adding(keyword, to: items, limit: limit))
    }

    @discardableResult
    func remove(_ keyword: String) -> Bool {
        persist(SearchHistoryPolicy.removing(keyword, from: items))
    }

    @discardableResult
    func clear() -> Bool {
        let succeeded = persist([])
        if succeeded, persistence.capability.isDurable {
            defaults.removeObject(forKey: key)
        }
        return succeeded
    }

    @discardableResult
    private func persist(_ updated: [String]) -> Bool {
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try persistence.replaceAll(updated)
            items = updated
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "save search history")
            persistenceAvailability = .unavailable
            return false
        }
    }

    private func markPersistenceSucceeded() {
        guard persistentBackendIsAvailable else { return }
        persistenceAvailability = .available
    }

    private static func loadAndRepairItems(
        persistence: any SearchHistoryPersistence,
        limit: Int,
        canRepair: Bool,
        faultInjector: PersistenceFaultInjector = .none
    ) throws -> PersistenceLoadResult<[String]> {
        let raw = try persistence.load()
        let sanitized = SearchHistoryPolicy.sanitized(
            raw,
            limit: limit
        )
        if canRepair, raw != sanitized {
            do {
                try persistence.replaceAll(sanitized) {
                    try faultInjector.check(.repair)
                }
            } catch {
                return PersistenceLoadResult(value: sanitized, repairError: error)
            }
        }
        return PersistenceLoadResult(value: sanitized, repairError: nil)
    }

    // One-time import of the pre-SwiftData UserDefaults string array.
    private static func migrateLegacyStorage(
        defaults: UserDefaults,
        key: String,
        persistence: any SearchHistoryPersistence,
        limit: Int,
        legacyFallback: inout [String]?,
        faultInjector: PersistenceFaultInjector
    ) throws {
        guard defaults.object(forKey: key) != nil else { return }
        let decodedLegacy = {
            defaults.stringArray(forKey: key)
                .map { SearchHistoryPolicy.sanitized($0, limit: limit) }
        }
        guard persistence.capability.canAccessBackend else {
            legacyFallback = decodedLegacy()
            return
        }
        let existing: [String]
        do {
            existing = try persistence.load()
        } catch {
            legacyFallback = decodedLegacy()
            throw error
        }
        let source: [String]
        if existing.isEmpty {
            guard let legacy = decodedLegacy() else {
                throw LegacyStorageMigration.DecodeError.invalidTopLevelArray
            }
            source = legacy
            legacyFallback = source
        } else {
            source = existing
        }
        let sanitized = SearchHistoryPolicy.sanitized(source, limit: limit)
        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: persistence.capability.isDurable
        ) {
            try persistence.replaceAll(sanitized) {
                try faultInjector.check(.legacyMigration)
            }
        }
    }
}
