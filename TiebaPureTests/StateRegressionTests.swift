import Combine
import SwiftData
import XCTest
@testable import TiebaPure

@available(iOS 17.0, *)
final class StateRegressionTests: XCTestCase {
    private enum ExpectedPersistenceError: Error {
        case writeFailed
        case persistentContainerUnavailable
    }

    private func makeInMemoryModelContainer() throws -> ModelContainer {
        let schema = Schema(AppModelContainer.models)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
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
    func testLegacyMigrationKeepsDefaultsWhenPersistenceFailsOrIsNotDurable() throws {
        let defaults = try makeScratchDefaults()
        let key = "legacy"
        let legacyData = Data("legacy-value".utf8)

        defaults.set(legacyData, forKey: key)
        XCTAssertThrowsError(
            try LegacyStorageMigration.persistThenRemoveLegacyValue(
                defaults: defaults,
                key: key,
                destinationIsDurable: true
            ) {
                throw ExpectedPersistenceError.writeFailed
            }
        )
        XCTAssertEqual(defaults.data(forKey: key), legacyData)

        var didPersistIntoFallback = false
        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: false
        ) {
            didPersistIntoFallback = true
        }
        XCTAssertTrue(didPersistIntoFallback)
        XCTAssertEqual(defaults.data(forKey: key), legacyData)

        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: true
        ) {}
        XCTAssertNil(defaults.object(forKey: key))
    }

    @MainActor
    func testFailedPersistentContainerResolutionDisablesLegacyCleanup() throws {
        let fallback = try makeInMemoryModelContainer()
        let resolution = try AppModelContainer.resolve(
            persistent: {
                throw ExpectedPersistenceError.persistentContainerUnavailable
            },
            fallback: {
                fallback
            }
        )

        XCTAssertFalse(resolution.isDurable)
        XCTAssertEqual(resolution.availability, .unavailable)
        XCTAssertTrue(resolution.container === fallback)
        XCTAssertEqual(
            AppModelContainer.persistenceAvailability(
                for: fallback,
                resolvedSharedContainer: resolution
            ),
            .unavailable
        )
        XCTAssertFalse(AppModelContainer.allowsLegacyCleanup(
            for: fallback,
            resolvedSharedContainer: resolution
        ))
    }

    @MainActor
    func testAppAppearancePersistsOverridesAndSanitizesInvalidValues() throws {
        let suiteName = "AppAppearanceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let key = "appearance"

        let store = AppAppearanceStore(defaults: defaults, key: key)
        XCTAssertEqual(store.selection, .system)
        XCTAssertNil(store.selection.preferredColorScheme)
        XCTAssertNil(defaults.object(forKey: key))

        store.select(.dark)
        XCTAssertEqual(store.selection, .dark)
        XCTAssertEqual(store.selection.preferredColorScheme, .dark)
        XCTAssertEqual(defaults.string(forKey: key), AppAppearance.dark.rawValue)

        let reloaded = AppAppearanceStore(defaults: defaults, key: key)
        XCTAssertEqual(reloaded.selection, .dark)

        reloaded.select(.light)
        XCTAssertEqual(reloaded.selection, .light)
        XCTAssertEqual(reloaded.selection.preferredColorScheme, .light)
        XCTAssertEqual(defaults.string(forKey: key), AppAppearance.light.rawValue)

        reloaded.select(.system)
        XCTAssertEqual(reloaded.selection, .system)
        XCTAssertNil(reloaded.selection.preferredColorScheme)
        XCTAssertNil(defaults.object(forKey: key))

        defaults.set("invalid-appearance", forKey: key)
        let sanitized = AppAppearanceStore(defaults: defaults, key: key)
        XCTAssertEqual(sanitized.selection, .system)
        XCTAssertNil(defaults.object(forKey: key))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testForumThreadSortPreferencePersistsPerForumAndRepairsInvalidValues() throws {
        let defaults = try makeScratchDefaults()
        let key = "forum-thread-sort"
        let firstForum = Forum(
            id: 101,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        let secondForum = Forum(
            id: 102,
            name: "无障碍",
            displayName: "无障碍吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        let nameOnlyForum = Forum(
            id: 0,
            name: "  测试吧 ",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        let normalizedNameOnlyForum = Forum(
            id: 0,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )

        let store = ForumThreadSortPreferenceStore(defaults: defaults, key: key)
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertEqual(store.selection(for: secondForum), .replyTime)

        store.select(.publishTime, for: firstForum)
        XCTAssertEqual(store.selection(for: firstForum), .publishTime)
        XCTAssertEqual(store.selection(for: secondForum), .replyTime)
        XCTAssertEqual(
            store.selection(for: nameOnlyForum),
            .publishTime,
            "应用内和 Universal Link 进入同一贴吧时应共享排序偏好"
        )
        XCTAssertEqual(store.selection(for: normalizedNameOnlyForum), .publishTime)
        XCTAssertEqual(
            ForumThreadSortPreferenceStore(defaults: defaults, key: key)
                .selection(for: firstForum),
            .publishTime
        )

        store.select(.featured, for: firstForum)
        XCTAssertEqual(
            store.selection(for: firstForum),
            .publishTime,
            "精华是页签而非最新排序偏好，不应覆盖此前选择"
        )

        store.select(.publishTime, for: nameOnlyForum)
        XCTAssertEqual(store.selection(for: normalizedNameOnlyForum), .publishTime)

        let firstKey = ForumThreadSortPreferenceStore.preferenceKey(for: firstForum)
        let secondKey = ForumThreadSortPreferenceStore.preferenceKey(for: secondForum)
        defaults.set(
            [
                firstKey: ForumThreadCategory.featured.rawValue,
                secondKey: ForumThreadCategory.publishTime.rawValue
            ],
            forKey: key
        )
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertEqual(store.selection(for: secondForum), .publishTime)
        XCTAssertNil(defaults.dictionary(forKey: key)?[firstKey])
        XCTAssertEqual(
            defaults.dictionary(forKey: key)?[secondKey] as? String,
            ForumThreadCategory.publishTime.rawValue
        )

        defaults.set("corrupt", forKey: key)
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertNil(defaults.object(forKey: key))

        store.select(.publishTime, for: firstForum)
        store.select(.replyTime, for: firstForum)
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertNil(defaults.object(forKey: key))

        store.select(.publishTime, for: secondForum)
        store.reset()
        XCTAssertEqual(store.selection(for: secondForum), .replyTime)
    }

    func testSearchRoutePreservesMatchedPostID() {
        let route = SearchThreadRoute(threadID: 10, forumID: 20, postID: 30)
        XCTAssertEqual(route.postID, 30)
    }

    func testSearchRequestKeyIncludesEveryResultCondition() {
        let base = SearchRequestKey(accountID: "A", keyword: "词", forumName: "吧", filterType: 2, sortType: 5, page: 1)
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "B", keyword: "词", forumName: "吧", filterType: 2, sortType: 5, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "新词", forumName: "吧", filterType: 2, sortType: 5, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "词", forumName: "吧", filterType: 1, sortType: 5, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "词", forumName: "吧", filterType: 2, sortType: 0, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "词", forumName: "吧", filterType: 2, sortType: 5, page: 2))
    }

    @MainActor
    func testRecentForumStorePublishesDeduplicatesAndLimitsItems() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = RecentForumStore(defaults: defaults, limit: 30, modelContainer: container) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
        var observations: [[RecentForum]] = []
        let cancellable = store.$items.dropFirst().sink { observations.append($0) }

        for index in 0..<35 {
            store.save(name: "forum\(index)")
        }
        store.save(name: "forum10", displayName: "更新后的十号吧")

        XCTAssertEqual(store.items.count, 30)
        XCTAssertEqual(store.items.first?.name, "forum10")
        XCTAssertEqual(store.items.first?.displayName, "更新后的十号吧")
        XCTAssertEqual(store.items.filter { $0.name == "forum10" }.count, 1)
        XCTAssertFalse(observations.isEmpty)
        withExtendedLifetime(cancellable) {}

        let reloaded = RecentForumStore(defaults: defaults, limit: 30, modelContainer: container)
        XCTAssertEqual(reloaded.items, store.items)

        XCTAssertTrue(store.clear())
        XCTAssertTrue(store.items.isEmpty)
        let cleared = RecentForumStore(defaults: defaults, limit: 30, modelContainer: container)
        XCTAssertTrue(cleared.items.isEmpty)
    }

    @MainActor
    func testRecentForumStoreRemovesSelectedEntriesDurably() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = RecentForumStore(defaults: defaults, limit: 30, modelContainer: container) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
        store.save(name: "Alpha")
        store.save(name: "beta")
        store.save(name: "gamma")

        // Identifiers are case-insensitive, matching `RecentForum.id`.
        XCTAssertTrue(store.remove(ids: ["ALPHA"]))
        XCTAssertEqual(store.items.map(\.name), ["gamma", "beta"])
        XCTAssertTrue(store.remove(ids: ["missing"]), "删除不存在的条目不应视为失败")
        XCTAssertEqual(store.items.count, 2)

        let reloaded = RecentForumStore(defaults: defaults, limit: 30, modelContainer: container)
        XCTAssertEqual(reloaded.items.map(\.name), ["gamma", "beta"])

        XCTAssertTrue(store.remove(ids: ["gamma", "beta"]))
        XCTAssertTrue(store.items.isEmpty)
        let emptied = RecentForumStore(defaults: defaults, limit: 30, modelContainer: container)
        XCTAssertTrue(emptied.items.isEmpty)
    }

    @MainActor
    func testSearchHistoryPersistsDeduplicatesLimitsAndDeletes() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let store = SearchHistoryStore(
            defaults: defaults,
            key: "search-history",
            limit: 3,
            modelContainer: container
        )

        store.record("  第一条  ")
        store.record("Second")
        store.record("second")
        store.record("第三条")
        store.record("第四条")

        XCTAssertEqual(store.items, ["第四条", "第三条", "second"])

        let reloaded = SearchHistoryStore(
            defaults: defaults,
            key: "search-history",
            limit: 3,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.items, store.items)

        reloaded.remove("SECOND")
        XCTAssertEqual(reloaded.items, ["第四条", "第三条"])
        reloaded.clear()
        XCTAssertTrue(reloaded.items.isEmpty)

        let cleared = SearchHistoryStore(
            defaults: defaults,
            key: "search-history",
            limit: 3,
            modelContainer: container
        )
        XCTAssertTrue(cleared.items.isEmpty)
    }

    @MainActor
    func testBrowsingHistoryPersistsDeduplicatesLimitsAndDeletes() throws {
        XCTAssertEqual(BrowsingHistoryPolicy.maximumStoredEntries, 500)
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = BrowsingHistoryStore(
            defaults: defaults,
            key: "browsing-history",
            limit: 2,
            modelContainer: container
        ) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
        let author = UserSummary(
            id: 1,
            name: "author",
            displayName: "历史作者",
            portrait: ""
        )
        let forum = Forum(
            id: 101,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        func thread(id: Int64, title: String, forumID: Int64? = nil) -> ThreadSummary {
            ThreadSummary(
                id: id,
                forumID: forumID,
                title: title,
                author: author,
                forumName: forum.name,
                replyCount: 0,
                viewCount: 0,
                blocks: []
            )
        }

        store.record(thread: thread(id: 1, title: "第一条"), forum: forum)
        store.record(thread: thread(id: 2, title: "第二条"), forum: forum)
        store.record(thread: thread(id: 1, title: "更新后的第一条"), forum: forum)
        store.record(
            thread: thread(id: 3, title: "第三条"),
            fallbackForumID: 303
        )
        store.record(thread: thread(id: 0, title: "无效帖子"), forum: forum)

        XCTAssertEqual(store.items.map(\.threadID), [3, 1])
        XCTAssertEqual(store.items.last?.title, "更新后的第一条")
        XCTAssertEqual(store.items.first?.forumID, 303)
        XCTAssertEqual(store.items.last?.forumDisplayName, "测试吧")
        XCTAssertEqual(store.items.first?.visitedAt, Date(timeIntervalSince1970: 4))

        let reloaded = BrowsingHistoryStore(
            defaults: defaults,
            key: "browsing-history",
            limit: 2,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.items, store.items)

        reloaded.remove(threadIDs: [3])
        XCTAssertEqual(reloaded.items.map(\.threadID), [1])
        reloaded.clear()
        XCTAssertTrue(reloaded.items.isEmpty)

        let cleared = BrowsingHistoryStore(
            defaults: defaults,
            key: "browsing-history",
            limit: 2,
            modelContainer: container
        )
        XCTAssertTrue(cleared.items.isEmpty)
    }

    @MainActor
    func testBrowsingHistoryBackgroundMutationsSerializeUpsertPruneAndDelete() async throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = BrowsingHistoryStore(
            defaults: defaults,
            key: "background-browsing-history",
            limit: 2,
            modelContainer: container
        ) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
        let author = UserSummary(
            id: 1,
            name: "author",
            displayName: "作者",
            portrait: ""
        )
        func thread(id: Int64, title: String) -> ThreadSummary {
            ThreadSummary(
                id: id,
                title: title,
                author: author,
                replyCount: 0,
                viewCount: 0,
                blocks: []
            )
        }

        let first = store.enqueueRecord(thread: thread(id: 1, title: "第一条"))
        XCTAssertFalse(
            store.reload(),
            "后台上下文写入期间，主上下文不能并发读取并修复同一批记录"
        )
        let second = store.enqueueRecord(thread: thread(id: 2, title: "第二条"))
        let updated = store.enqueueRecord(thread: thread(id: 1, title: "更新第一条"))
        let third = store.enqueueRecord(thread: thread(id: 3, title: "第三条"))

        let firstResult = await first.value
        let secondResult = await second.value
        let updatedResult = await updated.value
        let thirdResult = await third.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertTrue(updatedResult)
        XCTAssertTrue(thirdResult)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.items.map(\.threadID), [3, 1])
        XCTAssertEqual(store.items.last?.title, "更新第一条")

        let removalResult = await store.removeInBackground(threadIDs: [3])
        XCTAssertTrue(removalResult)
        XCTAssertEqual(store.items.map(\.threadID), [1])
        let clearResult = await store.clearInBackground()
        XCTAssertTrue(clearResult)
        XCTAssertTrue(store.items.isEmpty)

        let reloaded = BrowsingHistoryStore(
            defaults: defaults,
            key: "background-browsing-history",
            limit: 2,
            modelContainer: container
        )
        XCTAssertTrue(reloaded.items.isEmpty)
    }

    @MainActor
    func testLocalThreadLibraryPersistsReadingPositions() throws {
        XCTAssertEqual(LocalThreadLibraryPolicy.maximumReadingPositions, 500)
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            readingPositionLimit: 2,
            modelContainer: container
        ) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }

        store.recordReadingPosition(threadID: 1, postID: 1001, floor: 1)
        store.recordReadingPosition(threadID: 1, postID: 1002, floor: 2)
        store.recordReadingPosition(threadID: 2, postID: 2003, floor: 3)
        store.recordReadingPosition(threadID: 1, postID: 1004, floor: 4)
        store.recordReadingPosition(threadID: 3, postID: 3005, floor: 5)

        XCTAssertEqual(store.readingPositions.map(\.threadID), [3, 1])
        XCTAssertEqual(store.position(for: 1)?.postID, 1004)
        XCTAssertEqual(store.position(for: 1)?.floor, 4)
        XCTAssertNil(store.position(for: 2))

        let reloaded = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            readingPositionLimit: 2,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.readingPositions, store.readingPositions)

        reloaded.clearReadingPosition(threadID: 1)
        XCTAssertNil(reloaded.position(for: 1))
        reloaded.clearReadingPositions()
        XCTAssertTrue(reloaded.readingPositions.isEmpty)

        reloaded.recordReadingPosition(threadID: 1, postID: 1006, floor: 6)
        reloaded.clearAll()
        XCTAssertTrue(reloaded.readingPositions.isEmpty)

        let cleared = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            readingPositionLimit: 2,
            modelContainer: container
        )
        XCTAssertTrue(cleared.readingPositions.isEmpty)
    }

    @MainActor
    func testReadingPositionBackgroundQueuePreservesMutationOrder() async throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "background-favorites",
            readingPositionsKey: "background-positions",
            readingPositionLimit: 4,
            modelContainer: container
        ) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }

        let firstPosition = store.enqueueReadingPosition(
            threadID: 1,
            postID: 1_001,
            floor: 1
        )
        let newerPosition = store.enqueueReadingPosition(
            threadID: 1,
            postID: 1_002,
            floor: 2
        )
        let firstPositionSucceeded = await firstPosition.value
        let newerPositionSucceeded = await newerPosition.value
        XCTAssertTrue(firstPositionSucceeded)
        XCTAssertTrue(newerPositionSucceeded)
        XCTAssertEqual(store.position(for: 1)?.postID, 1_002)

        let pendingInsert = store.enqueueReadingPosition(
            threadID: 2,
            postID: 2_001,
            floor: 3
        )
        let deleteAfterPendingInsert = store.enqueueClearReadingPosition(threadID: 2)
        let pendingInsertSucceeded = await pendingInsert.value
        let deleteAfterPendingInsertSucceeded = await deleteAfterPendingInsert.value
        XCTAssertTrue(pendingInsertSucceeded)
        XCTAssertTrue(deleteAfterPendingInsertSucceeded)
        XCTAssertNil(store.position(for: 2))

        let pendingDelete = store.enqueueClearReadingPosition(threadID: 1)
        let insertAfterPendingDelete = store.enqueueReadingPosition(
            threadID: 1,
            postID: 1_002,
            floor: 2
        )
        let pendingDeleteSucceeded = await pendingDelete.value
        let insertAfterPendingDeleteSucceeded = await insertAfterPendingDelete.value
        XCTAssertTrue(pendingDeleteSucceeded)
        XCTAssertTrue(insertAfterPendingDeleteSucceeded)
        await store.waitForPendingReadingPositionMutations()
        XCTAssertEqual(store.position(for: 1)?.postID, 1_002)

        let reloaded = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "background-favorites",
            readingPositionsKey: "background-positions",
            readingPositionLimit: 4,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.readingPositions.map(\.threadID), [1])
        XCTAssertEqual(reloaded.position(for: 1)?.postID, 1_002)
    }

    @MainActor
    func testReadingPositionUpdatesRowsInPlaceAndPrunesOnlyTheOldestRecord() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            readingPositionLimit: 3,
            modelContainer: container
        ) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }

        store.recordReadingPosition(threadID: 1, postID: 1001, floor: 1)
        store.recordReadingPosition(threadID: 2, postID: 2001, floor: 2)
        let beforeUpdate = try container.mainContext.fetch(
            FetchDescriptor<ThreadReadingPositionRecord>()
        )
        let thread1ID = try XCTUnwrap(
            beforeUpdate.first(where: { $0.threadID == 1 })?.persistentModelID
        )
        let thread2ID = try XCTUnwrap(
            beforeUpdate.first(where: { $0.threadID == 2 })?.persistentModelID
        )

        store.recordReadingPosition(threadID: 1, postID: 1002, floor: 3)
        let afterUpdate = try container.mainContext.fetch(
            FetchDescriptor<ThreadReadingPositionRecord>()
        )
        XCTAssertEqual(afterUpdate.count, 2)
        XCTAssertEqual(
            afterUpdate.first(where: { $0.threadID == 1 })?.persistentModelID,
            thread1ID
        )
        XCTAssertEqual(
            afterUpdate.first(where: { $0.threadID == 2 })?.persistentModelID,
            thread2ID
        )
        XCTAssertEqual(store.position(for: 1)?.postID, 1002)

        store.recordReadingPosition(threadID: 3, postID: 3001, floor: 4)
        store.recordReadingPosition(threadID: 4, postID: 4001, floor: 5)
        let afterPruning = try container.mainContext.fetch(
            FetchDescriptor<ThreadReadingPositionRecord>()
        )
        XCTAssertEqual(Set(afterPruning.map(\.threadID)), [1, 3, 4])
        XCTAssertEqual(afterPruning.count, 3)
        XCTAssertEqual(
            afterPruning.first(where: { $0.threadID == 1 })?.persistentModelID,
            thread1ID
        )
        XCTAssertNil(afterPruning.first(where: { $0.threadID == 2 }))
        XCTAssertEqual(store.readingPositions.map(\.threadID), [4, 3, 1])
        let orderedRecords = afterPruning.sorted { $0.sortIndex < $1.sortIndex }
        XCTAssertEqual(orderedRecords.map(\.sortIndex), [0, 1, 2])
        XCTAssertEqual(orderedRecords.map(\.threadID), [4, 3, 1])

        let reloaded = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            readingPositionLimit: 3,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.readingPositions.map(\.threadID), [4, 3, 1])
        let afterReload = try container.mainContext.fetch(
            FetchDescriptor<ThreadReadingPositionRecord>()
        )
        XCTAssertEqual(
            Set(afterReload.map(\.persistentModelID)),
            Set(afterPruning.map(\.persistentModelID))
        )
    }

    // Replaces the corrupt-element tolerant-decode tests: the same JSON now
    // flows through the one-time UserDefaults-to-SwiftData migration, which
    // must drop corrupt elements, remove the legacy key, and never re-import.
    @MainActor
    func testRecentForumStoreMigratesLegacyDefaultsDroppingCorruptElements() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let json = #"[{"name":"first","displayName":"first吧","updatedAt":2},"corrupt",{"name":"second","displayName":"second吧","updatedAt":1}]"#
        defaults.set(Data(json.utf8), forKey: "recent-forums")

        let store = RecentForumStore(defaults: defaults, key: "recent-forums", limit: 30, modelContainer: container)

        XCTAssertEqual(store.items.map(\.name), ["first", "second"])
        XCTAssertNil(defaults.object(forKey: "recent-forums"))

        // A reappearing legacy key must not duplicate already-imported rows.
        defaults.set(Data(json.utf8), forKey: "recent-forums")
        let reloaded = RecentForumStore(defaults: defaults, key: "recent-forums", limit: 30, modelContainer: container)
        XCTAssertEqual(reloaded.items.map(\.name), ["first", "second"])
        XCTAssertNil(defaults.object(forKey: "recent-forums"))
    }

    @MainActor
    func testBrowsingHistoryStoreMigratesLegacyDefaultsDroppingCorruptElements() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let json = #"[{"threadID":1,"title":"第一条","authorDisplayName":"作者","visitedAt":1},{"threadID":"corrupt"},{"threadID":2,"title":"第二条","authorDisplayName":"作者","visitedAt":2}]"#
        defaults.set(Data(json.utf8), forKey: "browsing-history")

        let store = BrowsingHistoryStore(defaults: defaults, key: "browsing-history", limit: 10, modelContainer: container)

        XCTAssertEqual(store.items.map(\.threadID), [2, 1])
        XCTAssertNil(defaults.object(forKey: "browsing-history"))

        defaults.set(Data(json.utf8), forKey: "browsing-history")
        let reloaded = BrowsingHistoryStore(defaults: defaults, key: "browsing-history", limit: 10, modelContainer: container)
        XCTAssertEqual(reloaded.items.map(\.threadID), [2, 1])
        XCTAssertNil(defaults.object(forKey: "browsing-history"))
    }

    @MainActor
    func testLocalThreadLibraryStoreMigratesLegacyDefaultsDroppingCorruptElements() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let favoritesJSON = #"[{"threadID":1,"title":"第一条","authorDisplayName":"作者","savedAt":2}]"#
        let positionsJSON = #"[{"threadID":1,"postID":1001,"floor":2,"updatedAt":2},{"threadID":"corrupt"},{"threadID":2,"postID":2001,"floor":3,"updatedAt":1}]"#
        defaults.set(Data(favoritesJSON.utf8), forKey: "favorites")
        defaults.set(Data(positionsJSON.utf8), forKey: "positions")

        let store = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            readingPositionLimit: 10,
            modelContainer: container
        )

        XCTAssertEqual(store.readingPositions.map(\.threadID), [1, 2])
        XCTAssertEqual(store.position(for: 1)?.postID, 1001)
        XCTAssertNil(defaults.object(forKey: "positions"))
        // Collections moved to the account, so the retired blob is dropped
        // instead of imported.
        XCTAssertNil(defaults.object(forKey: "favorites"))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<ThreadFavoriteRecord>()),
            0
        )

        defaults.set(Data(positionsJSON.utf8), forKey: "positions")
        let reloaded = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            readingPositionLimit: 10,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.readingPositions.map(\.threadID), [1, 2])
        XCTAssertNil(defaults.object(forKey: "positions"))
    }

    @MainActor
    func testSearchHistoryStoreMigratesLegacyDefaultsArrayOnce() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        defaults.set(["第一条", "second", "   "], forKey: "search-history")

        let store = SearchHistoryStore(
            defaults: defaults,
            key: "search-history",
            limit: 20,
            modelContainer: container
        )

        XCTAssertEqual(store.items, ["第一条", "second"])
        XCTAssertNil(defaults.object(forKey: "search-history"))

        defaults.set(["旧数据"], forKey: "search-history")
        let reloaded = SearchHistoryStore(
            defaults: defaults,
            key: "search-history",
            limit: 20,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.items, ["第一条", "second"])
        XCTAssertNil(defaults.object(forKey: "search-history"))
    }

    @MainActor
    func testPersistenceUnavailableIsObservableAndRejectsVolatileWrites() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let author = UserSummary(
            id: 1,
            name: "author",
            displayName: "作者",
            portrait: ""
        )
        let thread = ThreadSummary(
            id: 10,
            forumID: 20,
            title: "不可伪装持久保存",
            author: author,
            forumName: "测试",
            replyCount: 0,
            viewCount: 0,
            blocks: []
        )

        let browsing = BrowsingHistoryStore(
            defaults: defaults,
            key: "unavailable-browsing",
            modelContainer: container,
            persistenceAvailability: .unavailable
        )
        XCTAssertEqual(browsing.persistenceAvailability, .unavailable)
        XCTAssertFalse(browsing.record(thread: thread))
        XCTAssertTrue(browsing.items.isEmpty)

        let recent = RecentForumStore(
            defaults: defaults,
            key: "unavailable-recent",
            modelContainer: container,
            persistenceAvailability: .unavailable
        )
        XCTAssertEqual(recent.persistenceAvailability, .unavailable)
        XCTAssertFalse(recent.save(name: "测试"))
        XCTAssertTrue(recent.items.isEmpty)

        defaults.set(["legacy"], forKey: "unavailable-search")
        let search = SearchHistoryStore(
            defaults: defaults,
            key: "unavailable-search",
            modelContainer: container,
            persistenceAvailability: .unavailable
        )
        XCTAssertEqual(search.persistenceAvailability, .unavailable)
        XCTAssertFalse(search.record("关键词"))
        XCTAssertEqual(search.items, ["legacy"])
        XCTAssertEqual(defaults.stringArray(forKey: "unavailable-search"), ["legacy"])

        let library = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "unavailable-favorites",
            readingPositionsKey: "unavailable-positions",
            modelContainer: container,
            persistenceAvailability: .unavailable
        )
        XCTAssertEqual(library.persistenceAvailability, .unavailable)
        XCTAssertFalse(library.recordReadingPosition(threadID: 10, postID: 100, floor: 1))
        XCTAssertTrue(library.readingPositions.isEmpty)
    }

    @MainActor
    func testLegacyArrayDecoderDistinguishesInvalidTopLevelFromValidEmptyArray() throws {
        let invalid = Data(#"{"not":"an array"}"#.utf8)
        let empty = Data("[]".utf8)

        XCTAssertNil(PersistedArrayDecoder.decode(BrowsingHistoryEntry.self, from: invalid))
        XCTAssertEqual(
            PersistedArrayDecoder.decode(BrowsingHistoryEntry.self, from: empty),
            []
        )

        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        defaults.set(invalid, forKey: "invalid-browsing")
        let store = BrowsingHistoryStore(
            defaults: defaults,
            key: "invalid-browsing",
            modelContainer: container
        )

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.persistenceAvailability, .unavailable)
        XCTAssertEqual(defaults.data(forKey: "invalid-browsing"), invalid)

        defaults.set(empty, forKey: "empty-browsing")
        let emptyStore = BrowsingHistoryStore(
            defaults: defaults,
            key: "empty-browsing",
            modelContainer: container
        )
        XCTAssertTrue(emptyStore.items.isEmpty)
        XCTAssertNil(defaults.object(forKey: "empty-browsing"))
    }

    @MainActor
    func testInvalidStaleLegacyValueDoesNotHideExistingSwiftDataRows() throws {
        let container = try makeInMemoryModelContainer()
        let context = container.mainContext
        context.insert(BrowsingHistoryRecord(
            entry: BrowsingHistoryEntry(
                threadID: 42,
                title: "持久化记录",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: 42)
            ),
            sortIndex: 0
        ))
        try context.save()

        let defaults = try makeScratchDefaults()
        defaults.set(Data(#"{"stale":"invalid"}"#.utf8), forKey: "stale-browsing")
        let store = BrowsingHistoryStore(
            defaults: defaults,
            key: "stale-browsing",
            modelContainer: container
        )

        XCTAssertEqual(store.items.map(\.threadID), [42])
        XCTAssertEqual(store.persistenceAvailability, .available)
        XCTAssertNil(defaults.object(forKey: "stale-browsing"))
    }

    @MainActor
    func testFailedLegacyMigrationKeepsKeyAndShowsSanitizedLegacyForSession() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let legacy = [
            BrowsingHistoryEntry(
                threadID: 7,
                forumID: -1,
                title: "  可恢复标题  ",
                authorDisplayName: "  作者  ",
                forumDisplayName: " ",
                visitedAt: Date(timeIntervalSinceReferenceDate: 7)
            )
        ]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "failed-migration")
        let store = BrowsingHistoryStore(
            defaults: defaults,
            key: "failed-migration",
            modelContainer: container,
            faultInjector: PersistenceFaultInjector { point in
                if point == .legacyMigration {
                    throw ExpectedPersistenceError.writeFailed
                }
            }
        )

        XCTAssertEqual(store.items.map(\.threadID), [7])
        XCTAssertEqual(store.items.first?.title, "可恢复标题")
        XCTAssertNil(store.items.first?.forumID)
        XCTAssertEqual(store.persistenceAvailability, .unavailable)
        XCTAssertEqual(defaults.data(forKey: "failed-migration"), data)
        XCTAssertTrue(try container.mainContext.fetch(
            FetchDescriptor<BrowsingHistoryRecord>()
        ).isEmpty)
    }

    @MainActor
    func testFailedRepairPublishesSanitizedDataAndRollsBackRawRecords() throws {
        let container = try makeInMemoryModelContainer()
        let context = container.mainContext
        context.insert(BrowsingHistoryRecord(
            entry: BrowsingHistoryEntry(
                threadID: 9,
                forumID: -1,
                title: "  旧标题  ",
                authorDisplayName: " ",
                visitedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            sortIndex: 0
        ))
        context.insert(BrowsingHistoryRecord(
            entry: BrowsingHistoryEntry(
                threadID: 9,
                title: "  新标题  ",
                authorDisplayName: "  新作者  ",
                visitedAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
            sortIndex: 1
        ))
        try context.save()

        let store = BrowsingHistoryStore(
            defaults: try makeScratchDefaults(),
            key: "repair-failure",
            limit: 10,
            modelContainer: container,
            faultInjector: PersistenceFaultInjector { point in
                if point == .repair {
                    throw ExpectedPersistenceError.writeFailed
                }
            }
        )

        XCTAssertEqual(store.items.map(\.threadID), [9])
        XCTAssertEqual(store.items.first?.title, "新标题")
        XCTAssertEqual(store.items.first?.authorDisplayName, "新作者")
        XCTAssertEqual(store.persistenceAvailability, .unavailable)
        let rolledBack = try context.fetch(FetchDescriptor<BrowsingHistoryRecord>())
        XCTAssertEqual(rolledBack.count, 2)
    }

    @MainActor
    func testClearAllRollsBackReadingPositionsOnFailure() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let initial = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "atomic-favorites",
            readingPositionsKey: "atomic-positions",
            modelContainer: container
        )
        XCTAssertTrue(initial.recordReadingPosition(threadID: 21, postID: 2101, floor: 2))

        let failing = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "atomic-favorites",
            readingPositionsKey: "atomic-positions",
            modelContainer: container,
            faultInjector: PersistenceFaultInjector { point in
                if point == .clearAll {
                    throw ExpectedPersistenceError.writeFailed
                }
            }
        )
        XCTAssertFalse(failing.clearAll())
        XCTAssertEqual(failing.readingPositions.map(\.threadID), [21])
        XCTAssertEqual(failing.persistenceAvailability, .unavailable)
        XCTAssertEqual(try container.mainContext.fetchCount(
            FetchDescriptor<ThreadReadingPositionRecord>()
        ), 1)
    }

    @MainActor
    func testLegacyMigrationsSanitizeSortDeduplicateAndLimitBeforeSaving() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()

        let browsingLegacy = [
            BrowsingHistoryEntry(
                threadID: 1,
                forumID: -1,
                title: " 旧标题 ",
                authorDisplayName: " ",
                forumDisplayName: " ",
                visitedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            BrowsingHistoryEntry(
                threadID: 2,
                title: "第二条",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
            BrowsingHistoryEntry(
                threadID: 1,
                title: " 最新标题 ",
                authorDisplayName: " 最新作者 ",
                visitedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            BrowsingHistoryEntry(
                threadID: 0,
                title: "无效",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: 4)
            )
        ]
        defaults.set(try JSONEncoder().encode(browsingLegacy), forKey: "clean-browsing")

        let recentLegacy = [
            RecentForum(
                name: "same",
                displayName: "旧名称",
                avatarURL: URL(string: "http://example.com/a.png"),
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            RecentForum(
                name: " second ",
                displayName: " ",
                avatarURL: URL(string: "https://example.com/b.png"),
                updatedAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
            RecentForum(
                name: "SAME",
                displayName: "新名称",
                avatarURL: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            RecentForum(
                name: " ",
                displayName: "无效",
                avatarURL: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 4)
            )
        ]
        defaults.set(try JSONEncoder().encode(recentLegacy), forKey: "clean-recent")

        let positionsLegacy = [
            ThreadReadingPosition(
                threadID: 1,
                postID: 100,
                floor: 1,
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            ThreadReadingPosition(
                threadID: 2,
                postID: 200,
                floor: 2,
                updatedAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
            ThreadReadingPosition(
                threadID: 1,
                postID: 101,
                floor: 3,
                updatedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            ThreadReadingPosition(
                threadID: -1,
                postID: 300,
                floor: 4,
                updatedAt: Date(timeIntervalSinceReferenceDate: 4)
            )
        ]
        defaults.set(try JSONEncoder().encode(positionsLegacy), forKey: "clean-positions")
        defaults.set(
            [" first ", "SECOND", "second", " ", "third"],
            forKey: "clean-search"
        )

        let browsing = BrowsingHistoryStore(
            defaults: defaults,
            key: "clean-browsing",
            limit: 2,
            modelContainer: container
        )
        let recent = RecentForumStore(
            defaults: defaults,
            key: "clean-recent",
            limit: 2,
            modelContainer: container
        )
        let library = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "clean-favorites",
            readingPositionsKey: "clean-positions",
            readingPositionLimit: 2,
            modelContainer: container
        )
        let search = SearchHistoryStore(
            defaults: defaults,
            key: "clean-search",
            limit: 2,
            modelContainer: container
        )

        XCTAssertEqual(browsing.items.map(\.threadID), [1, 2])
        XCTAssertEqual(browsing.items.first?.title, "最新标题")
        XCTAssertEqual(recent.items.map(\.name), ["SAME", "second"])
        XCTAssertEqual(recent.items.last?.displayName, "second吧")
        XCTAssertEqual(recent.items.last?.avatarURL?.scheme, "https")
        XCTAssertEqual(library.readingPositions.map(\.threadID), [1, 2])
        XCTAssertEqual(library.readingPositions.first?.postID, 101)
        XCTAssertEqual(search.items, ["first", "SECOND"])

        for key in [
            "clean-browsing",
            "clean-recent",
            "clean-favorites",
            "clean-positions",
            "clean-search"
        ] {
            XCTAssertNil(defaults.object(forKey: key))
        }

        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<BrowsingHistoryRecord>()),
            2
        )
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<RecentForumRecord>()),
            2
        )
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<ThreadReadingPositionRecord>()),
            2
        )
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<SearchHistoryRecord>()),
            2
        )
    }

    @MainActor
    func testExistingSwiftDataRowsAreRepairedAndAllPoliciesEnforceCaps() throws {
        let container = try makeInMemoryModelContainer()
        let context = container.mainContext
        let defaults = try makeScratchDefaults()

        let historyRows = [
            BrowsingHistoryEntry(
                threadID: 1,
                title: "旧",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            BrowsingHistoryEntry(
                threadID: 1,
                title: "新",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            BrowsingHistoryEntry(
                threadID: -1,
                title: "无效",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: 4)
            ),
            BrowsingHistoryEntry(
                threadID: 2,
                title: "第二条",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: 2)
            )
        ]
        try PersistedRecordStore.replaceAll(
            BrowsingHistoryRecord.self,
            with: historyRows.enumerated().map {
                BrowsingHistoryRecord(entry: $0.element, sortIndex: $0.offset)
            },
            in: context
        )

        try PersistedRecordStore.replaceAll(
            ThreadFavoriteRecord.self,
            with: [ThreadFavoriteRecord(threadID: 1, title: "旧收藏", savedAt: .distantPast)],
            in: context
        )

        let positionRows = [
            ThreadReadingPosition(
                threadID: 1,
                postID: 100,
                floor: 1,
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            ThreadReadingPosition(
                threadID: 1,
                postID: 101,
                floor: 2,
                updatedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            ThreadReadingPosition(
                threadID: 0,
                postID: 0,
                floor: -1,
                updatedAt: Date(timeIntervalSinceReferenceDate: 4)
            ),
            ThreadReadingPosition(
                threadID: 2,
                postID: 200,
                floor: 2,
                updatedAt: Date(timeIntervalSinceReferenceDate: 2)
            )
        ]
        try PersistedRecordStore.replaceAll(
            ThreadReadingPositionRecord.self,
            with: positionRows.enumerated().map {
                ThreadReadingPositionRecord(entry: $0.element, sortIndex: $0.offset)
            },
            in: context
        )

        let recentRows = [
            RecentForum(
                name: "same",
                displayName: "旧",
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            RecentForum(
                name: "SAME",
                displayName: "新",
                updatedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            RecentForum(
                name: " ",
                displayName: "无效",
                updatedAt: Date(timeIntervalSinceReferenceDate: 4)
            ),
            RecentForum(
                name: "second",
                displayName: "第二吧",
                updatedAt: Date(timeIntervalSinceReferenceDate: 2)
            )
        ]
        try PersistedRecordStore.replaceAll(
            RecentForumRecord.self,
            with: recentRows.enumerated().map {
                RecentForumRecord(entry: $0.element, sortIndex: $0.offset)
            },
            in: context
        )
        try PersistedRecordStore.replaceAll(
            SearchHistoryRecord.self,
            with: ["first", " ", "FIRST", "second"].enumerated().map {
                SearchHistoryRecord(keyword: $0.element, sortIndex: $0.offset)
            },
            in: context
        )

        let browsing = BrowsingHistoryStore(
            defaults: defaults,
            key: "repair-browsing",
            limit: 2,
            modelContainer: container
        )
        let recent = RecentForumStore(
            defaults: defaults,
            key: "repair-recent",
            limit: 2,
            modelContainer: container
        )
        let library = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "repair-favorites",
            readingPositionsKey: "repair-positions",
            readingPositionLimit: 2,
            modelContainer: container
        )
        let search = SearchHistoryStore(
            defaults: defaults,
            key: "repair-search",
            limit: 2,
            modelContainer: container
        )

        XCTAssertEqual(browsing.items.map(\.threadID), [1, 2])
        XCTAssertEqual(recent.items.map(\.name), ["SAME", "second"])
        XCTAssertEqual(library.readingPositions.map(\.threadID), [1, 2])
        XCTAssertEqual(search.items, ["first", "second"])
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<BrowsingHistoryRecord>()),
            2
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecentForumRecord>()), 2)
        // Retired collection rows are dropped rather than repaired.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ThreadFavoriteRecord>()), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ThreadReadingPositionRecord>()),
            2
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SearchHistoryRecord>()), 2)

        let manyHistories = (1...600).map {
            BrowsingHistoryEntry(
                threadID: Int64($0),
                title: "\($0)",
                authorDisplayName: "作者",
                visitedAt: Date(timeIntervalSinceReferenceDate: TimeInterval($0))
            )
        }
        let manyPositions = manyHistories.map {
            ThreadReadingPosition(
                threadID: $0.threadID,
                postID: UInt64($0.threadID),
                floor: 0,
                updatedAt: $0.visitedAt
            )
        }
        let manyForums = (1...40).map {
            RecentForum(
                name: "forum\($0)",
                displayName: "forum\($0)吧",
                updatedAt: Date(timeIntervalSinceReferenceDate: TimeInterval($0))
            )
        }
        let manySearches = (1...30).map { "keyword\($0)" }

        XCTAssertEqual(
            BrowsingHistoryPolicy.sanitized(
                manyHistories,
                limit: 10_000
            ).count,
            500
        )
        XCTAssertEqual(
            LocalThreadLibraryPolicy.sanitizedReadingPositions(
                manyPositions,
                limit: 10_000
            ).count,
            500
        )
        XCTAssertEqual(
            RecentForumPolicy.sanitized(
                manyForums,
                limit: 10_000
            ).count,
            30
        )
        XCTAssertEqual(
            SearchHistoryPolicy.sanitized(
                manySearches,
                limit: 10_000
            ).count,
            20
        )
    }

    func testThreadReadingVisibilityPolicyRecordsBottomMostVisibleReply() {
        let mainPostID: UInt64 = 2001
        let postIDs: [UInt64] = [2001, 2002, 2003, 2004]
        let visiblePostIDs: Set<UInt64> = [2001, 2002, 2003]

        XCTAssertEqual(
            ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
                postIDsInDisplayOrder: postIDs,
                visiblePostIDs: visiblePostIDs,
                excludedPostID: mainPostID
            ),
            2003
        )
        XCTAssertEqual(
            ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
                postIDsInDisplayOrder: [2001, 2004, 2003, 2002],
                visiblePostIDs: visiblePostIDs,
                excludedPostID: mainPostID
            ),
            2002,
            "倒序或热门列表必须按当前显示顺序选择最下方可见回复"
        )
        XCTAssertNil(ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
            postIDsInDisplayOrder: [mainPostID],
            visiblePostIDs: [mainPostID],
            excludedPostID: mainPostID
        ))
        XCTAssertNil(ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
            postIDsInDisplayOrder: postIDs,
            visiblePostIDs: [],
            excludedPostID: mainPostID
        ))
    }

    func testThreadReadingScrollRegionUsesStableBoundaries() {
        XCTAssertEqual(ThreadReadingScrollRegion.resolve(distanceFromTop: -1), .top)
        XCTAssertEqual(ThreadReadingScrollRegion.resolve(distanceFromTop: 0), .top)
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ShortPullRefreshPolicy.topTolerance
            ),
            .top
        )
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ShortPullRefreshPolicy.topTolerance + 0.5
            ),
            .nearTop
        )
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ThreadReadingViewportPolicy.minimumRecordingDistance - 0.5
            ),
            .nearTop
        )
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ThreadReadingViewportPolicy.minimumRecordingDistance
            ),
            .away
        )
    }

    func testThreadReadingPersistenceWaitsForIdleAndSelectsOneAction() {
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .away,
                didMoveAwayFromTop: true
            ),
            .record
        )
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .top,
                didMoveAwayFromTop: true
            ),
            .clear
        )
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .nearTop,
                didMoveAwayFromTop: true
            ),
            .none
        )
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .away,
                didMoveAwayFromTop: false
            ),
            .none
        )
    }

    func testThreadReadingTrackingCancelsPendingCommitWithoutDiscardingViewport() {
        let state = ThreadReadingTrackingState()
        state.visiblePostIDs = [2002, 2003]
        state.scrollRegion = .away
        state.lastRecordedPostID = 2002
        state.didMoveAwayFromTop = true
        state.pendingCommitTask = Task {}

        state.cancelPendingCommit()

        XCTAssertEqual(state.visiblePostIDs, [2002, 2003])
        XCTAssertEqual(state.scrollRegion, .away)
        XCTAssertNil(state.pendingCommitTask)
        XCTAssertEqual(state.lastRecordedPostID, 2002)
        XCTAssertTrue(state.didMoveAwayFromTop)
    }

    func testThreadReadingTrackingUsesViewportVisibilityWithoutDuplicates() {
        let state = ThreadReadingTrackingState()

        XCTAssertTrue(state.postBecameVisible(2002))
        XCTAssertTrue(state.postBecameVisible(2003))
        XCTAssertFalse(state.postBecameVisible(2002))
        XCTAssertFalse(state.postBecameVisible(0))
        XCTAssertEqual(state.visiblePostIDs, [2002, 2003])

        XCTAssertTrue(state.postBecameHidden(2002))
        XCTAssertFalse(state.postBecameHidden(2002))
        XCTAssertEqual(state.visiblePostIDs, [2003])
    }

    func testThreadReadingTrackingKeepsDeferredPageLoadUntilItCanStart() {
        let state = ThreadReadingTrackingState()
        XCTAssertFalse(state.consumePendingAutomaticPageLoad(canLoad: true))

        state.pendingAutomaticPageLoad = true
        XCTAssertFalse(state.consumePendingAutomaticPageLoad(canLoad: false))
        XCTAssertTrue(state.pendingAutomaticPageLoad)
        XCTAssertTrue(state.consumePendingAutomaticPageLoad(canLoad: true))
        XCTAssertFalse(state.consumePendingAutomaticPageLoad(canLoad: true))
    }

    func testThreadReadingTrackingResetClearsViewportAndRegion() {
        let state = ThreadReadingTrackingState()
        state.visiblePostIDs = [2002, 2003]
        state.isScrollIdle = false
        state.scrollRegion = .away
        state.lastRecordedPostID = 2003
        state.didMoveAwayFromTop = true
        state.pendingCommitTask = Task {}
        state.pendingAutomaticPageLoad = true

        state.reset()

        XCTAssertEqual(state.visiblePostIDs, [])
        XCTAssertTrue(state.isScrollIdle)
        XCTAssertEqual(state.scrollRegion, .top)
        XCTAssertNil(state.lastRecordedPostID)
        XCTAssertFalse(state.didMoveAwayFromTop)
        XCTAssertNil(state.pendingCommitTask)
        XCTAssertFalse(state.pendingAutomaticPageLoad)
    }

    func testPreciseScrollSessionsDistinguishRepeatedRestoreToSamePost() {
        let first = ThreadPreciseScrollSession(postID: 2002)
        let second = ThreadPreciseScrollSession(postID: 2002)

        XCTAssertEqual(first.postID, second.postID)
        XCTAssertNotEqual(first, second)
    }

    func testFixtureSearchCarriesPostIDAndCancellationPropagates() async throws {
        let api = FixtureTiebaAPI(scenario: .success)
        let page = try await api.searchThreads(
            keyword: "确定性",
            page: 1,
            sortType: 5,
            filterType: 2,
            forumName: nil,
            pageSize: 30
        )
        XCTAssertEqual(page.results.first?.postID, 2002)

        let slow = FixtureTiebaAPI(scenario: .slow)
        let task = Task {
            try await slow.searchThreads(
                keyword: "慢请求",
                page: 1,
                sortType: 5,
                filterType: 2,
                forumName: nil,
                pageSize: 30
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    @MainActor
    func testReadingPreferencesPersistIndependentlyAndRemoveDefaultValues() throws {
        let defaults = try makeScratchDefaults()
        let keys = ReadingPreferencesStore.StorageKeys(
            fontSize: "reader-font",
            lineSpacing: "reader-spacing",
            defaultReplySort: "reader-sort",
            mediaLoading: "reader-media"
        )
        let store = ReadingPreferencesStore(defaults: defaults, keys: keys)

        XCTAssertEqual(store.preferences, .default)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))

        store.select(fontSize: .large)
        XCTAssertEqual(defaults.string(forKey: keys.fontSize), ReaderFontSize.large.rawValue)
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))

        store.select(lineSpacing: .relaxed)
        store.select(defaultReplySort: .descending)
        store.select(mediaLoading: .manual)
        XCTAssertEqual(
            ReadingPreferencesStore(defaults: defaults, keys: keys).preferences,
            ReadingPreferences(
                fontSize: .large,
                lineSpacing: .relaxed,
                defaultReplySort: .descending,
                mediaLoading: .manual
            )
        )

        store.select(fontSize: .standard)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertEqual(defaults.string(forKey: keys.lineSpacing), ReaderLineSpacing.relaxed.rawValue)
        XCTAssertEqual(defaults.integer(forKey: keys.defaultReplySort), ThreadReplySort.descending.rawValue)
        XCTAssertEqual(defaults.string(forKey: keys.mediaLoading), ReaderMediaLoadingPolicy.manual.rawValue)

        store.update(.default)
        XCTAssertEqual(store.preferences, .default)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))
    }

    @MainActor
    func testReadingPreferencesSanitizeOnlyInvalidStoredValues() throws {
        let defaults = try makeScratchDefaults()
        let keys = ReadingPreferencesStore.StorageKeys(
            fontSize: "reader-font",
            lineSpacing: "reader-spacing",
            defaultReplySort: "reader-sort",
            mediaLoading: "reader-media"
        )
        defaults.set("oversized", forKey: keys.fontSize)
        defaults.set(ReaderLineSpacing.compact.rawValue, forKey: keys.lineSpacing)
        defaults.set(ThreadReplySort.ascending.rawValue, forKey: keys.defaultReplySort)
        defaults.set(ReaderMediaLoadingPolicy.dataSaving.rawValue, forKey: keys.mediaLoading)

        let store = ReadingPreferencesStore(defaults: defaults, keys: keys)
        XCTAssertEqual(store.preferences.fontSize, .standard)
        XCTAssertEqual(store.preferences.lineSpacing, .compact)
        XCTAssertEqual(store.preferences.defaultReplySort, .ascending)
        XCTAssertEqual(store.preferences.mediaLoading, .dataSaving)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertEqual(defaults.string(forKey: keys.lineSpacing), ReaderLineSpacing.compact.rawValue)
        XCTAssertEqual(defaults.integer(forKey: keys.defaultReplySort), ThreadReplySort.ascending.rawValue)
        XCTAssertEqual(
            defaults.string(forKey: keys.mediaLoading),
            ReaderMediaLoadingPolicy.dataSaving.rawValue
        )

        defaults.set("invalid-media-policy", forKey: keys.mediaLoading)
        let sanitizedMedia = ReadingPreferencesStore(defaults: defaults, keys: keys)
        XCTAssertEqual(sanitizedMedia.preferences.lineSpacing, .compact)
        XCTAssertEqual(sanitizedMedia.preferences.defaultReplySort, .ascending)
        XCTAssertEqual(sanitizedMedia.preferences.mediaLoading, .automatic)
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))
        XCTAssertNotNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNotNil(defaults.object(forKey: keys.defaultReplySort))
    }

    @MainActor
    func testReadingPreferencesResetRemovesEveryOverride() throws {
        let defaults = try makeScratchDefaults()
        let keys = ReadingPreferencesStore.StorageKeys(
            fontSize: "reader-font",
            lineSpacing: "reader-spacing",
            defaultReplySort: "reader-sort",
            mediaLoading: "reader-media"
        )
        let store = ReadingPreferencesStore(defaults: defaults, keys: keys)
        store.update(ReadingPreferences(
            fontSize: .extraLarge,
            lineSpacing: .relaxed,
            defaultReplySort: .descending,
            mediaLoading: .manual
        ))

        store.reset()

        XCTAssertEqual(store.preferences, .default)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))
    }

    func testReaderFontSizeAndDynamicTypeScalingAreMonotonic() {
        let largeCategory = UITraitCollection(preferredContentSizeCategory: .large)
        let pointSizes = ReaderFontSize.allCases.map {
            ReaderTypographyPolicy.font(
                textStyle: .body,
                fontSize: $0,
                compatibleWith: largeCategory
            ).pointSize
        }
        XCTAssertEqual(pointSizes.count, 4)
        XCTAssertLessThan(pointSizes[0], pointSizes[1])
        XCTAssertLessThan(pointSizes[1], pointSizes[2])
        XCTAssertLessThan(pointSizes[2], pointSizes[3])

        let accessibilityCategory = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let standardFont = ReaderTypographyPolicy.font(
            textStyle: .body,
            fontSize: .standard,
            compatibleWith: largeCategory
        )
        let accessibilityFont = ReaderTypographyPolicy.font(
            textStyle: .body,
            fontSize: .standard,
            compatibleWith: accessibilityCategory
        )
        XCTAssertGreaterThan(accessibilityFont.pointSize, standardFont.pointSize)
    }

    func testReaderLineSpacingPreservesExistingDefaultsAndMapsPreferences() {
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.standard, context: .body),
            4,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.standard, context: .subpost),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.compact, context: .body),
            3,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.relaxed, context: .body),
            6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.compact, context: .subpost),
            1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.relaxed, context: .subpost),
            3,
            accuracy: 0.001
        )
    }

    func testReaderMediaRequestPolicyControlsAutomaticAndFallbackRequests() {
        XCTAssertEqual(
            ReaderMediaRequestPolicy.resolve(.automatic),
            ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: true)
        )
        XCTAssertEqual(
            ReaderMediaRequestPolicy.resolve(.dataSaving),
            ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: false)
        )
        XCTAssertEqual(
            ReaderMediaRequestPolicy.resolve(.manual),
            ReaderMediaRequestPolicy(loadsAutomatically: false, allowsFallback: true)
        )

        let manual = ReaderMediaRequestPolicy.resolve(.manual)
        XCTAssertFalse(manual.allowsLoading(sourceIdentity: "image-a", manualAuthorization: nil))
        XCTAssertTrue(manual.allowsLoading(sourceIdentity: "image-a", manualAuthorization: "image-a"))
        XCTAssertFalse(
            manual.allowsLoading(sourceIdentity: "image-b", manualAuthorization: "image-a"),
            "手动加载授权不得跟随复用视图泄漏到新的媒体 URL"
        )

        let dataSaving = ReaderMediaRequestPolicy.resolve(.dataSaving)
        XCTAssertFalse(dataSaving.allowsFallback(sourceIdentity: "image-a", explicitAuthorization: nil))
        XCTAssertTrue(
            dataSaving.allowsFallback(
                sourceIdentity: "image-a",
                explicitAuthorization: "image-a"
            )
        )
        XCTAssertFalse(
            dataSaving.allowsFallback(
                sourceIdentity: "image-b",
                explicitAuthorization: "image-a"
            ),
            "显式原图授权只属于用户点击的当前媒体"
        )
    }

    func testReaderImageRequestSourcePolicySkipsFailedPreviewAfterExplicitOriginalTap() throws {
        let preview = try XCTUnwrap(URL(string: "https://example.com/preview.jpg"))
        let original = try XCTUnwrap(URL(string: "https://example.com/original.jpg"))
        let sourceIdentity = "image-a"

        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.automatic),
                sourceIdentity: sourceIdentity,
                explicitOriginalAuthorization: nil
            ),
            ReaderImageRequestSources(primaryURL: preview, fallbackURL: original)
        )
        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.dataSaving),
                sourceIdentity: sourceIdentity,
                explicitOriginalAuthorization: nil
            ),
            ReaderImageRequestSources(primaryURL: preview, fallbackURL: nil)
        )
        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.dataSaving),
                sourceIdentity: sourceIdentity,
                explicitOriginalAuthorization: sourceIdentity
            ),
            ReaderImageRequestSources(primaryURL: original, fallbackURL: nil),
            "明确点击加载原图后必须跳过已经失败的缩略图"
        )
        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.dataSaving),
                sourceIdentity: "image-b",
                explicitOriginalAuthorization: sourceIdentity
            ),
            ReaderImageRequestSources(primaryURL: preview, fallbackURL: nil),
            "原图授权不得泄漏到复用后的另一张图片"
        )
    }

    func testAutomaticMediaRemainsActivatableWhilePreviewLoads() {
        XCTAssertFalse(ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: .resolve(.automatic)
        ))
        XCTAssertFalse(ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: .resolve(.dataSaving)
        ))
        XCTAssertTrue(ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: .resolve(.manual)
        ))
    }

    func testInitialPostTargetOverridesDefaultReplySort() {
        XCTAssertEqual(
            ThreadInitialReplySortPolicy.resolve(
                defaultReplySort: .descending,
                initialPostID: 2_002
            ),
            .ascending
        )
        XCTAssertEqual(
            ThreadInitialReplySortPolicy.resolve(
                defaultReplySort: .hot,
                initialPostID: 2_002
            ),
            .ascending
        )
        XCTAssertEqual(
            ThreadInitialReplySortPolicy.resolve(
                defaultReplySort: .descending,
                initialPostID: nil
            ),
            .descending
        )
    }
}

