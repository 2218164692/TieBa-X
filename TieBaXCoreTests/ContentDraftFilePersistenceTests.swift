import XCTest
@testable import TieBaX

final class ContentDraftFilePersistenceTests: XCTestCase {
    private enum InjectedFailure: Error {
        case beforeCatalogCommit
        case blobCleanup
    }

    private final class CancellationGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TieBaX-ContentDraftFileTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeTarget(threadID: Int64) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: .threadReply,
            forumID: 10,
            forumName: "fixture",
            forumDisplayName: "测试吧",
            threadID: threadID,
            threadTitle: "测试帖子",
            parentPostID: nil,
            parentFloor: nil,
            subpostID: nil,
            replyUserID: nil,
            replyUserDisplayName: nil
        )
    }

    private func makeImage(marker: UInt8, byteCount: Int = 3) -> ContentSubmissionImage {
        ContentSubmissionImage(
            data: Data(repeating: marker, count: byteCount),
            pixelWidth: 20,
            pixelHeight: 30,
            mimeType: "image/jpeg"
        )
    }

    private func makeDraft(
        accountID: String = "account",
        threadID: Int64,
        marker: UInt8,
        updatedAt: TimeInterval? = nil,
        imageByteCount: Int = 3
    ) -> ContentDraft {
        ContentDraft(
            accountID: accountID,
            target: makeTarget(threadID: threadID),
            title: "title-\(threadID)",
            body: "body-\(threadID)",
            images: [makeImage(marker: marker, byteCount: imageByteCount)],
            updatedAt: Date(timeIntervalSince1970: updatedAt ?? TimeInterval(threadID))
        )
    }

    private func blobURLs(in directory: URL) throws -> [URL] {
        let blobDirectory = directory.appendingPathComponent(
            "content-draft-blobs",
            isDirectory: true
        )
        return try FileManager.default.contentsOfDirectory(
            at: blobDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "tpdi" }
    }

    @MainActor
    func testCatalogAndRawTPDIBlobAreStoredSeparatelyWithSecureAttributes() throws {
        let directory = try makeDirectory()
        let backend = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let store = ContentDraftStore(persistence: backend)
        let draft = makeDraft(
            threadID: 1,
            marker: 0xa5,
            imageByteCount: 1_024 * 1_024
        )

        XCTAssertTrue(store.save(draft))

        let catalogURL = directory.appendingPathComponent("content-drafts-catalog.json")
        let blobs = try blobURLs(in: directory)
        let blobURL = try XCTUnwrap(blobs.first)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertLessThan(
            try Data(contentsOf: catalogURL).count,
            try Data(contentsOf: blobURL).count / 10
        )
        XCTAssertEqual(
            Data(try Data(contentsOf: blobURL).prefix(5)),
            Data([0x54, 0x50, 0x44, 0x49, 0x02])
        )

        for url in [catalogURL, blobURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(
                (attributes[.posixPermissions] as? NSNumber)?.intValue
            )
            XCTAssertEqual(permissions & 0o777, 0o600)
            // CoreSimulator does not expose NSFileProtectionKey on every host
            // filesystem. Verify it whenever the filesystem reports support.
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(protection, .complete)
            }
        }
    }

    @MainActor
    func testSeparateInstancesSerializeConcurrentCatalogUpdates() async throws {
        let directory = try makeDirectory()
        let first = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        let second = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        let firstDraft = makeDraft(threadID: 1, marker: 1)
        let secondDraft = makeDraft(threadID: 2, marker: 2)

        async let firstSave: Void = first.saveAsync(firstDraft)
        async let secondSave: Void = second.saveAsync(secondDraft)
        try await firstSave
        try await secondSave

        let reloaded = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        XCTAssertEqual(reloaded.draft(accountID: "account", target: firstDraft.target), firstDraft)
        XCTAssertEqual(reloaded.draft(accountID: "account", target: secondDraft.target), secondDraft)
        XCTAssertEqual(try blobURLs(in: directory).count, 2)
    }

    @MainActor
    func testCatalogCommitFailureKeepsPreviousDraftAndRemovesStagedBlob() throws {
        let directory = try makeDirectory()
        let stableBackend = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let stableStore = ContentDraftStore(persistence: stableBackend)
        let original = makeDraft(threadID: 1, marker: 1, updatedAt: 1)
        XCTAssertTrue(stableStore.save(original))

        let failingBackend = try FileContentDraftPersistenceBackend(
            directoryURL: directory,
            faultInjector: ContentDraftFilePersistenceFaultInjector { point in
                if case .beforeCatalogCommit = point {
                    throw InjectedFailure.beforeCatalogCommit
                }
            }
        )
        let replacement = makeDraft(threadID: 1, marker: 9, updatedAt: 9)
        XCTAssertFalse(ContentDraftStore(persistence: failingBackend).save(replacement))

        let reloaded = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        XCTAssertEqual(reloaded.draft(accountID: "account", target: original.target), original)
        XCTAssertEqual(try blobURLs(in: directory).count, 1)
    }

    @MainActor
    func testCleanupFailureAfterCatalogCommitDoesNotReportCommittedSaveAsFailed() throws {
        let directory = try makeDirectory()
        let stableStore = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        let original = makeDraft(threadID: 1, marker: 1, updatedAt: 1)
        XCTAssertTrue(stableStore.save(original))

        let backend = try FileContentDraftPersistenceBackend(
            directoryURL: directory,
            faultInjector: ContentDraftFilePersistenceFaultInjector { point in
                if case .beforeBlobCleanup = point {
                    throw InjectedFailure.blobCleanup
                }
            }
        )
        let replacement = makeDraft(threadID: 1, marker: 9, updatedAt: 9)
        XCTAssertTrue(ContentDraftStore(persistence: backend).save(replacement))

        let reloaded = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        XCTAssertEqual(reloaded.draft(accountID: "account", target: replacement.target), replacement)
        // The old orphan can remain until maintenance, but it must never make
        // the already committed replacement look like a failed mutation.
        XCTAssertEqual(try blobURLs(in: directory).count, 2)
    }

    @MainActor
    func testCancellationAfterBlobCommitDoesNotPublishDraftOrLeakBlob() async throws {
        let directory = try makeDirectory()
        let gate = CancellationGate()
        let backend = try FileContentDraftPersistenceBackend(
            directoryURL: directory,
            faultInjector: ContentDraftFilePersistenceFaultInjector { point in
                if case .beforeCatalogCommit = point {
                    gate.entered.signal()
                    gate.proceed.wait()
                    try Task.checkCancellation()
                }
            }
        )
        let store = ContentDraftStore(persistence: backend)
        let draft = makeDraft(threadID: 1, marker: 1)
        let task = Task { @MainActor in try await store.saveAsync(draft) }

        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: gate.entered.wait(timeout: .now() + 5))
            }
        }
        XCTAssertEqual(entered, .success)
        task.cancel()
        gate.proceed.signal()
        do {
            try await task.value
            XCTFail("Cancellation must be preserved")
        } catch is CancellationError {
            // Expected.
        }

        let reloaded = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        XCTAssertNil(reloaded.draft(accountID: "account", target: draft.target))
        XCTAssertTrue(try blobURLs(in: directory).isEmpty)
    }

    @MainActor
    func testCapacityPrunesOldestCatalogEntryAndItsBlob() throws {
        let directory = try makeDirectory()
        let store = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        for index in 0...ContentDraftPolicy.maximumDraftsPerAccount {
            XCTAssertTrue(store.save(makeDraft(
                threadID: Int64(index + 1),
                marker: UInt8(index % 200),
                updatedAt: TimeInterval(index)
            )))
        }

        XCTAssertNil(store.draft(accountID: "account", target: makeTarget(threadID: 1)))
        XCTAssertNotNil(store.draft(
            accountID: "account",
            target: makeTarget(threadID: Int64(ContentDraftPolicy.maximumDraftsPerAccount + 1))
        ))
        XCTAssertEqual(
            try blobURLs(in: directory).count,
            ContentDraftPolicy.maximumDraftsPerAccount
        )
    }

    @MainActor
    func testDamagedBlobIsReportedAndCanBeDeletedWithoutTouchingOtherDrafts() async throws {
        let directory = try makeDirectory()
        let store = ContentDraftStore(persistence: try FileContentDraftPersistenceBackend(
            directoryURL: directory
        ))
        let damaged = makeDraft(threadID: 1, marker: 1)
        let retained = makeDraft(threadID: 2, marker: 2)
        XCTAssertTrue(store.save(damaged))
        let damagedBlob = try XCTUnwrap(blobURLs(in: directory).first)
        XCTAssertTrue(store.save(retained))
        var bytes = try Data(contentsOf: damagedBlob)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xff
        try bytes.write(to: damagedBlob, options: [.atomic, .completeFileProtection])

        let damagedOutcome = await store.loadAsync(
            accountID: "account",
            target: damaged.target
        )
        XCTAssertEqual(damagedOutcome, .damaged(.attachmentContainer))
        XCTAssertTrue(store.delete(accountID: "account", target: damaged.target))
        XCTAssertEqual(store.draft(accountID: "account", target: retained.target), retained)
        XCTAssertEqual(try blobURLs(in: directory).count, 1)
    }

    @MainActor
    func testMigrationManifestContainsOnlyDigestsAndRecordsStreamIndividually() async throws {
        let directory = try makeDirectory()
        let backend = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let store = ContentDraftStore(persistence: backend)
        let draft = makeDraft(
            threadID: 1,
            marker: 0xa5,
            imageByteCount: 2 * 1_024 * 1_024
        )
        XCTAssertTrue(store.save(draft))

        let manifest = try await backend.migrationManifest()
        let entry = try XCTUnwrap(manifest.entries.first)
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(entry.identity, "account\u{1f}\(draft.target.draftKey)")
        XCTAssertEqual(entry.blobDigest.count, 64)
        XCTAssertEqual(entry.metadataDigest.count, 64)
        XCTAssertLessThan(try JSONEncoder().encode(manifest).count, 2_048)

        let record = try await backend.migrationRecord(identity: entry.identity)
        XCTAssertEqual(record.imagesByteCount, record.imagesBlob.count)
        XCTAssertGreaterThan(record.imagesBlob.count, 2 * 1_024 * 1_024)
    }

    @MainActor
    func testMigrationManifestDoesNotReadAttachmentBlob() async throws {
        let directory = try makeDirectory()
        let backend = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let draft = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(ContentDraftStore(persistence: backend).save(draft))
        let blobURL = try XCTUnwrap(blobURLs(in: directory).first)
        try FileManager.default.removeItem(at: blobURL)

        let manifest = try await backend.migrationManifest()
        XCTAssertEqual(manifest.entries.count, 1)
        do {
            _ = try await backend.migrationRecord(identity: manifest.entries[0].identity)
            XCTFail("The missing per-record blob must fail when that record is streamed")
        } catch {
            // Expected. The manifest remains metadata-only; the record read is
            // the first operation that touches the attachment container.
        }
    }

    func testPersistenceStateRejectsInvalidBackendStatusCombinations() throws {
        let generationID = "11111111-1111-1111-1111-111111111111"
        XCTAssertNoThrow(try ContentDraftPersistenceState.activeFiles.validated())
        XCTAssertNoThrow(try ContentDraftPersistenceState.initialSwiftData(
            generationID: generationID
        ).validated())
        XCTAssertNoThrow(try ContentDraftPersistenceState.nativeActivationPending(
            generationID: generationID
        ).validated())
        XCTAssertNoThrow(try ContentDraftPersistenceState.migrated(
            sourceFingerprint: String(repeating: "a", count: 64),
            generationID: generationID,
            completedAt: Date(timeIntervalSinceReferenceDate: 1)
        ).validated())
        XCTAssertThrowsError(try ContentDraftPersistenceState.initialSwiftData(
            generationID: "not-a-generation"
        ).validated())

        let invalid = ContentDraftPersistenceState(
            formatVersion: ContentDraftPersistenceState.currentFormatVersion,
            activeBackend: .secureFiles,
            migrationStatus: .completed,
            destinationGenerationID: generationID,
            receipt: ContentDraftMigrationReceipt(
                migrationVersion: ContentDraftMigrationReceipt.currentMigrationVersion,
                sourceFingerprint: String(repeating: "a", count: 64),
                completedAt: Date()
            )
        )
        XCTAssertThrowsError(try invalid.validated())
    }

    @MainActor
    func testIOS16ResolverFailsClosedForCorruptCatalogInsteadOfCreatingEmptyStore() throws {
        let directory = try makeDirectory()
        let catalogURL = directory.appendingPathComponent("content-drafts-catalog.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a catalog".utf8).write(to: catalogURL)

        XCTAssertThrowsError(try ContentDraftPersistenceFactory.resolveIOS16Backend(
            directoryURL: directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                ContentDraftPersistenceFactory.stateFileName
            ).path
        ))
    }

    @MainActor
    func testIOS16ResolverCommitsFileAuthorityBeforeReturningWritableBackend() throws {
        let directory = try makeDirectory()
        let backend = try ContentDraftPersistenceFactory.resolveIOS16Backend(
            directoryURL: directory
        )
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        XCTAssertEqual(try stateFile.load(), ContentDraftPersistenceState.activeFiles)

        let draft = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(backend.save(draft))
        let relaunched = try ContentDraftPersistenceFactory.resolveIOS16Backend(
            directoryURL: directory
        )
        XCTAssertEqual(relaunched.draft(accountID: "account", target: draft.target), draft)
    }
}
