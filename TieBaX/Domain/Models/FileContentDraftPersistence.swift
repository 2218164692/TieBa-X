import Foundation

enum FileContentDraftPersistenceError: Error, Equatable {
    case unsupportedCatalogVersion(Int)
    case invalidCatalog
    case invalidAccountID
    case pathIsSymbolicLink
    case pathIsNotRegularFile
    case pathIsNotDirectory
    case attachmentTooLarge
}

struct ContentDraftFilePersistenceFaultInjector: Sendable {
    enum Point: Sendable {
        case beforeBlobCommit
        case beforeCatalogCommit
        case beforeBlobCleanup
    }

    static let none = ContentDraftFilePersistenceFaultInjector { _ in }

    let check: @Sendable (Point) throws -> Void
}

private struct ContentDraftFileCatalog: Codable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var entries: [ContentDraftFileCatalogEntry]

    static var empty: ContentDraftFileCatalog {
        ContentDraftFileCatalog(formatVersion: currentFormatVersion, entries: [])
    }
}

private struct ContentDraftFileCatalogEntry: Codable, Sendable {
    let recordID: String
    let accountID: String
    let targetKey: String
    let targetData: Data
    let title: String
    let body: String
    let blobFileName: String
    let imagesByteCount: Int
    let updatedAt: Date
    let metadataDigest: String
    let blobDigest: String

    var identity: String {
        "\(accountID)\u{1f}\(targetKey)"
    }

    var migrationManifestEntry: ContentDraftMigrationManifestEntry {
        ContentDraftMigrationManifestEntry(
            identity: identity,
            accountID: accountID,
            targetKey: targetKey,
            updatedAt: updatedAt,
            imagesByteCount: imagesByteCount,
            metadataDigest: metadataDigest,
            blobDigest: blobDigest
        )
    }
}

enum ContentDraftFileCatalogPresence: Equatable, Sendable {
    case absent
    case empty
    case containsDrafts
}

private final class ContentDraftFileSharedState: @unchecked Sendable {
    let lock = NSRecursiveLock()
}

private final class ContentDraftFileStateRegistry: @unchecked Sendable {
    static let shared = ContentDraftFileStateRegistry()

    private let lock = NSLock()
    private var states: [String: ContentDraftFileSharedState] = [:]

    func state(for standardizedPath: String) -> ContentDraftFileSharedState {
        lock.lock()
        defer { lock.unlock() }
        if let state = states[standardizedPath] { return state }
        let state = ContentDraftFileSharedState()
        states[standardizedPath] = state
        return state
    }
}

private final class ContentDraftFileStorage: @unchecked Sendable {
    static let catalogFileName = "content-drafts-catalog.json"
    static let blobDirectoryName = "content-draft-blobs"

    private let directoryURL: URL
    private let blobDirectoryURL: URL
    private let fileManager: FileManager
    private let catalogFile: SecureCodableFile<ContentDraftFileCatalog>
    private let sharedState: ContentDraftFileSharedState
    private let faultInjector: ContentDraftFilePersistenceFaultInjector