final class LocalThreadLibraryPersistenceTests: XCTestCase {
    private enum ExpectedError: Error {
        case replaceFailed
    }

    @MainActor
    func testFileBackendPersistsMutationsAcrossInstances() throws {
        let fileURL = makeTemporaryFileURL()
        let first = try FileThreadReadingPositionPersistence(fileURL: fileURL)
        let older = makePosition(threadID: 1, postID: 101, floor: 1, updatedAt: 1)
        let newer = makePosition(threadID: 2, postID: 202, floor: 2, updatedAt: 2)

        try first.replaceAll([older])
        try first.upsert(newer, limit: 10)

        let reopened = try FileThreadReadingPositionPersistence(fileURL: fileURL)
        XCTAssertEqual(try reopened.load().map(\.threadID), [2, 1])
        XCTAssertEqual(try reopened.load().first?.postID, 202)

        try reopened.remove(threadID: 2)
        XCTAssertEqual(try first.load(), [older])
        try reopened.removeAll()
        XCTAssertEqual(try first.load(), [])
        XCTAssertTrue(reopened.hasStateArtifacts)
    }

    @MainActor
    func testStoreUsesInjectedFileBackendAndMigratesLegacyDefaults() throws {
        let fileURL = makeTemporaryFileURL()
        let defaults = try makeScratchDefaults()
        let legacyKey = "file-reading-positions"
        let favoritesKey = "retired-file-favorites"
        let legacy = [
            makePosition(threadID: 1, postID: 101, floor: 1, updatedAt: 1),
            makePosition(threadID: 2, postID: 202, floor: 2, updatedAt: 2)
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: legacyKey)
        defaults.set(Data("retired".utf8), forKey: favoritesKey)
        let persistence = try FileThreadReadingPositionPersistence(fileURL: fileURL)

        let store = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: favoritesKey,
            readingPositionsKey: legacyKey,
            readingPositionLimit: 2,
            persistence: persistence,
            now: { Date(timeIntervalSinceReferenceDate: 3) }
        )

