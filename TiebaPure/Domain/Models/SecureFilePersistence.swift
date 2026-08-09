import CryptoKit
import Foundation

enum SecureFilePersistenceError: Error, Equatable {
    case invalidFileName
    case pathIsSymbolicLink
    case pathIsNotRegularFile
    case pathIsNotDirectory
    case payloadTooLarge
    case unsupportedFormatVersion(Int)
    case checksumMismatch
    case corruptedPrimaryAndBackup
    case failedClosed
}

private final class SecureFileSharedState: @unchecked Sendable {
    let lock = NSLock()
    var isFailedClosed = false
}

private final class SecureFileStateRegistry: @unchecked Sendable {
    static let shared = SecureFileStateRegistry()

    private let registryLock = NSLock()
    private var states: [String: SecureFileSharedState] = [:]

    func state(for standardizedPath: String) -> SecureFileSharedState {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = states[standardizedPath] {
            return existing
        }
        let created = SecureFileSharedState()
        states[standardizedPath] = created
        return created
    }
}

struct SecurePersistenceLocation: Sendable {
    static let currentDirectoryName = "v1"

    let directoryURL: URL

    static func applicationSupport(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) throws -> SecurePersistenceLocation {
        let applicationSupport: URL
        if let baseDirectoryURL {
            applicationSupport = baseDirectoryURL
        } else {
            guard let resolved = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            applicationSupport = resolved
        }
        if fileManager.fileExists(atPath: applicationSupport.path) == false {
            try fileManager.createDirectory(
                at: applicationSupport,
                withIntermediateDirectories: true
            )
        }

        var directoryURL = applicationSupport
        for component in ["TiebaPure", "Persistence", currentDirectoryName] {
            directoryURL.appendPathComponent(component, isDirectory: true)
            try prepareProtectedDirectory(directoryURL, fileManager: fileManager)
        }
        return SecurePersistenceLocation(directoryURL: directoryURL)
    }

    private static func prepareProtectedDirectory(
        _ directoryURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: directoryURL.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw SecureFilePersistenceError.pathIsSymbolicLink
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw SecureFilePersistenceError.pathIsNotDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: protectedDirectoryAttributes
            )
        }
        try fileManager.setAttributes(
            protectedDirectoryAttributes,
            ofItemAtPath: directoryURL.path
        )
    }

    private static var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o700))
        ]
#if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
#endif
        return attributes
    }
}

enum SecurePersistenceDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A small, versioned file store used by the iOS 16 persistence adapters.
///
/// Every operation is serialized by the lock, including a read-modify-write
/// performed from the browsing-history actor. The latest committed generation
/// is mirrored as a backup. A corrupt primary is restored from that backup; when
/// neither generation is valid, writes remain blocked until explicit recovery
/// quarantines the damaged files.
final class SecureCodableFile<Payload: Codable & Sendable>: @unchecked Sendable {
    private struct Envelope: Codable {
        let formatVersion: Int
        let payload: Payload
        let checksum: String
    }

    private enum ReadResult {
        case missing
        case value(Payload, encodedEnvelope: Data)
        case corrupt
    }

    static var currentFormatVersion: Int { 1 }
    static var defaultMaximumByteCount: Int { 8 * 1_024 * 1_024 }

    let fileURL: URL
    let backupURL: URL

    private let fileManager: FileManager
    private let maximumByteCount: Int
    private let sharedState: SecureFileSharedState

    init(
        directoryURL: URL,
        fileName: String,
        fileManager: FileManager = .default,
        maximumByteCount: Int = SecureCodableFile.defaultMaximumByteCount
    ) throws {
        guard fileName.isEmpty == false,
              fileName != ".",
              fileName != "..",
              fileName == (fileName as NSString).lastPathComponent else {
            throw SecureFilePersistenceError.invalidFileName
        }
        self.fileManager = fileManager
        self.maximumByteCount = max(maximumByteCount, 1)
        fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        backupURL = directoryURL.appendingPathComponent("\(fileName).backup", isDirectory: false)
        sharedState = SecureFileStateRegistry.shared.state(
            for: fileURL.standardizedFileURL.path
        )
        try Self.prepareDirectory(directoryURL, fileManager: fileManager)
    }

