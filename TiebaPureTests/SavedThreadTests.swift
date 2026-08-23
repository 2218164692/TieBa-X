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

    func testLegacyVersionOneSnapshotMigratesToTextOnly() async throws {
        var snapshot = try await SavedThreadCaptureService(api: FixtureTiebaAPI()).capture(
            account: nil,
            threadID: FixtureTiebaAPI.threads[0].id,
            forumID: FixtureTiebaAPI.forum.id
        )
        snapshot.formatVersion = 1
        snapshot.mediaMode = nil
        snapshot.mediaAssets = nil

        let decoded = try JSONDecoder().decode(
            SavedThreadSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        let migrated = try decoded.validated()

        XCTAssertEqual(migrated.formatVersion, SavedThreadSnapshot.currentFormatVersion)
        XCTAssertEqual(migrated.effectiveMediaMode, .textOnly)
        XCTAssertTrue(migrated.effectiveMediaAssets.isEmpty)
    }

    func testMediaImportCommitBackupAndRollbackAreIntegrityChecked() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        let originalData = Data("original offline payload".utf8)
        var original = try await capturedSnapshot()
        let originalAsset = mediaAsset(data: originalData, source: "voice:" + String(repeating: "a", count: 32))
        original.mediaMode = .complete
        original.mediaAssets = [originalAsset]
        let originalPrepared = try store.mediaStore.prepareImport(
            snapshot: original,
            files: [originalAsset.fileName: originalData]
        )
        try store.save(original, preparedMedia: originalPrepared)

        XCTAssertEqual(
            try store.mediaStore.backupFiles(for: original)[originalAsset.fileName],
            originalData
        )

        let replacementData = Data("replacement offline payload".utf8)
        var replacement = original
        let replacementAsset = mediaAsset(
            data: replacementData,
            source: "voice:" + String(repeating: "b", count: 32)
        )
        replacement.mediaAssets = [replacementAsset]
        let replacementPrepared = try store.mediaStore.prepareImport(
            snapshot: replacement,
            files: [replacementAsset.fileName: replacementData]
        )
        try replacementPrepared.commit()
        replacementPrepared.rollback()

        XCTAssertEqual(
            try store.mediaStore.backupFiles(for: original)[originalAsset.fileName],
            originalData,
            "回滚必须恢复此前已提交的离线媒体"
        )
    }

    func testStoreRepairsInterruptedMediaReplacementFromPersistedSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        let originalData = Data("persisted offline payload".utf8)
        var original = try await capturedSnapshot()
        let asset = mediaAsset(
            data: originalData,
            source: "voice:" + String(repeating: "1", count: 32)
        )
        original.mediaMode = .complete
        original.mediaAssets = [asset]
        let prepared = try store.mediaStore.prepareImport(
            snapshot: original,
            files: [asset.fileName: originalData]
        )
        try store.save(original, preparedMedia: prepared)

        let mediaRoot = savedThreadMediaRoot(in: directory)
        let final = mediaRoot.appendingPathComponent(String(original.id), isDirectory: true)
        let rollback = mediaRoot.appendingPathComponent(
            ".rollback-\(original.id)-interrupted",
            isDirectory: true
        )
        let abandonedStaging = mediaRoot.appendingPathComponent(
            ".staging-\(original.id)-interrupted",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: final, to: rollback)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
        try Data("uncommitted replacement".utf8).write(
            to: final.appendingPathComponent(asset.fileName)
        )
        try FileManager.default.createDirectory(
            at: abandonedStaging,
            withIntermediateDirectories: false
        )

        let reopened = SavedThreadStore(baseDirectoryURL: directory)

        XCTAssertEqual(
            try reopened.mediaStore.backupFiles(for: XCTUnwrap(reopened.entries.first))[asset.fileName],
            originalData
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollback.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedStaging.path))
    }

    func testStoreRepairsInterruptedFirstMediaCommitForTextOnlySnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        let snapshot = try await capturedSnapshot()
        try store.save(snapshot)

        let mediaRoot = savedThreadMediaRoot(in: directory)
        let final = mediaRoot.appendingPathComponent(String(snapshot.id), isDirectory: true)
        let rollback = mediaRoot.appendingPathComponent(
            ".rollback-\(snapshot.id)-interrupted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
        try Data("uncommitted media".utf8).write(
            to: final.appendingPathComponent("uncommitted.audio")
        )

        _ = SavedThreadStore(baseDirectoryURL: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollback.path))
    }

    func testValidationRejectsDuplicateFloorsAndCrossPostSubposts() async throws {
        let snapshot = try await capturedSnapshot()

        var duplicateFloor = snapshot
        var extraPost = try XCTUnwrap(duplicateFloor.posts.last)
        extraPost.post.id += 1_000
        duplicateFloor.posts.append(extraPost)
        XCTAssertThrowsError(try duplicateFloor.validated()) { error in
            XCTAssertEqual(error as? SavedThreadError, .inconsistentPagination)
        }

        var duplicateSubpost = snapshot
        let nested = try XCTUnwrap(duplicateSubpost.posts.last?.subposts.first)
        duplicateSubpost.posts[0].subposts.append(nested)
        XCTAssertThrowsError(try duplicateSubpost.validated()) { error in
            XCTAssertEqual(error as? SavedThreadError, .inconsistentPagination)
        }
    }

    func testMediaManifestRejectsPartiallyInvalidSourceIdentities() async throws {
        var snapshot = try await capturedSnapshot()
        let data = Data("payload".utf8)
        var asset = mediaAsset(data: data, source: "https://example.invalid/valid")
        asset.sourceIdentities.append("")
        snapshot.mediaMode = .complete
        snapshot.mediaAssets = [asset]

        XCTAssertThrowsError(try snapshot.validated()) { error in
            XCTAssertEqual(error as? SavedThreadError, .invalidMediaManifest)
        }
    }

    func testImportingTextOnlySnapshotRemovesPreviousMediaDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        let data = Data("offline payload".utf8)
        var snapshot = try await capturedSnapshot()
        let asset = mediaAsset(
            data: data,
            source: "voice:" + String(repeating: "2", count: 32)
        )
        snapshot.mediaMode = .complete
        snapshot.mediaAssets = [asset]
        let prepared = try store.mediaStore.prepareImport(
            snapshot: snapshot,
            files: [asset.fileName: data]
        )
        try store.save(snapshot, preparedMedia: prepared)

        var textOnly = snapshot
        textOnly.savedAt = snapshot.savedAt.addingTimeInterval(1)
        textOnly.mediaMode = .textOnly
        textOnly.mediaAssets = []
        try await store.importBackupWithoutBlocking(
            snapshots: [textOnly],
            mediaFiles: [textOnly.id: [:]],
            replacingExisting: true
        )

        let final = savedThreadMediaRoot(in: directory)
            .appendingPathComponent(String(snapshot.id), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    }

    func testRejectedAsyncSaveDiscardsPreparedStagingDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        var snapshot = try await capturedSnapshot()
        let prepared = try store.mediaStore.prepareImport(snapshot: snapshot, files: [:])
        snapshot.thread.id = 0

        do {
            try await store.saveWithoutBlocking(snapshot, preparedMedia: prepared)
            XCTFail("无效快照不应提交")
        } catch {
            XCTAssertEqual(error as? SavedThreadError, .incompleteThread)
        }

        let mediaRoot = savedThreadMediaRoot(in: directory)
        let children = try FileManager.default.contentsOfDirectory(
            at: mediaRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(children.contains { $0.lastPathComponent.hasPrefix(".staging-") })
    }

    func testBackupImportAndUpdateCountRoundTrip() async throws {
        let sourceDirectory = try makeTemporaryDirectory()
        let destinationDirectory = try makeTemporaryDirectory()
        let sourceStore = SavedThreadStore(baseDirectoryURL: sourceDirectory)
        let destinationStore = SavedThreadStore(baseDirectoryURL: destinationDirectory)
        let data = Data("portable payload".utf8)
        var snapshot = try await capturedSnapshot()
        let asset = mediaAsset(data: data, source: "voice:" + String(repeating: "c", count: 32))
        snapshot.mediaMode = .complete
        snapshot.mediaAssets = [asset]
        let prepared = try sourceStore.mediaStore.prepareImport(
            snapshot: snapshot,
            files: [asset.fileName: data]
        )
        try sourceStore.save(snapshot, preparedMedia: prepared)

        try await destinationStore.importBackupWithoutBlocking(
            snapshots: sourceStore.entries,
            mediaFiles: [snapshot.id: try sourceStore.mediaStore.backupFiles(for: snapshot)],
            replacingExisting: true
        )
        try destinationStore.recordUpdateCheck(
            threadID: snapshot.id,
            latestReplyCount: snapshot.thread.replyCount + 7,
            checkedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        XCTAssertEqual(destinationStore.entries.first?.newReplyCount, 7)
        XCTAssertEqual(
            try destinationStore.mediaStore.backupFiles(for: destinationStore.entries[0])[asset.fileName],
            data
        )
    }

    func testMergingOlderBackupKeepsNewerSnapshotAndItsMedia() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        let currentData = Data("current offline payload".utf8)
        var current = try await capturedSnapshot()
        current.savedAt = Date(timeIntervalSince1970: 1_800_000_100)
        current.thread.title = "本机较新版本"
        let currentAsset = mediaAsset(
            data: currentData,
            source: "voice:" + String(repeating: "f", count: 32)
        )
        current.mediaMode = .complete
        current.mediaAssets = [currentAsset]
        let currentPrepared = try store.mediaStore.prepareImport(
            snapshot: current,
            files: [currentAsset.fileName: currentData]
        )
        try store.save(current, preparedMedia: currentPrepared)

        let olderData = Data("older backup payload".utf8)
        var older = current
        older.savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        older.thread.title = "备份中的旧版本"
        let olderAsset = mediaAsset(
            data: olderData,
            source: "voice:" + String(repeating: "0", count: 32)
        )
        older.mediaAssets = [olderAsset]

        try await store.importBackupWithoutBlocking(
            snapshots: [older],
            mediaFiles: [older.id: [olderAsset.fileName: olderData]],
            replacingExisting: false
        )

        XCTAssertEqual(store.entries.first?.thread.title, "本机较新版本")
        XCTAssertEqual(store.entries.first?.effectiveMediaAssets, [currentAsset])
        XCTAssertEqual(
            try store.mediaStore.backupFiles(for: store.entries[0])[currentAsset.fileName],
            currentData
        )
    }

    func testMediaManifestRejectsTraversalAndDigestConflicts() async throws {
        var snapshot = try await capturedSnapshot()
        let data = Data("payload".utf8)
        var invalid = mediaAsset(data: data, source: "https://example.invalid/a")
        invalid.fileName = "../outside.bin"
        snapshot.mediaMode = .complete
        snapshot.mediaAssets = [invalid]
        XCTAssertThrowsError(try snapshot.validated()) { error in
            XCTAssertEqual(error as? SavedThreadError, .invalidMediaManifest)
        }
    }

    func testBackupRejectsOversizedMediaBeforeReadingFiles() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        var snapshot = try await capturedSnapshot()
        snapshot.mediaMode = .complete
        snapshot.mediaAssets = [SavedThreadMediaAsset(
            sourceIdentities: ["voice:" + String(repeating: "d", count: 32)],
            kind: .audio,
            fileName: String(repeating: "a", count: 64) + ".audio",
            byteCount: SavedThreadPolicy.maximumBackupBytes + 1,
            sha256: String(repeating: "a", count: 64)
        )]

        XCTAssertThrowsError(
            try SavedThreadBackupDocument(snapshots: [snapshot], mediaStore: store.mediaStore)
        ) { error in
            XCTAssertEqual(error as? SavedThreadError, .backupStorageLimitExceeded)
        }
    }

    func testBackupPreflightCountsHiddenFiles() throws {
        let directory = try makeTemporaryDirectory()
        let package = directory.appendingPathComponent("oversized.tiebapurebackup", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let hiddenFile = package.appendingPathComponent(".oversized")
        XCTAssertTrue(FileManager.default.createFile(atPath: hiddenFile.path, contents: nil))
        let handle = try FileHandle(forWritingTo: hiddenFile)
        try handle.truncate(atOffset: UInt64(SavedThreadPolicy.maximumBackupBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try SavedThreadBackupDocument.load(from: package)) { error in
            XCTAssertEqual(error as? SavedThreadError, .backupStorageLimitExceeded)
        }
    }

    func testBackupRejectsUnexpectedPackageEntriesAndDuplicateSnapshots() async throws {
        let snapshot = try await capturedSnapshot()
        let manifest = TestBackupManifest(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1_900_000_000),
            snapshots: [snapshot]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let validMedia = FileWrapper(directoryWithFileWrappers: [
            String(snapshot.id): FileWrapper(directoryWithFileWrappers: [:])
        ])
        let unexpectedRoot = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: manifestData),
            "Media": validMedia,
            ".unexpected": FileWrapper(regularFileWithContents: Data())
        ])
        XCTAssertThrowsError(try SavedThreadBackupDocument(fileWrapper: unexpectedRoot)) { error in
            XCTAssertEqual(error as? SavedThreadError, .invalidBackup)
        }

        let duplicateManifest = TestBackupManifest(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1_900_000_000),
            snapshots: [snapshot, snapshot]
        )
        let duplicateRoot = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(
                regularFileWithContents: try JSONEncoder().encode(duplicateManifest)
            ),
            "Media": validMedia
        ])
        XCTAssertThrowsError(try SavedThreadBackupDocument(fileWrapper: duplicateRoot)) { error in
            XCTAssertEqual(error as? SavedThreadError, .invalidBackup)
        }
    }

    func testSavingTextOnlyRemovesPreviouslyCommittedMedia() async throws {
        let directory = try makeTemporaryDirectory()
        let store = SavedThreadStore(baseDirectoryURL: directory)
        let data = Data("offline payload to remove".utf8)
        var snapshot = try await capturedSnapshot()
        let asset = mediaAsset(
            data: data,
            source: "voice:" + String(repeating: "e", count: 32)
        )
        snapshot.mediaMode = .complete
        snapshot.mediaAssets = [asset]
        let prepared = try store.mediaStore.prepareImport(
            snapshot: snapshot,
            files: [asset.fileName: data]
        )
        try store.save(snapshot, preparedMedia: prepared)

        snapshot.mediaMode = .textOnly
        snapshot.mediaAssets = []
        try store.save(snapshot)

        XCTAssertThrowsError(try store.mediaStore.backupFiles(for: snapshotWithAsset(
            snapshot,
            asset: asset
        )))
    }

    private func capturedSnapshot() async throws -> SavedThreadSnapshot {
        try await SavedThreadCaptureService(api: FixtureTiebaAPI()).capture(
            account: nil,
            threadID: FixtureTiebaAPI.threads[0].id,
            forumID: FixtureTiebaAPI.forum.id,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func mediaAsset(data: Data, source: String) -> SavedThreadMediaAsset {
        let digest = SecurePersistenceDigest.sha256(data)
        return SavedThreadMediaAsset(
            sourceIdentities: [source],
            kind: .audio,
            fileName: digest + ".audio",
            byteCount: data.count,
            sha256: digest
        )
    }

    private func snapshotWithAsset(
        _ snapshot: SavedThreadSnapshot,
        asset: SavedThreadMediaAsset
    ) -> SavedThreadSnapshot {
        var result = snapshot
        result.mediaMode = .complete
        result.mediaAssets = [asset]
        return result
    }

    private func savedThreadMediaRoot(in baseDirectory: URL) -> URL {
        baseDirectory
            .appendingPathComponent("TiebaPure", isDirectory: true)
            .appendingPathComponent("Persistence", isDirectory: true)
            .appendingPathComponent(SecurePersistenceLocation.currentDirectoryName, isDirectory: true)
            .appendingPathComponent("saved-thread-media", isDirectory: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private struct TestBackupManifest: Encodable {
        var formatVersion: Int
        var exportedAt: Date
        var snapshots: [SavedThreadSnapshot]
    }
}