        XCTAssertEqual(store.readingPositions.map(\.threadID), [2, 1])
        XCTAssertNil(defaults.object(forKey: legacyKey))
        XCTAssertNil(defaults.object(forKey: favoritesKey))
        XCTAssertTrue(store.recordReadingPosition(threadID: 3, postID: 303, floor: 3))

        let reopened = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: favoritesKey,
            readingPositionsKey: legacyKey,
            readingPositionLimit: 2,
            persistence: try FileThreadReadingPositionPersistence(fileURL: fileURL)
        )
        XCTAssertEqual(reopened.readingPositions.map(\.threadID), [3, 2])
        XCTAssertEqual(reopened.persistenceAvailability, .available)
    }

    @MainActor
    func testFileToDestinationMigrationTreatsActiveFileAsAuthority() throws {
        let fileURL = makeTemporaryFileURL()
        let source = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: false
        ) {
            throw ExpectedError.replaceFailed
        }.make()
        let fileValues = [
            makePosition(threadID: 1, postID: 105, floor: 5, updatedAt: 5),
            makePosition(threadID: 2, postID: 202, floor: 2, updatedAt: 2)
        ]
        try source.replaceAll(fileValues)
        let destination = TestThreadReadingPositionPersistence(values: [
            makePosition(threadID: 1, postID: 101, floor: 1, updatedAt: 1),
            makePosition(threadID: 1, postID: 100, floor: 0, updatedAt: 0),
            makePosition(threadID: 3, postID: 303, floor: 3, updatedAt: 3),
            makePosition(threadID: 3, postID: 304, floor: 4, updatedAt: 4)
        ])

        let migrated = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true,
            now: { Date(timeIntervalSinceReferenceDate: 10) }
        ) { destination }.make()

        XCTAssertTrue(migrated === destination)
        XCTAssertEqual(destination.values.map(\.threadID), [1, 2])
        XCTAssertEqual(destination.values.first?.postID, 105)
        let retainedFile = try FileThreadReadingPositionPersistence(fileURL: fileURL)
        let state = try XCTUnwrap(retainedFile.loadBackendState())
        XCTAssertEqual(state.activeBackend, .swiftData)
        XCTAssertEqual(state.migrationState, .fileMigrationCompleted)
        XCTAssertEqual(state.retainedFilePositions, fileValues)
        XCTAssertEqual(state.activation?.completedAt, Date(timeIntervalSinceReferenceDate: 10))

        let reopened = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()
        XCTAssertTrue(reopened === destination)
        XCTAssertEqual(destination.replaceCallCount, 1)
    }

    @MainActor
    func testNativeActivationPendingResumesWithItsOriginalGeneration() throws {
        let fileURL = makeTemporaryFileURL()
        let file = try FileThreadReadingPositionPersistence(fileURL: fileURL)
        let generationID = "11111111-1111-1111-1111-111111111111"
        let pendingState = try file.prepareNativeSwiftDataActivation(
            generationID: generationID,
            now: Date(timeIntervalSinceReferenceDate: 1)
        )
        XCTAssertEqual(pendingState.migrationState, .nativeActivationPending)
        let destination = TestThreadReadingPositionPersistence()

        let resolved = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true,
            now: { Date(timeIntervalSinceReferenceDate: 2) }
        ) { destination }.make()

        XCTAssertTrue(resolved === destination)
        XCTAssertEqual(destination.generationID, generationID)
        let completedState = try XCTUnwrap(file.loadBackendState())
        XCTAssertEqual(completedState.migrationState, .nativeSwiftData)
        XCTAssertEqual(completedState.activation?.destinationGenerationID, generationID)
    }

    @MainActor
    func testMissingStateWithExistingDestinationMarkerFailsClosed() throws {
        let fileURL = makeTemporaryFileURL()
        let destination = TestThreadReadingPositionPersistence()
        destination.generationID = "11111111-1111-1111-1111-111111111111"

        let resolved = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertEqual(resolved.capability, .unavailable)
        XCTAssertThrowsError(try resolved.load())
        XCTAssertNil(
            try FileThreadReadingPositionPersistence(fileURL: fileURL).loadBackendState()
        )
    }

    @MainActor
    func testFileMigrationKeepsSourceWhenDestinationCommitFails() throws {
        let fileURL = makeTemporaryFileURL()
        let source = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: false
        ) { throw ExpectedError.replaceFailed }.make()
        let sourceValues = [
            makePosition(threadID: 7, postID: 707, floor: 7, updatedAt: 7)
        ]
        try source.replaceAll(sourceValues)
        let destination = TestThreadReadingPositionPersistence()
        destination.replaceError = ExpectedError.replaceFailed

        let resolved = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertFalse(resolved === destination)
        XCTAssertEqual(try resolved.load(), sourceValues)
        let state = try XCTUnwrap(
            try FileThreadReadingPositionPersistence(fileURL: fileURL).loadBackendState()
        )
        XCTAssertEqual(state.activeBackend, .secureFiles)
        XCTAssertTrue(destination.values.isEmpty)
    }

    @MainActor
    func testFileMigrationDoesNotWriteReceiptWhenReadbackDiffers() throws {
        let fileURL = makeTemporaryFileURL()
        let source = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: false
        ) { throw ExpectedError.replaceFailed }.make()
        try source.replaceAll([
            makePosition(threadID: 4, postID: 404, floor: 4, updatedAt: 4)
        ])
        let destination = TestThreadReadingPositionPersistence()
        destination.corruptReadbackAfterReplace = true

        let resolved = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertFalse(resolved === destination)
        XCTAssertEqual(try resolved.load().map(\.threadID), [4])
        let state = try XCTUnwrap(
            try FileThreadReadingPositionPersistence(fileURL: fileURL).loadBackendState()
        )
        XCTAssertEqual(state.activeBackend, .secureFiles)
    }

    @MainActor
    func testFileMigrationDefersWhenDestinationIsNotDurable() throws {
        let fileURL = makeTemporaryFileURL()
        let source = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: false
        ) { throw ExpectedError.replaceFailed }.make()
        try source.replaceAll([
            makePosition(threadID: 9, postID: 909, floor: 9, updatedAt: 9)
        ])
        let destination = TestThreadReadingPositionPersistence(capability: .fallback)

        let resolved = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertFalse(resolved === destination)
        XCTAssertEqual(try resolved.load().map(\.threadID), [9])
        XCTAssertEqual(destination.replaceCallCount, 0)
    }

    @MainActor
    func testCompletedMigrationKeepsSwiftDataAuthoritativeAfterLegitimateClear() throws {
        let fileURL = makeTemporaryFileURL()
        let source = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: false
        ) { throw ExpectedError.replaceFailed }.make()
        try source.replaceAll([
            makePosition(threadID: 5, postID: 505, floor: 5, updatedAt: 5)
        ])
        let destination = TestThreadReadingPositionPersistence()
        _ = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()
        destination.values = []

        let reopened = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertTrue(reopened === destination)
        XCTAssertEqual(try reopened.load(), [])
        XCTAssertEqual(destination.replaceCallCount, 1)
    }

    @MainActor
    func testCompletedMigrationFailsClosedWhenDestinationMarkerIsLost() throws {
        let fileURL = makeTemporaryFileURL()
        let source = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: false
        ) { throw ExpectedError.replaceFailed }.make()
        try source.replaceAll([
            makePosition(threadID: 6, postID: 606, floor: 6, updatedAt: 6)
        ])
        let destination = TestThreadReadingPositionPersistence()
        _ = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()
        destination.generationID = nil

        let reopened = ThreadReadingPositionPersistenceFactory(
            fileURL: fileURL,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertEqual(reopened.capability, .unavailable)
        XCTAssertThrowsError(try reopened.load())
        XCTAssertEqual(destination.values.map(\.threadID), [6])
    }

    @MainActor
    func testCancelledFileMutationDoesNotCommitAndNextMutationStillSucceeds() async throws {
        let fileURL = makeTemporaryFileURL()
        let persistence = try FileThreadReadingPositionPersistence(fileURL: fileURL)
        try persistence.replaceAll([
            makePosition(threadID: 1, postID: 101, floor: 1, updatedAt: 1)
        ])
        var continuation: AsyncStream<Void>.Continuation?
        let gate = AsyncStream<Void> { continuation = $0 }
        let cancelled = Task { @MainActor in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return try await persistence.upsertInBackground(
                makePosition(threadID: 2, postID: 202, floor: 2, updatedAt: 2),
                limit: 10
            )
        }
        cancelled.cancel()
        continuation?.yield(())
        continuation?.finish()

        switch await cancelled.result {
        case .success:
            XCTFail("cancelled mutation unexpectedly committed")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try persistence.load().map(\.threadID), [1])

        let next = try await persistence.upsertInBackground(
            makePosition(threadID: 3, postID: 303, floor: 3, updatedAt: 3),
            limit: 10
        )
        XCTAssertEqual(next.map(\.threadID), [3, 1])
    }

    private func makeTemporaryFileURL(function: String = #function) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(function)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("positions.json", isDirectory: false)
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

    private func makePosition(
        threadID: Int64,
        postID: UInt64,
        floor: Int,
        updatedAt: TimeInterval
    ) -> ThreadReadingPosition {
        ThreadReadingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor,
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt)
        )
    }
}

