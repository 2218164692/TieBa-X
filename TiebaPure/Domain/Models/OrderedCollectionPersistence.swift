import Foundation

enum PersistenceCapability: Equatable, Sendable {
    case unavailable
    case fallback
    case durable

    var availability: PersistenceAvailability {
        self == .durable ? .available : .unavailable
    }

    var canAccessBackend: Bool {
        self != .unavailable
    }

    var acceptsUserMutations: Bool {
        self == .durable
    }

    var isDurable: Bool {
        self == .durable
    }
}

@MainActor
protocol BrowsingHistoryPersistence: AnyObject {
    var capability: PersistenceCapability { get }

    func load() throws -> [BrowsingHistoryEntry]
    func replaceAll(
        _ entries: [BrowsingHistoryEntry],
        beforeCommit: () throws -> Void
    ) throws
    func upsert(_ entry: BrowsingHistoryEntry, limit: Int) async throws -> [BrowsingHistoryEntry]
    func remove(threadIDs: Set<Int64>) async throws -> [BrowsingHistoryEntry]
    func removeAll() async throws -> [BrowsingHistoryEntry]
}

extension BrowsingHistoryPersistence {
    func replaceAll(_ entries: [BrowsingHistoryEntry]) throws {
        try replaceAll(entries, beforeCommit: {})
    }
}

@MainActor
protocol RecentForumPersistence: AnyObject {
    var capability: PersistenceCapability { get }

    func load() throws -> [RecentForum]
    func replaceAll(
        _ entries: [RecentForum],
        beforeCommit: () throws -> Void
    ) throws
}

extension RecentForumPersistence {
    func replaceAll(_ entries: [RecentForum]) throws {
        try replaceAll(entries, beforeCommit: {})
    }
}

@MainActor
protocol SearchHistoryPersistence: AnyObject {
    var capability: PersistenceCapability { get }

    func load() throws -> [String]
    func replaceAll(
        _ entries: [String],
        beforeCommit: () throws -> Void
    ) throws
}

extension SearchHistoryPersistence {
    func replaceAll(_ entries: [String]) throws {
        try replaceAll(entries, beforeCommit: {})
    }
}
