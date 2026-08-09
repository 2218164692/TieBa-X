import SwiftData
import XCTest
@testable import TiebaPure

final class SwiftDataOrderedCollectionPersistenceTests: XCTestCase {
    private enum InjectedFailure: Error {
        case beforeCommit
    }

    @MainActor
    func testAdaptersShareContainerWithoutOverwritingOtherTablesAndPreserveOrder() throws {
        let container = try makeInMemoryModelContainer()
        let browsing = SwiftDataBrowsingHistoryPersistence(modelContainer: container)
        let recent = SwiftDataRecentForumPersistence(modelContainer: container)
        let search = SwiftDataSearchHistoryPersistence(modelContainer: container)

        let browsingEntries = [
            makeBrowsingEntry(threadID: 2, visitedAt: 2),
            makeBrowsingEntry(threadID: 1, visitedAt: 1)
        ]
        let recentEntries = [
            makeRecentForum(name: "second", updatedAt: 2),
            makeRecentForum(name: "first", updatedAt: 1)
        ]
        let searchEntries = ["second", "first"]

        try browsing.replaceAll(browsingEntries)
        try recent.replaceAll(recentEntries)
        try search.replaceAll(searchEntries)

        let reopenedBrowsing = SwiftDataBrowsingHistoryPersistence(modelContainer: container)
        let reopenedRecent = SwiftDataRecentForumPersistence(modelContainer: container)
        let reopenedSearch = SwiftDataSearchHistoryPersistence(modelContainer: container)

        XCTAssertEqual(try reopenedBrowsing.load(), browsingEntries)
        XCTAssertEqual(try reopenedRecent.load(), recentEntries)
        XCTAssertEqual(try reopenedSearch.load(), searchEntries)
    }

    @MainActor
    func testBrowsingAsyncExecutorCommitIsVisibleToFreshLoader() async throws {
        let container = try makeInMemoryModelContainer()
        let writer = SwiftDataBrowsingHistoryPersistence(modelContainer: container)
        let first = makeBrowsingEntry(threadID: 1, visitedAt: 1)
        let second = makeBrowsingEntry(threadID: 2, visitedAt: 2)

        _ = try await writer.upsert(first, limit: 10)
        let committed = try await writer.upsert(second, limit: 10)
        XCTAssertEqual(committed.map(\.threadID), [2, 1])

        let loader = SwiftDataBrowsingHistoryPersistence(modelContainer: container)
        XCTAssertEqual(try loader.load().map(\.threadID), [2, 1])
    }

    @MainActor
    func testBeforeCommitFailureRollsBackEveryAdapter() throws {
        let container = try makeInMemoryModelContainer()
        let browsing = SwiftDataBrowsingHistoryPersistence(modelContainer: container)
        let recent = SwiftDataRecentForumPersistence(modelContainer: container)
        let search = SwiftDataSearchHistoryPersistence(modelContainer: container)

        let originalBrowsing = [makeBrowsingEntry(threadID: 1, visitedAt: 1)]
        let originalRecent = [makeRecentForum(name: "first", updatedAt: 1)]
        let originalSearch = ["first"]
        try browsing.replaceAll(originalBrowsing)
        try recent.replaceAll(originalRecent)
        try search.replaceAll(originalSearch)

        XCTAssertThrowsError(
            try browsing.replaceAll([makeBrowsingEntry(threadID: 2, visitedAt: 2)]) {
                throw InjectedFailure.beforeCommit
            }
        )
        XCTAssertThrowsError(
            try recent.replaceAll([makeRecentForum(name: "second", updatedAt: 2)]) {
                throw InjectedFailure.beforeCommit
            }
        )
        XCTAssertThrowsError(
            try search.replaceAll(["second"]) {
                throw InjectedFailure.beforeCommit
            }
        )

        XCTAssertEqual(try browsing.load(), originalBrowsing)
        XCTAssertEqual(try recent.load(), originalRecent)
        XCTAssertEqual(try search.load(), originalSearch)
    }

    func testAppSchemaStillIncludesEveryOrderedCollectionRecordType() {
        let identifiers = Set(AppModelContainer.models.map(ObjectIdentifier.init))

        XCTAssertTrue(identifiers.contains(ObjectIdentifier(BrowsingHistoryRecord.self)))
        XCTAssertTrue(identifiers.contains(ObjectIdentifier(RecentForumRecord.self)))
        XCTAssertTrue(identifiers.contains(ObjectIdentifier(SearchHistoryRecord.self)))
    }

    @MainActor
    func testWritableMemoryFallbackIsClassifiedAsFallbackInsteadOfDurable() throws {
        let container = try makeInMemoryModelContainer()

        XCTAssertEqual(
            SwiftDataBrowsingHistoryPersistence(
                modelContainer: container,
                persistenceAvailability: .unavailable
            ).capability,
            .fallback
        )
        XCTAssertEqual(
            SwiftDataRecentForumPersistence(
                modelContainer: container,
                persistenceAvailability: .unavailable
            ).capability,
            .fallback
        )
        XCTAssertEqual(
            SwiftDataSearchHistoryPersistence(
                modelContainer: container,
                persistenceAvailability: .unavailable
            ).capability,
            .fallback
        )
    }

    @MainActor
    private func makeInMemoryModelContainer() throws -> ModelContainer {
        let schema = Schema(AppModelContainer.models)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        )
    }

    private func makeBrowsingEntry(
        threadID: Int64,
        visitedAt: TimeInterval
    ) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(
            threadID: threadID,
            title: "thread-\(threadID)",
            authorDisplayName: "author-\(threadID)",
            visitedAt: Date(timeIntervalSince1970: visitedAt)
        )
    }

    private func makeRecentForum(
        name: String,
        updatedAt: TimeInterval
    ) -> RecentForum {
        RecentForum(
            name: name,
            displayName: "\(name)吧",
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