    init(
        directoryURL: URL,
        fileManager: FileManager,
        faultInjector: ContentDraftFilePersistenceFaultInjector
    ) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.faultInjector = faultInjector
        blobDirectoryURL = directoryURL.appendingPathComponent(
            Self.blobDirectoryName,
            isDirectory: true
        )
        catalogFile = try SecureCodableFile(
            directoryURL: directoryURL,
            fileName: Self.catalogFileName,
            fileManager: fileManager,
            maximumByteCount: 32 * 1_024 * 1_024
        )
        sharedState = ContentDraftFileStateRegistry.shared.state(
            for: catalogFile.fileURL.standardizedFileURL.path
        )
        try Self.prepareDirectory(blobDirectoryURL, fileManager: fileManager)
    }

    func catalogPresence() throws -> ContentDraftFileCatalogPresence {
        try withLock {
            let hasCatalogArtifact = fileManager.fileExists(atPath: catalogFile.fileURL.path)
                || fileManager.fileExists(atPath: catalogFile.backupURL.path)
            guard hasCatalogArtifact else { return .absent }
            return try loadCatalog().entries.isEmpty ? .empty : .containsDrafts
        }
    }

    func load(accountID: String, target: ContentSubmissionTarget) throws -> ContentDraftLoadOutcome {
        try withLock {
            let normalizedAccountID = try Self.normalizedAccountID(accountID)
            let catalog = try loadCatalog()
            let matches = catalog.entries.filter {
                $0.accountID == normalizedAccountID && $0.targetKey == target.draftKey
            }
            guard let entry = preferredEntry(in: matches) else { return .loaded(nil) }
            guard let storedTarget = try? JSONDecoder().decode(
                ContentSubmissionTarget.self,
                from: entry.targetData
            ), storedTarget.draftKey == entry.targetKey else {
                return .damaged(.targetMetadata)
            }
            guard let blob = try readBlobIfValid(entry.blobFileName) else {
                return .damaged(.attachmentContainer)
            }
            guard blob.count == entry.imagesByteCount,
                  SecurePersistenceDigest.sha256(blob) == entry.blobDigest else {
                return .damaged(.attachmentContainer)
            }
            let images: [ContentSubmissionImage]
            switch ContentDraftImageBlobCodec.decodeWithIntegrity(blob) {
            case let .decoded(decoded):
                images = decoded
            case .damagedContainer:
                return .damaged(.attachmentContainer)
            case .cancelled:
                throw CancellationError()
            }
            return .loaded(ContentDraft(
                accountID: normalizedAccountID,
                target: storedTarget,
                title: entry.title,
                body: entry.body,
                images: images,
                updatedAt: entry.updatedAt
            ))
        }
    }

    func save(_ draft: ContentDraft) throws {
        let accountID = try Self.normalizedAccountID(draft.accountID)
        let targetData = try JSONEncoder().encode(draft.target)
        let imagesBlob = try ContentDraftImageBlobCodec.encode(draft.images)
        guard imagesBlob.count <= ContentDraftPolicy.maximumAttachmentBytesPerDraft else {
            throw FileContentDraftPersistenceError.attachmentTooLarge
        }

        try withLock {
            try Task.checkCancellation()
            let oldCatalog = try loadCatalog()
            let record = try ContentDraftPersistenceRecord(
                accountID: accountID,
                targetKey: draft.target.draftKey,
                targetData: targetData,
                title: draft.title,
                body: draft.body,
                imagesBlob: imagesBlob,
                imagesByteCount: imagesBlob.count,
                updatedAt: draft.updatedAt
            ).validated()
            let manifestEntry = try ContentDraftMigrationManifestEntry(record: record)
            let recordID = UUID().uuidString.lowercased()
            let blobFileName = Self.blobFileName(recordID: recordID)
            var blobWasCommitted = false
            var catalogWasCommitted = false
            do {
                try writeBlob(imagesBlob, fileName: blobFileName)
                blobWasCommitted = true
                var updatedEntries = oldCatalog.entries.filter {
                    $0.accountID != accountID || $0.targetKey != draft.target.draftKey
                }
                updatedEntries.append(ContentDraftFileCatalogEntry(
                    recordID: recordID,
                    accountID: accountID,
                    targetKey: draft.target.draftKey,
                    targetData: targetData,
                    title: draft.title,
                    body: draft.body,
                    blobFileName: blobFileName,
                    imagesByteCount: imagesBlob.count,
                    updatedAt: draft.updatedAt,
                    metadataDigest: manifestEntry.metadataDigest,
                    blobDigest: manifestEntry.blobDigest
                ))
                updatedEntries = pruned(updatedEntries)
                let updatedCatalog = ContentDraftFileCatalog(
                    formatVersion: ContentDraftFileCatalog.currentFormatVersion,
                    entries: updatedEntries
                )
                try catalogFile.replace(updatedCatalog) {
                    try Task.checkCancellation()
                    try faultInjector.check(.beforeCatalogCommit)
                }
                catalogWasCommitted = true
                cleanupBestEffort(referencedBy: updatedCatalog)
            } catch {
                if blobWasCommitted, catalogWasCommitted == false {
                    try? removeRegularFileIfPresent(blobURL(fileName: blobFileName))
                }
                throw error
            }
        }
    }

    func delete(accountID: String, target: ContentSubmissionTarget) throws {
        try withLock {
            let normalizedAccountID = try Self.normalizedAccountID(accountID)
            let oldCatalog = try loadCatalog()
            let retained = oldCatalog.entries.filter {
                $0.accountID != normalizedAccountID || $0.targetKey != target.draftKey
            }
            guard retained.count != oldCatalog.entries.count else { return }
            let updated = ContentDraftFileCatalog(
                formatVersion: ContentDraftFileCatalog.currentFormatVersion,
                entries: retained
            )
            try catalogFile.replace(updated) {
                try Task.checkCancellation()
                try faultInjector.check(.beforeCatalogCommit)
            }
            cleanupBestEffort(referencedBy: updated)
        }
    }

    func clear(accountID: String) throws {
        try withLock {
            let normalizedAccountID = try Self.normalizedAccountID(accountID)
            let oldCatalog = try loadCatalog()
            let retained = oldCatalog.entries.filter { $0.accountID != normalizedAccountID }
            let updated = ContentDraftFileCatalog(
                formatVersion: ContentDraftFileCatalog.currentFormatVersion,
                entries: retained
            )
            // Commit an empty catalog even on a first clear. It is a durable
            // source generation that must migrate as an intentional deletion.
            try catalogFile.replace(updated) {
                try Task.checkCancellation()
                try faultInjector.check(.beforeCatalogCommit)
            }
            cleanupBestEffort(referencedBy: updated)
        }
    }

    func repairAndPrune() throws {
        try withLock {
            let catalog = try loadCatalog()
            let retained = pruned(catalog.entries)
            let updated = ContentDraftFileCatalog(
                formatVersion: ContentDraftFileCatalog.currentFormatVersion,
                entries: retained
            )
            if retained.count != catalog.entries.count {
                try catalogFile.replace(updated) {
                    try Task.checkCancellation()
                    try faultInjector.check(.beforeCatalogCommit)
                }
            }
            cleanupBestEffort(referencedBy: updated)
        }
    }

    func migrationManifest() throws -> ContentDraftMigrationManifest {
        try withLock {
            let catalog = try loadCatalog()
            try Task.checkCancellation()
            return try ContentDraftMigrationManifest(
                entries: catalog.entries.map(\.migrationManifestEntry)
            )
        }
    }

    func migrationRecord(identity: String) throws -> ContentDraftPersistenceRecord {
        try withLock {
            let catalog = try loadCatalog()
            guard let entry = preferredEntry(in: catalog.entries.filter { $0.identity == identity }),
                  let blob = try readBlobIfValid(entry.blobFileName) else {
                throw ContentDraftPersistenceError.missingMigrationRecord
            }
            let record = try ContentDraftPersistenceRecord(
                accountID: entry.accountID,
                targetKey: entry.targetKey,
                targetData: entry.targetData,
                title: entry.title,
                body: entry.body,
                imagesBlob: blob,
                imagesByteCount: blob.count,
                updatedAt: entry.updatedAt
            ).validated()
            guard try ContentDraftMigrationManifestEntry(record: record)
                == entry.migrationManifestEntry else {
                throw ContentDraftPersistenceError.invalidRecord
            }
            return record
        }
    }

    func beginMigration(to manifest: ContentDraftMigrationManifest) throws {
        try withLock {
            _ = try ContentDraftMigrationManifest(entries: manifest.entries)
            let empty = ContentDraftFileCatalog.empty
            try catalogFile.replace(empty) {
                try Task.checkCancellation()
                try faultInjector.check(.beforeCatalogCommit)
            }
            cleanupBestEffort(referencedBy: empty)
        }
    }

    func writeMigrationRecord(_ record: ContentDraftPersistenceRecord) throws {
        let record = try record.validated()
        let manifestEntry = try ContentDraftMigrationManifestEntry(record: record)
        try withLock {
            try Task.checkCancellation()
            let oldCatalog = try loadCatalog()
            let recordID = UUID().uuidString.lowercased()
            let blobFileName = Self.blobFileName(recordID: recordID)
            var blobWasCommitted = false
            var catalogWasCommitted = false
            do {
                try writeBlob(record.imagesBlob, fileName: blobFileName)
                blobWasCommitted = true
                var entries = oldCatalog.entries.filter { $0.identity != record.identity }
                entries.append(ContentDraftFileCatalogEntry(
                    recordID: recordID,
                    accountID: record.accountID,
                    targetKey: record.targetKey,
                    targetData: record.targetData,
                    title: record.title,
                    body: record.body,
                    blobFileName: blobFileName,
                    imagesByteCount: record.imagesByteCount,
                    updatedAt: record.updatedAt,
                    metadataDigest: manifestEntry.metadataDigest,
                    blobDigest: manifestEntry.blobDigest
                ))
                let updated = ContentDraftFileCatalog(
                    formatVersion: ContentDraftFileCatalog.currentFormatVersion,
                    entries: pruned(entries)
                )
                try catalogFile.replace(updated) {
                    try Task.checkCancellation()
                    try faultInjector.check(.beforeCatalogCommit)
                }
                catalogWasCommitted = true
                cleanupBestEffort(referencedBy: updated)
            } catch {
                if blobWasCommitted, catalogWasCommitted == false {
                    try? removeRegularFileIfPresent(blobURL(fileName: blobFileName))
                }
                throw error
            }
        }
    }

    private func loadCatalog() throws -> ContentDraftFileCatalog {
        let catalog = try catalogFile.load() ?? .empty
        guard catalog.formatVersion == ContentDraftFileCatalog.currentFormatVersion else {
            throw FileContentDraftPersistenceError.unsupportedCatalogVersion(catalog.formatVersion)
        }
        var recordIDs = Set<String>()
        var fileNames = Set<String>()
        var identities = Set<String>()
        for entry in catalog.entries {
            guard UUID(uuidString: entry.recordID) != nil,
                  entry.blobFileName == Self.blobFileName(recordID: entry.recordID),
                  recordIDs.insert(entry.recordID).inserted,
                  fileNames.insert(entry.blobFileName).inserted,
                  identities.insert(entry.identity).inserted,
                  entry.accountID.isEmpty == false,
                  entry.accountID == entry.accountID.trimmingCharacters(in: .whitespacesAndNewlines),
                  entry.targetKey.isEmpty == false,
                  entry.imagesByteCount >= 0,
                  entry.imagesByteCount <= ContentDraftPolicy.maximumAttachmentBytesPerDraft,
                  entry.metadataDigest == ContentDraftMigrationManifestEntry.metadataDigest(
                    accountID: entry.accountID,
                    targetKey: entry.targetKey,
                    targetData: entry.targetData,
                    title: entry.title,
                    body: entry.body,
                    updatedAt: entry.updatedAt
                  ) else {
                throw FileContentDraftPersistenceError.invalidCatalog
            }
        }
        guard (try? ContentDraftMigrationManifest(
            entries: catalog.entries.map(\.migrationManifestEntry)
        )) != nil else {
            throw FileContentDraftPersistenceError.invalidCatalog
        }
        return catalog
    }

    private func pruned(
        _ entries: [ContentDraftFileCatalogEntry]
    ) -> [ContentDraftFileCatalogEntry] {
        let candidates = entries.enumerated().map { index, entry in
            ContentDraftPruneCandidate(
                sourceIndex: index,
                persistentID: entry.recordID,
                accountID: entry.accountID,
                targetKey: entry.targetKey,
                updatedAt: entry.updatedAt,
                imagesByteCount: entry.imagesByteCount
            )
        }
        let deletionIndices = ContentDraftPruner.deletionIndices(for: candidates)
        return entries.enumerated().compactMap { index, entry in
            deletionIndices.contains(index) ? nil : entry
        }
    }

    private func preferredEntry(
        in entries: [ContentDraftFileCatalogEntry]
    ) -> ContentDraftFileCatalogEntry? {
        entries.max {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.recordID < $1.recordID
        }
    }

    private func writeBlob(_ data: Data, fileName: String) throws {
        try Task.checkCancellation()
        guard data.count <= ContentDraftPolicy.maximumAttachmentBytesPerDraft else {
            throw FileContentDraftPersistenceError.attachmentTooLarge
        }
        try Self.prepareDirectory(blobDirectoryURL, fileManager: fileManager)
        let destinationURL = blobURL(fileName: fileName)
        guard fileManager.fileExists(atPath: destinationURL.path) == false else {
            throw FileContentDraftPersistenceError.invalidCatalog
        }
        let temporaryURL = blobDirectoryURL.appendingPathComponent(
            ".\(fileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.completeFileProtection])
        try Self.secureFile(temporaryURL, fileManager: fileManager)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.synchronize()
        try handle.close()
        try Task.checkCancellation()
        try faultInjector.check(.beforeBlobCommit)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        try Self.secureFile(destinationURL, fileManager: fileManager)
    }

    private func readBlobIfValid(_ fileName: String) throws -> Data? {
        let url = blobURL(fileName: fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try Self.rejectSymbolicLink(url, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw FileContentDraftPersistenceError.pathIsNotRegularFile
        }
        if let size = attributes[.size] as? NSNumber,
           size.intValue > ContentDraftPolicy.maximumAttachmentBytesPerDraft {
            return nil
        }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= ContentDraftPolicy.maximumAttachmentBytesPerDraft else { return nil }
        return data
    }

    private func cleanupUnreferencedBlobs(
        referencedBy catalog: ContentDraftFileCatalog
    ) throws {
        let referenced = Set(catalog.entries.map(\.blobFileName))
        for url in try fileManager.contentsOfDirectory(
            at: blobDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) where (url.pathExtension == "tpdi"
            && referenced.contains(url.lastPathComponent) == false)
            || (url.lastPathComponent.hasPrefix(".")
                && url.lastPathComponent.hasSuffix(".tmp")) {
            try Task.checkCancellation()
            try removeRegularFileIfPresent(url)
        }
    }

    private func cleanupBestEffort(referencedBy catalog: ContentDraftFileCatalog) {
        do {
            try faultInjector.check(.beforeBlobCleanup)
            try cleanupUnreferencedBlobs(referencedBy: catalog)
        } catch {
            // The catalog is the commit point. Cleanup is maintenance and can
            // be retried without changing the result of the committed write.
        }
    }

    private func removeRegularFileIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try Self.rejectSymbolicLink(url, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw FileContentDraftPersistenceError.pathIsNotRegularFile
        }
        try fileManager.removeItem(at: url)
    }

    private func blobURL(fileName: String) -> URL {
        blobDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func blobFileName(recordID: String) -> String {
        "draft-\(recordID.lowercased()).tpdi"
    }

    private static func normalizedAccountID(_ accountID: String) throws -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw FileContentDraftPersistenceError.invalidAccountID
        }
        return normalized
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        sharedState.lock.lock()
        defer { sharedState.lock.unlock() }
        return try operation()
    }

    private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            try rejectSymbolicLink(url, fileManager: fileManager)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw FileContentDraftPersistenceError.pathIsNotDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: secureDirectoryAttributes
            )
        }
        try fileManager.setAttributes(secureDirectoryAttributes, ofItemAtPath: url.path)
    }

    private static func secureFile(_ url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(secureFileAttributes, ofItemAtPath: url.path)
    }

    private static func rejectSymbolicLink(_ url: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw FileContentDraftPersistenceError.pathIsSymbolicLink
        }
    }

    private static var secureDirectoryAttributes: [FileAttributeKey: Any] {
        [
            .posixPermissions: NSNumber(value: Int16(0o700)),
            .protectionKey: FileProtectionType.complete
        ]
    }

    private static var secureFileAttributes: [FileAttributeKey: Any] {
        [
            .posixPermissions: NSNumber(value: Int16(0o600)),
            .protectionKey: FileProtectionType.complete
        ]
    }
}

