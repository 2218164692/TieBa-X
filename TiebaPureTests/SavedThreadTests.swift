import XCTest
@testable import TiebaPure

@MainActor
final class SavedThreadTests: XCTestCase {
    func testCaptureIncludesMainPostRepliesAndAllSubposts() async throws {
        let snapshot = try await SavedThreadCaptureService(api: FixtureTiebaAPI()).capture(
            account: nil,
            threadID: FixtureTiebaAPI.threads[0].id,
            forumID: FixtureTiebaAPI.forum.id,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(snapshot.mainPost?.post.id, 2_001)
        XCTAssertEqual(snapshot.posts.map(\.post.id), [2_001, 2_002])
        XCTAssertEqual(snapshot.replyCount, 1)
        XCTAssertEqual(snapshot.posts.first { $0.id == 2_002 }?.subposts.map(\.id), [3_001, 3_002])
        XCTAssertEqual(snapshot.subpostCount, 2)
    }

    func testStoreRoundTripsAndUpdatesExistingThreadAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let original = try await SavedThreadCaptureService(api: FixtureTiebaAPI()).capture(
            account: nil,
            threadID: FixtureTiebaAPI.threads[0].id,
            forumID: FixtureTiebaAPI.forum.id,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let store = SavedThreadStore(baseDirectoryURL: directory)
        try store.save(original)

        let reopened = SavedThreadStore(baseDirectoryURL: directory)
        XCTAssertEqual(reopened.entries, [original])

        var updated = original
        updated.savedAt = Date(timeIntervalSince1970: 1_800_000_100)
        updated.thread.title = "更新后的本地标题"
        try reopened.save(updated)

        let updatedStore = SavedThreadStore(baseDirectoryURL: directory)
        XCTAssertEqual(updatedStore.entries.count, 1)
        XCTAssertEqual(updatedStore.entries.first?.thread.title, "更新后的本地标题")
        XCTAssertEqual(updatedStore.entries.first?.savedAt, updated.savedAt)
    }

    func testIncompleteMainPostDoesNotProduceSnapshot() async {
        do {
            _ = try await SavedThreadCaptureService(api: FixtureTiebaAPI(scenario: .missingMain)).capture(
                account: nil,
                threadID: FixtureTiebaAPI.threads[0].id,
                forumID: FixtureTiebaAPI.forum.id
            )
            XCTFail("Expected incomplete thread failure")
        } catch let error as SavedThreadError {
            XCTAssertEqual(error, .incompleteThread)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
