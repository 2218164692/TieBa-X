import XCTest
@testable import TieBaX

final class PersistenceBoundaryTests: XCTestCase {
    fileprivate enum ExpectedError: Error {
        case loadFailed
        case replaceFailed
        case mutationFailed
    }

    private func makeScratchDefaults(function: String = #function) throws -> UserDefaults {
        let suiteName = "\(function).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    @MainActor
    func testFallbackMigrationStagesSnapshotWithoutDeletingLegacyOrAcceptingUserWrites() throws {
        let defaults = try makeScratchDefaults()
        let key = "non-durable-search-history"
        defaults.set([" first ", "SECOND", "second"], forKey: key)
        let persistence = TestSearchHistoryPersistence(
            capability: .fallback
        )

        let store = SearchHistoryStore(
            defaults: defaults,
            key: key,
            limit: 20,
            persistence: persistence
        )

        XCTAssertEqual(store.items, ["first", "SECOND"])
        XCTAssertEqual(persistence.values, ["first", "SECOND"])
        XCTAssertEqual(persistence.replaceCallCount, 1)
        XCTAssertEqual(defaults.stringArray(forKey: key), [" first ", "SECOND", "second"])
        XCTAssertEqual(store.persistenceAvailability, .unavailable)

        XCTAssertFalse(store.clear())
        XCTAssertEqual(defaults.stringArray(forKey: key), [" first ", "SECOND", "second"])
    }

    @MainActor
    func testReplaceFailureDoesNotPublishCandidateSnapshot() throws {
        let original = RecentForum(
            name: "existing",
            displayName: "原有吧",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let persistence = TestRecentForumPersistence(values: [original])
        let store = RecentForumStore(
            defaults: try makeScratchDefaults(),
            persistence: persistence,
            now: { Date(timeIntervalSinceReferenceDate: 2) }
        )
        persistence.replaceError = ExpectedError.replaceFailed

        XCTAssertFalse(store.save(name: "candidate", displayName: "候选吧"))
        XCTAssertEqual(store.items, [original])
        XCTAssertEqual(persistence.values, [original])
        XCTAssertEqual(persistence.replaceCallCount, 1)
        XCTAssertEqual(store.persistenceAvailability, .unavailable)
    }

    @MainActor
    func testLoadFailureKeepsLegacyValueAndMarksStoreUnavailable() throws {
        let defaults = try makeScratchDefaults()
        let key = "load-failure-search-history"
        defaults.set(["legacy"], forKey: key)
        let persistence = TestSearchHistoryPersistence()
        persistence.loadError = ExpectedError.loadFailed

        let store = SearchHistoryStore(
            defaults: defaults,
            key: key,
            persistence: persistence
        )

        XCTAssertEqual(store.items, ["legacy"])
        XCTAssertEqual(defaults.stringArray(forKey: key), ["legacy"])
        XCTAssertEqual(persistence.loadCallCount, 2)
        XCTAssertEqual(persistence.replaceCallCount, 0)
        XCTAssertEqual(store.persistenceAvailability, .unavailable)
    }

    @MainActor
    func testUnavailableBackendsRejectWritesWithoutCallingPersistence() async throws {
        let browsingPersistence = TestBrowsingHistoryPersistence(capability: .unavailable)
        let recentPersistence = TestRecentForumPersistence(capability: .unavailable)
        let searchPersistence = TestSearchHistoryPersistence(capability: .unavailable)
        let browsing = BrowsingHistoryStore(
            defaults: try makeScratchDefaults(function: "browsing"),
            persistence: browsingPersistence
        )
        let recent = RecentForumStore(
            defaults: try makeScratchDefaults(function: "recent"),
            persistence: recentPersistence
        )
        let searchDefaults = try makeScratchDefaults(function: "search")
        searchDefaults.set(["legacy"], forKey: "unavailable-search")
        let search = SearchHistoryStore(
            defaults: searchDefaults,
            key: "unavailable-search",
            persistence: searchPersistence
        )

        XCTAssertFalse(browsing.record(thread: makeThread(id: 1, title: "浏览")))
        let backgroundResult = await browsing.recordInBackground(
            thread: makeThread(id: 2, title: "后台浏览")
        )
        XCTAssertFalse(backgroundResult)
        XCTAssertFalse(recent.save(name: "recent"))
        XCTAssertFalse(search.record("search"))
        XCTAssertFalse(browsing.reload())
        XCTAssertFalse(recent.reload())
        XCTAssertFalse(search.reload())
        XCTAssertEqual(search.items, ["legacy"])
        XCTAssertEqual(searchDefaults.stringArray(forKey: "unavailable-search"), ["legacy"])

        XCTAssertEqual(browsingPersistence.replaceCallCount, 0)
        XCTAssertEqual(browsingPersistence.loadCallCount, 0)
        XCTAssertTrue(browsingPersistence.operations.isEmpty)
        XCTAssertEqual(recentPersistence.replaceCallCount, 0)
        XCTAssertEqual(recentPersistence.loadCallCount, 0)
        XCTAssertEqual(searchPersistence.replaceCallCount, 0)
        XCTAssertEqual(searchPersistence.loadCallCount, 0)
        XCTAssertEqual(browsing.persistenceAvailability, .unavailable)
        XCTAssertEqual(recent.persistenceAvailability, .unavailable)
        XCTAssertEqual(search.persistenceAvailability, .unavailable)
    }

    @MainActor
    func testBrowsingHistoryMutationsRunInStrictEnqueueOrder() async throws {
        let gate = MutationGate()
        let persistence = TestBrowsingHistoryPersistence()
        persistence.nextMutationGate = gate
        var tick: TimeInterval = 0
        let store = BrowsingHistoryStore(
            defaults: try makeScratchDefaults(),
            limit: 2,
            persistence: persistence
        ) {
            tick += 1
            return Date(timeIntervalSinceReferenceDate: tick)
        }

        let first = store.enqueueRecord(thread: makeThread(id: 1, title: "第一条"))
        await gate.waitUntilEntered()
        let second = store.enqueueRecord(thread: makeThread(id: 2, title: "第二条"))
        let updated = store.enqueueRecord(thread: makeThread(id: 1, title: "更新第一条"))
        let third = store.enqueueRecord(thread: makeThread(id: 3, title: "第三条"))

        XCTAssertEqual(persistence.operations, [.upsert(1)])
        await gate.open()
        let firstResult = await first.value
        let secondResult = await second.value
        let updatedResult = await updated.value
        let thirdResult = await third.value

        XCTAssertEqual(
            [firstResult, secondResult, updatedResult, thirdResult],
            [true, true, true, true]
        )
        XCTAssertEqual(
            persistence.operations,
            [.upsert(1), .upsert(2), .upsert(1), .upsert(3)]
        )
        XCTAssertEqual(store.items.map(\.threadID), [3, 1])
        XCTAssertEqual(store.items.last?.title, "更新第一条")
    }

    @MainActor
    func testBrowsingHistoryFailedMutationDoesNotPoisonFollowingMutation() async throws {
        let gate = MutationGate()
        let persistence = TestBrowsingHistoryPersistence()
        persistence.nextMutationGate = gate
        persistence.failingMutationOrdinals = [1]
        let store = BrowsingHistoryStore(
            defaults: try makeScratchDefaults(),
            persistence: persistence
        )

        let failed = store.enqueueRecord(thread: makeThread(id: 1, title: "失败"))
        await gate.waitUntilEntered()
        let succeeding = store.enqueueRecord(thread: makeThread(id: 2, title: "成功"))
        await gate.open()
        let failedResult = await failed.value
        let succeedingResult = await succeeding.value

        XCTAssertFalse(failedResult)
        XCTAssertTrue(succeedingResult)
        XCTAssertEqual(persistence.operations, [.upsert(1), .upsert(2)])
        XCTAssertEqual(persistence.values.map(\.threadID), [2])
        XCTAssertEqual(store.items.map(\.threadID), [2])
        XCTAssertEqual(store.persistenceAvailability, .available)
    }

    @MainActor
    func testCancelledBrowsingHistoryMutationKeepsBackendAvailableAndAllowsNextMutation() async throws {
        let gate = MutationGate()
        let persistence = TestBrowsingHistoryPersistence()
        persistence.nextMutationGate = gate
        let store = BrowsingHistoryStore(
            defaults: try makeScratchDefaults(),
            persistence: persistence
        )

        let cancelled = store.enqueueRecord(thread: makeThread(id: 1, title: "取消"))
        await gate.waitUntilEntered()
        cancelled.cancel()
        await gate.open()

        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(persistence.values.isEmpty)
        XCTAssertEqual(store.persistenceAvailability, .available)

        let succeedingResult = await store.recordInBackground(
            thread: makeThread(id: 2, title: "成功")
        )
        XCTAssertTrue(succeedingResult)
        XCTAssertEqual(store.items.map(\.threadID), [2])
        XCTAssertEqual(store.persistenceAvailability, .available)
    }

    @MainActor
    func testBrowsingHistoryReloadIsRejectedWhileMutationIsPending() async throws {
        let gate = MutationGate()
        let persistence = TestBrowsingHistoryPersistence()
        persistence.nextMutationGate = gate
        let store = BrowsingHistoryStore(
            defaults: try makeScratchDefaults(),
            persistence: persistence
        )

        let mutation = store.enqueueRecord(thread: makeThread(id: 1, title: "待提交"))
        await gate.waitUntilEntered()

        XCTAssertFalse(store.reload())
        XCTAssertEqual(persistence.loadCallCount, 1)

        await gate.open()
        let mutationResult = await mutation.value
        XCTAssertTrue(mutationResult)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(persistence.loadCallCount, 2)
        XCTAssertEqual(store.items.map(\.threadID), [1])
    }

    @MainActor
    func testBrowsingHistoryBackgroundClearDeletesLegacyOnlyAfterSuccess() async throws {
        let defaults = try makeScratchDefaults()
        let key = "background-clear-history"
        let legacy = [makeHistoryEntry(id: 7, title: "旧记录", visitedAt: 7)]
        let data = try JSONEncoder().encode(legacy)
        let persistence = TestBrowsingHistoryPersistence(values: legacy)
        let store = BrowsingHistoryStore(
            defaults: defaults,
            key: key,
            persistence: persistence
        )
        // Simulate a still-present legacy value after initialization so this
        // test isolates clear's commit ordering from startup migration.
        defaults.set(data, forKey: key)
        persistence.failingMutationOrdinals = [1]

        let failedResult = await store.clearInBackground()
        XCTAssertFalse(failedResult)
        XCTAssertEqual(store.items.map(\.threadID), [7])
        XCTAssertEqual(persistence.values.map(\.threadID), [7])
        XCTAssertEqual(defaults.data(forKey: key), data)

        let successfulResult = await store.clearInBackground()
        XCTAssertTrue(successfulResult)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(persistence.values.isEmpty)
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(persistence.operations, [.removeAll, .removeAll])
    }

    private func makeThread(id: Int64, title: String) -> ThreadSummary {
        ThreadSummary(
            id: id,
            title: title,
            author: UserSummary(
                id: 1,
                name: "author",
                displayName: "作者",
                portrait: ""
            ),
            replyCount: 0,
            viewCount: 0,
            blocks: []
        )
    }

    private func makeHistoryEntry(
        id: Int64,
        title: String,
        visitedAt: TimeInterval
    ) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(
            threadID: id,
            title: title,
            authorDisplayName: "作者",
            visitedAt: Date(timeIntervalSinceReferenceDate: visitedAt)
        )
    }
}

private actor MutationGate {
    private var didEnter = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard didEnter == false else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class TestBrowsingHistoryPersistence: BrowsingHistoryPersistence {
    enum Operation: Equatable {
        case upsert(Int64)
        case remove(Set<Int64>)
        case removeAll
    }

    let capability: PersistenceCapability
    var values: [BrowsingHistoryEntry]
    var loadError: Error?
    var replaceError: Error?
    var nextMutationGate: MutationGate?
    var failingMutationOrdinals = Set<Int>()
    private(set) var loadCallCount = 0
    private(set) var replaceCallCount = 0
    private(set) var operations: [Operation] = []
    private var mutationOrdinal = 0

    init(
        values: [BrowsingHistoryEntry] = [],
        capability: PersistenceCapability = .durable
    ) {
        self.values = values
        self.capability = capability
    }

    func load() throws -> [BrowsingHistoryEntry] {
        loadCallCount += 1
        if let loadError { throw loadError }
        return values
    }

    func replaceAll(
        _ entries: [BrowsingHistoryEntry],
        beforeCommit: () throws -> Void
    ) throws {
        replaceCallCount += 1
        try beforeCommit()
        if let replaceError { throw replaceError }
        values = entries
    }

    func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) async throws -> [BrowsingHistoryEntry] {
        try await beginMutation(.upsert(entry.threadID))
        values = BrowsingHistoryPolicy.adding(entry, to: values, limit: limit)
        return values
    }

    func remove(threadIDs: Set<Int64>) async throws -> [BrowsingHistoryEntry] {
        try await beginMutation(.remove(threadIDs))
        values = BrowsingHistoryPolicy.removing(threadIDs: threadIDs, from: values)
        return values
    }

    func removeAll() async throws -> [BrowsingHistoryEntry] {
        try await beginMutation(.removeAll)
        values = []
        return values
    }

    private func beginMutation(_ operation: Operation) async throws {
        mutationOrdinal += 1
        let currentOrdinal = mutationOrdinal
        operations.append(operation)
        if let gate = nextMutationGate {
            nextMutationGate = nil
            await gate.suspend()
        }
        try Task.checkCancellation()
        if failingMutationOrdinals.contains(currentOrdinal) {
            throw PersistenceBoundaryTests.ExpectedError.mutationFailed
        }
    }
}

@MainActor
private final class TestRecentForumPersistence: RecentForumPersistence {
    let capability: PersistenceCapability
    var values: [RecentForum]
    var loadError: Error?
    var replaceError: Error?
    private(set) var loadCallCount = 0
    private(set) var replaceCallCount = 0

    init(
        values: [RecentForum] = [],
        capability: PersistenceCapability = .durable
    ) {
        self.values = values
        self.capability = capability
    }

    func load() throws -> [RecentForum] {
        loadCallCount += 1
        if let loadError { throw loadError }
        return values
    }

    func replaceAll(
        _ entries: [RecentForum],
        beforeCommit: () throws -> Void
    ) throws {
        replaceCallCount += 1
        try beforeCommit()
        if let replaceError { throw replaceError }
        values = entries
    }
}

@MainActor
private final class TestSearchHistoryPersistence: SearchHistoryPersistence {
    let capability: PersistenceCapability
    var values: [String]
    var loadError: Error?
    var replaceError: Error?
    private(set) var loadCallCount = 0
    private(set) var replaceCallCount = 0

    init(
        values: [String] = [],
        capability: PersistenceCapability = .durable
    ) {
        self.values = values
        self.capability = capability
    }

    func load() throws -> [String] {
        loadCallCount += 1
        if let loadError { throw loadError }
        return values
    }

    func replaceAll(
        _ entries: [String],
        beforeCommit: () throws -> Void
    ) throws {
        replaceCallCount += 1
        try beforeCommit()
        if let replaceError { throw replaceError }
        values = entries
    }
}