@MainActor
final class FileContentDraftPersistenceBackend: ContentDraftPersistenceBackend {
    private let storage: ContentDraftFileStorage
    private(set) var persistenceAvailability: PersistenceAvailability = .available

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        faultInjector: ContentDraftFilePersistenceFaultInjector = .none
    ) throws {
        storage = try ContentDraftFileStorage(
            directoryURL: directoryURL,
            fileManager: fileManager,
            faultInjector: faultInjector
        )
    }

    func catalogPresence() throws -> ContentDraftFileCatalogPresence {
        try storage.catalogPresence()
    }

    func load(
        accountID: String,
        target: ContentSubmissionTarget,
        into draft: inout ContentDraft?
    ) -> Bool {
        draft = nil
        do {
            let outcome = try storage.load(accountID: accountID, target: target)
            switch outcome {
            case let .loaded(value):
                draft = value
                markSucceeded()
                return true
            case .damaged:
                markSucceeded()
                return false
            case .unavailable:
                return fail(ContentDraftPersistenceError.unavailable, operation: "load file content draft")
            }
        } catch is CancellationError {
            return false
        } catch {
            return fail(error, operation: "load file content draft")
        }
    }

    func loadAsync(
        accountID: String,
        target: ContentSubmissionTarget
    ) async -> ContentDraftLoadOutcome {
        let storage = storage
        let task = Task.detached(priority: .userInitiated) {
            try storage.load(accountID: accountID, target: target)
        }
        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            markSucceeded()
            return outcome
        } catch is CancellationError {
            return .unavailable
        } catch {
            _ = fail(error, operation: "load file content draft")
            return .unavailable
        }
    }

    func save(_ draft: ContentDraft) -> Bool {
        do {
            try storage.save(draft)
            markSucceeded()
            return true
        } catch is CancellationError {
            return false
        } catch {
            return fail(error, operation: "save file content draft")
        }
    }

    func saveAsync(_ draft: ContentDraft) async throws {
        let storage = storage
        let task = Task.detached(priority: .userInitiated) {
            try storage.save(draft)
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            markSucceeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "save file content draft")
            throw error
        }
    }

    func delete(accountID: String, target: ContentSubmissionTarget) -> Bool {
        do {
            try storage.delete(accountID: accountID, target: target)
            markSucceeded()
            return true
        } catch is CancellationError {
            return false
        } catch {
            return fail(error, operation: "delete file content draft")
        }
    }

    func clear(accountID: String) -> Bool {
        do {
            try storage.clear(accountID: accountID)
            markSucceeded()
            return true
        } catch is CancellationError {
            return false
        } catch {
            return fail(error, operation: "clear file content drafts")
        }
    }

    func repairLegacyMetadataAndPruneAsync() async -> Bool {
        let storage = storage
        let task = Task.detached(priority: .utility) {
            try storage.repairAndPrune()
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            markSucceeded()
            return true
        } catch is CancellationError {
            return false
        } catch {
            return fail(error, operation: "repair file content drafts")
        }
    }

    func migrationManifest() async throws -> ContentDraftMigrationManifest {
        let storage = storage
        let task = Task.detached(priority: .utility) {
            try storage.migrationManifest()
        }
        do {
            let manifest = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            markSucceeded()
            return manifest
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "export file content draft migration manifest")
            throw error
        }
    }

    func migrationRecord(identity: String) async throws -> ContentDraftPersistenceRecord {
        let storage = storage
        let task = Task.detached(priority: .utility) {
            try storage.migrationRecord(identity: identity)
        }
        do {
            let record = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            markSucceeded()
            return record
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "read file content draft migration record")
            throw error
        }
    }

    func beginMigration(to manifest: ContentDraftMigrationManifest) async throws {
        let storage = storage
        let task = Task.detached(priority: .utility) {
            try storage.beginMigration(to: manifest)
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            markSucceeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "begin file content draft migration")
            throw error
        }
    }

    func writeMigrationRecord(_ record: ContentDraftPersistenceRecord) async throws {
        let storage = storage
        let task = Task.detached(priority: .utility) {
            try storage.writeMigrationRecord(record)
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            markSucceeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "write file content draft migration record")
            throw error
        }
    }

    private func markSucceeded() {
        persistenceAvailability = .available
    }

    private func fail(_ error: Error, operation: String) -> Bool {
        PersistenceDiagnostics.report(error, operation: operation)
        persistenceAvailability = .unavailable
        return false
    }
}