@MainActor
private final class TestThreadReadingPositionPersistence:
    ThreadReadingPositionMigrationDestination {
    let capability: PersistenceCapability
    var values: [ThreadReadingPosition]
    var replaceError: Error?
    var corruptReadbackAfterReplace = false
    var generationID: String?
    private(set) var replaceCallCount = 0

    init(
        values: [ThreadReadingPosition] = [],
        capability: PersistenceCapability = .durable
    ) {
        self.values = values
        self.capability = capability
    }

    func load() throws -> [ThreadReadingPosition] {
        if corruptReadbackAfterReplace, replaceCallCount > 0 {
            return []
        }
        return values
    }

    func replaceAll(
        _ positions: [ThreadReadingPosition],
        beforeCommit: () throws -> Void
    ) throws {
        replaceCallCount += 1
        try beforeCommit()
        if let replaceError { throw replaceError }
        values = positions
    }

    func upsert(_ position: ThreadReadingPosition, limit: Int) throws {
        values = LocalThreadLibraryPolicy.addingReadingPosition(
            position,
            to: values,
            limit: limit
        )
    }

    func remove(threadID: Int64) throws {
        values.removeAll { $0.threadID == threadID }
    }

    func removeAll(beforeCommit: () throws -> Void) throws {
        try beforeCommit()
        values = []
    }

    func clearAll(beforeCommit: () throws -> Void) throws {
        try removeAll(beforeCommit: beforeCommit)
    }

    func backendGenerationID() throws -> String? {
        generationID
    }

    func establishNativeBackendMarker(generationID: String) throws {
        if let existing = self.generationID {
            guard existing == generationID else { throw ExpectedMarkerError.mismatch }
            return
        }
        self.generationID = generationID
    }

    func replaceAllForMigration(
        _ positions: [ThreadReadingPosition],
        generationID: String
    ) throws {
        try replaceAll(positions)
        self.generationID = generationID
    }

    private enum ExpectedMarkerError: Error {
        case mismatch
    }
}
