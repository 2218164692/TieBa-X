import Combine
import SwiftData
import XCTest
@testable import TiebaPure

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
    func testLocalThreadLibraryPersistsFavoritesAndReadingPositions() throws {
        XCTAssertEqual(LocalThreadLibraryPolicy.maximumFavoriteEntries, 500)
        XCTAssertEqual(LocalThreadLibraryPolicy.maximumReadingPositions, 500)
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        var tick: TimeInterval = 0
        let store = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            favoriteLimit: 2,
            readingPositionLimit: 2,
            modelContainer: container
        ) {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
        let author = UserSummary(
            id: 1,
            name: "author",
            displayName: "收藏作者",
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
        func thread(id: Int64, title: String) -> ThreadSummary {
            ThreadSummary(
                id: id,
                forumID: forum.id,
                title: title,
                author: author,
                forumName: forum.name,
                replyCount: 0,
                viewCount: 0,
                blocks: []
            )
        }

        store.addFavorite(thread: thread(id: 1, title: "第一条"), forum: forum)
        store.addFavorite(thread: thread(id: 2, title: "第二条"), forum: forum)
        store.addFavorite(thread: thread(id: 1, title: "更新后的第一条"), forum: forum)
        store.addFavorite(thread: thread(id: 3, title: "第三条"), forum: forum)
        store.addFavorite(thread: thread(id: 0, title: "无效帖子"), forum: forum)

        XCTAssertEqual(store.favorites.map(\.threadID), [3, 1])
        XCTAssertEqual(store.favorites.last?.title, "更新后的第一条")
        XCTAssertTrue(store.isFavorite(threadID: 3))
        XCTAssertFalse(store.toggleFavorite(thread: thread(id: 3, title: "第三条"), forum: forum))
        XCTAssertEqual(store.favorites.map(\.threadID), [1])

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
            favoriteLimit: 2,
            readingPositionLimit: 2,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.favorites, store.favorites)
        XCTAssertEqual(reloaded.readingPositions, store.readingPositions)

        reloaded.clearReadingPosition(threadID: 1)
        XCTAssertNil(reloaded.position(for: 1))
        reloaded.clearReadingPositions()
        XCTAssertTrue(reloaded.readingPositions.isEmpty)
        XCTAssertFalse(reloaded.favorites.isEmpty)

        reloaded.recordReadingPosition(threadID: 1, postID: 1006, floor: 6)
        reloaded.clearAll()
        XCTAssertTrue(reloaded.favorites.isEmpty)
        XCTAssertTrue(reloaded.readingPositions.isEmpty)

        let cleared = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            favoriteLimit: 2,
            readingPositionLimit: 2,
            modelContainer: container
        )
        XCTAssertTrue(cleared.favorites.isEmpty)
        XCTAssertTrue(cleared.readingPositions.isEmpty)
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
            favoriteLimit: 3,
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
            favoriteLimit: 3,
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
        let favoritesJSON = #"[{"threadID":1,"title":"第一条","authorDisplayName":"作者","savedAt":2},"corrupt",{"threadID":2,"title":"第二条","authorDisplayName":"作者","savedAt":1}]"#
        let positionsJSON = #"[{"threadID":1,"postID":1001,"floor":2,"updatedAt":2},{"threadID":"corrupt"},{"threadID":2,"postID":2001,"floor":3,"updatedAt":1}]"#
        defaults.set(Data(favoritesJSON.utf8), forKey: "favorites")
        defaults.set(Data(positionsJSON.utf8), forKey: "positions")

        let store = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            favoriteLimit: 10,
            readingPositionLimit: 10,
            modelContainer: container
        )

        XCTAssertEqual(store.favorites.map(\.threadID), [1, 2])
        XCTAssertEqual(store.readingPositions.map(\.threadID), [1, 2])
        XCTAssertEqual(store.position(for: 1)?.postID, 1001)
        XCTAssertNil(defaults.object(forKey: "favorites"))
        XCTAssertNil(defaults.object(forKey: "positions"))

        defaults.set(Data(favoritesJSON.utf8), forKey: "favorites")
        defaults.set(Data(positionsJSON.utf8), forKey: "positions")
        let reloaded = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "favorites",
            readingPositionsKey: "positions",
            favoriteLimit: 10,
            readingPositionLimit: 10,
            modelContainer: container
        )
        XCTAssertEqual(reloaded.favorites.map(\.threadID), [1, 2])
        XCTAssertEqual(reloaded.readingPositions.map(\.threadID), [1, 2])
        XCTAssertNil(defaults.object(forKey: "favorites"))
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
        XCTAssertFalse(library.addFavorite(thread: thread))
        XCTAssertFalse(library.recordReadingPosition(threadID: 10, postID: 100, floor: 1))
        XCTAssertTrue(library.favorites.isEmpty)
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
    func testClearAllRollsBackFavoritesAndReadingPositionsTogether() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try makeScratchDefaults()
        let author = UserSummary(
            id: 1,
            name: "author",
            displayName: "作者",
            portrait: ""
        )
        let thread = ThreadSummary(
            id: 21,
            forumID: 31,
            title: "原子清理",
            author: author,
            forumName: "测试",
            replyCount: 0,
            viewCount: 0,
            blocks: []
        )
        let initial = LocalThreadLibraryStore(
            defaults: defaults,
            favoritesKey: "atomic-favorites",
            readingPositionsKey: "atomic-positions",
            modelContainer: container
        )
        XCTAssertTrue(initial.addFavorite(thread: thread))
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
        XCTAssertEqual(failing.favorites.map(\.threadID), [21])
        XCTAssertEqual(failing.readingPositions.map(\.threadID), [21])
        XCTAssertEqual(failing.persistenceAvailability, .unavailable)
        XCTAssertEqual(try container.mainContext.fetchCount(
            FetchDescriptor<ThreadFavoriteRecord>()
        ), 1)
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

        let favoritesLegacy = [
            ThreadFavoriteEntry(
                threadID: 1,
                title: "旧收藏",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            ThreadFavoriteEntry(
                threadID: 2,
                title: "第二条",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
            ThreadFavoriteEntry(
                threadID: 1,
                title: "新收藏",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            ThreadFavoriteEntry(
                threadID: 0,
                title: "无效",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 4)
            )
        ]
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
        defaults.set(try JSONEncoder().encode(favoritesLegacy), forKey: "clean-favorites")
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
            favoriteLimit: 2,
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
        XCTAssertEqual(library.favorites.map(\.threadID), [1, 2])
        XCTAssertEqual(library.favorites.first?.title, "新收藏")
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
            try container.mainContext.fetchCount(FetchDescriptor<ThreadFavoriteRecord>()),
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

        let favoriteRows = [
            ThreadFavoriteEntry(
                threadID: 1,
                title: "旧",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            ThreadFavoriteEntry(
                threadID: 1,
                title: "新",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            ThreadFavoriteEntry(
                threadID: 0,
                title: "无效",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 4)
            ),
            ThreadFavoriteEntry(
                threadID: 2,
                title: "第二条",
                authorDisplayName: "作者",
                savedAt: Date(timeIntervalSinceReferenceDate: 2)
            )
        ]
        try PersistedRecordStore.replaceAll(
            ThreadFavoriteRecord.self,
            with: favoriteRows.enumerated().map {
                ThreadFavoriteRecord(entry: $0.element, sortIndex: $0.offset)
            },
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
            favoriteLimit: 2,
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
        XCTAssertEqual(library.favorites.map(\.threadID), [1, 2])
        XCTAssertEqual(library.readingPositions.map(\.threadID), [1, 2])
        XCTAssertEqual(search.items, ["first", "second"])
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<BrowsingHistoryRecord>()),
            2
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecentForumRecord>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ThreadFavoriteRecord>()), 2)
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
        let manyFavorites = manyHistories.map {
            ThreadFavoriteEntry(
                threadID: $0.threadID,
                title: $0.title,
                authorDisplayName: $0.authorDisplayName,
                savedAt: $0.visitedAt
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
            LocalThreadLibraryPolicy.sanitizedFavorites(
                manyFavorites,
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

    func testThreadReadingViewportPolicyRecordsBottomMostVisibleReply() {
        let mainPostID: UInt64 = 2001
        let entries = [
            ThreadPostViewportEntry(postID: 2001, floor: 1, minY: -240, maxY: 80),
            ThreadPostViewportEntry(postID: 2002, floor: 0, minY: 80, maxY: 240),
            ThreadPostViewportEntry(postID: 2003, floor: 0, minY: 240, maxY: 400),
            // Prefetched below the viewport; must not be recorded.
            ThreadPostViewportEntry(postID: 2004, floor: 0, minY: 700, maxY: 900)
        ]

        XCTAssertNil(ThreadReadingViewportPolicy.position(
            entries: entries,
            scrollDistanceFromTop: 20,
            viewportHeight: 600,
            excludedPostID: mainPostID
        ))
        // Floors are absent under hot sort (floor == 0); the bottom-most
        // visible reply is still recorded by post ID.
        XCTAssertEqual(
            ThreadReadingViewportPolicy.position(
                entries: entries,
                scrollDistanceFromTop: 240,
                viewportHeight: 600,
                excludedPostID: mainPostID
            )?.postID,
            2003
        )
        // A long main post alone never records a position of its own.
        XCTAssertNil(ThreadReadingViewportPolicy.position(
            entries: [ThreadPostViewportEntry(postID: 2001, floor: 1, minY: 0, maxY: 200)],
            scrollDistanceFromTop: 100,
            viewportHeight: 600,
            excludedPostID: mainPostID
        ))
        XCTAssertNil(ThreadReadingViewportPolicy.position(
            entries: entries,
            scrollDistanceFromTop: 240,
            viewportHeight: 0,
            excludedPostID: mainPostID
        ))
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
}