    func load() throws -> Payload? {
        try withLock {
            try loadLocked()
        }
    }

    func replace(
        _ payload: Payload,
        beforeCommit: () throws -> Void = {}
    ) throws {
        try withLock {
            guard sharedState.isFailedClosed == false else {
                throw SecureFilePersistenceError.failedClosed
            }
            _ = try loadLocked()
            let encoded = try encode(payload)
            try beforeCommit()
            try invalidateBackupLocked()
            try atomicWrite(encoded, to: fileURL)
            refreshBackupBestEffort(encoded)
        }
    }

    func update(
        default defaultPayload: @autoclosure () -> Payload,
        beforeCommit: () throws -> Void = {},
        transform: (inout Payload) throws -> Void
    ) throws -> Payload {
        try withLock {
            guard sharedState.isFailedClosed == false else {
                throw SecureFilePersistenceError.failedClosed
            }
            var payload = try loadLocked() ?? defaultPayload()
            try transform(&payload)
            let encoded = try encode(payload)
            try beforeCommit()
            try invalidateBackupLocked()
            try atomicWrite(encoded, to: fileURL)
            refreshBackupBestEffort(encoded)
            return payload
        }
    }

    /// Preserves damaged generations for diagnostics and unlocks a clean store.
    /// This is intentionally explicit so a decode failure can never silently
    /// erase the only remaining copy.
    func quarantineCorruptedGenerations(now: Date = Date()) throws {
        try withLock {
            guard sharedState.isFailedClosed else { return }
            let suffix = String(Int(now.timeIntervalSince1970)) + "-" + UUID().uuidString
            try quarantineIfPresent(fileURL, suffix: suffix)
            try quarantineIfPresent(backupURL, suffix: suffix)
            sharedState.isFailedClosed = false
        }
    }

    private func loadLocked() throws -> Payload? {
        guard sharedState.isFailedClosed == false else {
            throw SecureFilePersistenceError.failedClosed
        }

        let primary = try read(fileURL)
        switch primary {
        case let .value(payload, encodedEnvelope):
            refreshBackupBestEffort(encodedEnvelope)
            return payload
        case .missing, .corrupt:
            let backup = try read(backupURL)
            switch backup {
            case let .value(payload, encodedEnvelope):
                try atomicWrite(encodedEnvelope, to: fileURL)
                return payload
            case .missing:
                if case .missing = primary {
                    return nil
                }
            case .corrupt:
                break
            }
        }

        sharedState.isFailedClosed = true
        throw SecureFilePersistenceError.corruptedPrimaryAndBackup
    }

    private func invalidateBackupLocked() throws {
        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        try Self.rejectSymbolicLink(at: backupURL, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: backupURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SecureFilePersistenceError.pathIsNotRegularFile
        }
        try fileManager.removeItem(at: backupURL)
    }

    private func refreshBackupBestEffort(_ encodedEnvelope: Data) {
        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try Self.rejectSymbolicLink(at: backupURL, fileManager: fileManager)
                let attributes = try fileManager.attributesOfItem(atPath: backupURL.path)
                if attributes[.type] as? FileAttributeType == .typeRegular,
                   try Data(contentsOf: backupURL, options: [.mappedIfSafe]) == encodedEnvelope {
                    return
                }
            }
            try invalidateBackupLocked()
            try atomicWrite(encodedEnvelope, to: backupURL)
        } catch {
            // The primary is already committed and remains authoritative. Never
            // leave an older backup that could resurrect a cleared entry.
            try? removeRegularBackupIfPresent()
        }
    }

    private func removeRegularBackupIfPresent() throws {
        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        try Self.rejectSymbolicLink(at: backupURL, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: backupURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
        try fileManager.removeItem(at: backupURL)
    }

    private func read(_ url: URL) throws -> ReadResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        try Self.rejectSymbolicLink(at: url, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SecureFilePersistenceError.pathIsNotRegularFile
        }
        if let byteCount = attributes[.size] as? NSNumber,
           byteCount.intValue > maximumByteCount {
            return .corrupt
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumByteCount else {
            return .corrupt
        }
        do {
            return .value(try decode(data), encodedEnvelope: data)
        } catch let error as SecureFilePersistenceError {
            switch error {
            case .unsupportedFormatVersion, .checksumMismatch:
                return .corrupt
            default:
                throw error
            }
        } catch is DecodingError {
            return .corrupt
        }
    }

    private func encode(_ payload: Payload) throws -> Data {
        let payloadData = try Self.encoder().encode(payload)
        guard payloadData.count <= maximumByteCount else {
            throw SecureFilePersistenceError.payloadTooLarge
        }
        let envelope = Envelope(
            formatVersion: Self.currentFormatVersion,
            payload: payload,
            checksum: SecurePersistenceDigest.sha256(payloadData)
        )
        let data = try Self.encoder().encode(envelope)
        guard data.count <= maximumByteCount else {
            throw SecureFilePersistenceError.payloadTooLarge
        }
        return data
    }

    private func decode(_ data: Data) throws -> Payload {
        let envelope = try Self.decoder().decode(Envelope.self, from: data)
        guard envelope.formatVersion == Self.currentFormatVersion else {
            throw SecureFilePersistenceError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let payloadData = try Self.encoder().encode(envelope.payload)
        guard SecurePersistenceDigest.sha256(payloadData) == envelope.checksum else {
            throw SecureFilePersistenceError.checksumMismatch
        }
        return envelope.payload
    }

    private func atomicWrite(_ data: Data, to destinationURL: URL) throws {
        guard data.count <= maximumByteCount else {
            throw SecureFilePersistenceError.payloadTooLarge
        }
        let directoryURL = destinationURL.deletingLastPathComponent()
        try Self.prepareDirectory(directoryURL, fileManager: fileManager)
        try Self.rejectSymbolicLinkIfPresent(at: destinationURL, fileManager: fileManager)

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: Self.protectedWritingOptions)
        try Self.secureFile(at: temporaryURL, fileManager: fileManager)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.synchronize()
        try handle.close()

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func quarantineIfPresent(_ url: URL, suffix: String) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try Self.rejectSymbolicLink(at: url, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SecureFilePersistenceError.pathIsNotRegularFile
        }
        try Self.secureFile(at: url, fileManager: fileManager)
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(suffix)",
            isDirectory: false
        )
        try fileManager.moveItem(at: url, to: quarantineURL)
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        sharedState.lock.lock()
        defer { sharedState.lock.unlock() }
        return try operation()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func prepareDirectory(
        _ directoryURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try rejectSymbolicLink(at: directoryURL, fileManager: fileManager)
            let attributes = try fileManager.attributesOfItem(atPath: directoryURL.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw SecureFilePersistenceError.pathIsNotDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: secureDirectoryAttributes
            )
        }
        try fileManager.setAttributes(
            secureDirectoryAttributes,
            ofItemAtPath: directoryURL.path
        )
    }

    private static func secureFile(at url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(secureFileAttributes, ofItemAtPath: url.path)
    }

    private static func rejectSymbolicLinkIfPresent(
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try rejectSymbolicLink(at: url, fileManager: fileManager)
    }

    private static func rejectSymbolicLink(
        at url: URL,
        fileManager: FileManager
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw SecureFilePersistenceError.pathIsSymbolicLink
        }
    }

    private static var secureDirectoryAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o700))
        ]
#if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
#endif
        return attributes
    }

    private static var secureFileAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o600))
        ]
#if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
#endif
        return attributes
    }

    private static var protectedWritingOptions: Data.WritingOptions {
#if os(iOS)
        [.completeFileProtection]
#else
        []
#endif
    }
}
