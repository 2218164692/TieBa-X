import Combine
import Foundation
import Security

protocol AccountStoreService: Sendable {
    func loadData() async throws -> Data?
    func saveData(_ data: Data) async throws
    func clearData() async throws
}

/// Read/delete-only access to the one-time plaintext migration source. Keeping
/// this separate from AccountStoreService makes a file-backed credential
/// fallback impossible to wire into production accidentally.
protocol LegacyAccountStoreService: Sendable {
    func loadData() async throws -> Data?
    func clearData() async throws
}

final class AccountStore: ObservableObject {
    private let service: AccountStoreService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let operationLock = AccountStoreOperationLock()
    let accountDidChange = PassthroughSubject<Account?, Never>()

    init(service: AccountStoreService) {
        self.service = service
    }

    func load() async throws -> Account? {
        try await withExclusiveOperation {
            try await loadUnlocked()
        }
    }

    private func loadUnlocked() async throws -> Account? {
        guard let data = try await service.loadData() else { return nil }
        do {
            let account = try decoder.decode(Account.self, from: data)
            guard BaiduCredentialPolicy.isValid(account) else {
                throw AccountStoreError.invalidCredentials
            }
            return account
        } catch {
            try? await service.clearData()
            throw error
        }
    }

    func save(_ account: Account) async throws {
        try await withExclusiveOperation {
            try await saveUnlocked(account)
        }
    }

    /// Updates non-secret metadata on the active account without allowing a
    /// stale view to recreate credentials or overwrite refreshed cookies.
    func updateDisplayName(
        _ displayName: String,
        forSession expectedSession: AccountSessionIdentity
    ) async throws {
        try await withExclusiveOperation {
            guard var current = try await loadUnlocked(),
                  current.sessionIdentity == expectedSession else {
                throw AccountStoreError.sessionChanged
            }
            current.displayName = displayName
            try await saveUnlocked(current)
        }
    }

    private func saveUnlocked(_ account: Account) async throws {
        try Task.checkCancellation()
        guard BaiduCredentialPolicy.isValid(account) else {
            throw AccountStoreError.invalidCredentials
        }
        let previousData = try await service.loadData()
        let previousAccount = previousData
            .flatMap { try? decoder.decode(Account.self, from: $0) }
            .flatMap { BaiduCredentialPolicy.isValid($0) ? $0 : nil }
        // Re-encode rather than restore the original bytes so removed legacy
        // fields (including a complete Cookie header) cannot reappear.
        let restorablePreviousData = previousAccount.flatMap { try? encoder.encode($0) }
        let data = try encoder.encode(account)
        do {
            try Task.checkCancellation()
            try await service.saveData(data)
            try Task.checkCancellation()
            try await MainActor.run {
                try Task.checkCancellation()
                accountDidChange.send(account)
            }
            // Publishing the account is the commit point. Subscribers are
            // expected to dismiss the login view, which cancels its validation
            // task. Treating that expected dismissal as a failed save would
            // immediately roll the newly stored account back to logged out.
        } catch is CancellationError {
            do {
                if let restorablePreviousData {
                    try await service.saveData(restorablePreviousData)
                } else {
                    try await service.clearData()
                }
            } catch {
                throw AccountStoreError.cancellationRollbackFailed
            }
            await MainActor.run {
                accountDidChange.send(previousAccount)
            }
            throw CancellationError()
        }
    }

    func clear() async throws {
        try await withExclusiveOperation {
            try await service.clearData()
            await MainActor.run {
                accountDidChange.send(nil)
            }
        }
    }

    private func withExclusiveOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await operationLock.acquire()
        do {
            let result = try await operation()
            await operationLock.release()
            return result
        } catch {
            await operationLock.release()
            throw error
        }
    }
}

private actor AccountStoreOperationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isLocked == false {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard waiters.isEmpty == false else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

actor MemoryAccountStoreService: AccountStoreService, LegacyAccountStoreService {
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func loadData() async throws -> Data? {
        data
    }

    func saveData(_ data: Data) async throws {
        self.data = data
    }

    func clearData() async throws {
        data = nil
    }
}

/// Keeps a credential that could not be classified during first-launch cleanup
/// inaccessible for the lifetime of this process. A successful login may still
/// replace it; reads and clears are enabled only after that replacement succeeds.
actor DeferredFreshInstallAccountStoreService: AccountStoreService {
    private let keychain: any AccountStoreService
    private let markCleanupCompleted: @Sendable () throws -> Void
    private var allowsAccess = false

    init(
        keychain: any AccountStoreService,
        markCleanupCompleted: @escaping @Sendable () throws -> Void
    ) {
        self.keychain = keychain
        self.markCleanupCompleted = markCleanupCompleted
    }

    func loadData() async throws -> Data? {
        guard allowsAccess else { return nil }
        return try await keychain.loadData()
    }

    func saveData(_ data: Data) async throws {
        try await keychain.saveData(data)
        // SecItemUpdate preserves the old creation date. Mark this install as
        // complete only after replacement succeeds so the new login is not
        // mistaken for the old uninstall leftover on the next launch.
        try markCleanupCompleted()
        allowsAccess = true
    }

    func clearData() async throws {
        guard allowsAccess else { return }
        try await keychain.clearData()
        allowsAccess = false
    }
}

/// Imports the previous plaintext account exactly once. Credentials are never
/// returned unless the Keychain write and plaintext deletion both succeed.
actor MigratingAccountStoreService: AccountStoreService {
    private let keychain: any AccountStoreService
    private let legacyFile: any LegacyAccountStoreService

    init(keychain: any AccountStoreService, legacyFile: any LegacyAccountStoreService) {
        self.keychain = keychain
        self.legacyFile = legacyFile
    }

    func loadData() async throws -> Data? {
        let keychainData: Data?
        do {
            keychainData = try await keychain.loadData()
        } catch {
            try? await legacyFile.clearData()
            throw AccountMigrationError.keychainWriteFailed
        }
        if let stored = keychainData {
            guard let decoded = Self.validAccount(from: stored),
                  let sanitized = try? JSONEncoder().encode(decoded) else {
                try? await keychain.clearData()
                try? await legacyFile.clearData()
                throw AccountMigrationError.invalidLegacyData
            }
            if sanitized != stored {
                do {
                    try await keychain.saveData(sanitized)
                } catch {
                    try? await keychain.clearData()
                    try? await legacyFile.clearData()
                    throw AccountMigrationError.keychainWriteFailed
                }
            }
            do {
                try await legacyFile.clearData()
            } catch {
                try? await keychain.clearData()
                throw AccountMigrationError.plaintextDeletionFailed
            }
            return sanitized
        }
        guard let legacy = try await legacyFile.loadData() else {
            return nil
        }
        guard let decoded = Self.validAccount(from: legacy),
              let sanitized = try? JSONEncoder().encode(decoded) else {
            try? await legacyFile.clearData()
            throw AccountMigrationError.invalidLegacyData
        }

        do {
            // Decode and re-encode instead of copying the legacy bytes. Codable
            // intentionally ignores unknown keys, so this strips the removed
            // full-cookie field and any other unrecognized plaintext material.
            try await keychain.saveData(sanitized)
            do {
                try await legacyFile.clearData()
            } catch {
                try? await keychain.clearData()
                throw AccountMigrationError.plaintextDeletionFailed
            }
            return sanitized
        } catch let error as AccountMigrationError {
            throw error
        } catch {
            // A failed migration must force a new login and must not continue
            // reading usable credentials from disk.
            try? await legacyFile.clearData()
            throw AccountMigrationError.keychainWriteFailed
        }
    }

    func saveData(_ data: Data) async throws {
        do {
            try await keychain.saveData(data)
        } catch {
            try? await legacyFile.clearData()
            throw AccountMigrationError.keychainWriteFailed
        }
        do {
            try await legacyFile.clearData()
        } catch {
            try? await keychain.clearData()
            throw AccountMigrationError.plaintextDeletionFailed
        }
    }

    func clearData() async throws {
        var firstError: Error?
        do { try await legacyFile.clearData() } catch { firstError = error }
        do { try await keychain.clearData() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    private static func validAccount(from data: Data) -> Account? {
        guard let account = try? JSONDecoder().decode(Account.self, from: data),
              BaiduCredentialPolicy.isValid(account) else {
            return nil
        }
        return account
    }
}

enum AccountMigrationError: Error, Equatable {
    case keychainWriteFailed
    case plaintextDeletionFailed
    case invalidLegacyData
}

actor FileAccountStoreService: LegacyAccountStoreService {
    private let fileURL: URL

    init(fileURL: URL = FileAccountStoreService.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func loadData() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    func clearData() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("TiebaPure", isDirectory: true)
            .appendingPathComponent("account.json")
    }
}

protocol KeychainSecurityOperating: Sendable {
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemKeychainSecurityOperations: KeychainSecurityOperating {
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

struct KeychainAccountStoreService: AccountStoreService {
    private let service: String
    private let account: String
    private let securityOperations: any KeychainSecurityOperating

    init(
        service: String = "dev.infinityf4p.tiebapure.account",
        account: String = "single",
        securityOperations: any KeychainSecurityOperating = SystemKeychainSecurityOperations()
    ) {
        self.service = service
        self.account = account
        self.securityOperations = securityOperations
    }

    func loadData() async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = securityOperations.copyMatching(query as CFDictionary, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    func saveData(_ data: Data) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = securityOperations.update(
            query as CFDictionary,
            attributes: attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = securityOperations.add(addQuery as CFDictionary)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    func clearData() async throws {
        try deleteStoredItem()
    }

    /// Whether a credential exists and, when it does, when Keychain created it.
    /// Query failures are thrown rather than being collapsed into `notFound`,
    /// so a transient Keychain error cannot permanently disable the first-run
    /// cleanup.
    func storedItemCreationState() throws -> StoredCredentialCreationState {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = securityOperations.copyMatching(query as CFDictionary, result: &result)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
        guard let attributes = result as? [String: Any],
              let creationDate = attributes[kSecAttrCreationDate as String] as? Date else {
            throw KeychainError.invalidItemAttributes
        }
        return .found(creationDate)
    }

    /// Synchronous variant for the fresh-install sweep, which must finish
    /// before any credential load can start.
    func deleteStoredItem() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = securityOperations.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

enum StoredCredentialCreationState: Equatable {
    case notFound
    case found(Date)
}

enum FreshInstallCredentialCleanupResult: Equatable {
    /// Cleanup either completed now or had already completed on an earlier run.
    case completed
    /// Credential state could not be established safely. Retry next launch.
    case deferred
}

/// Keychain items survive app uninstall. A credential written before the
/// current sandbox existed can only be a leftover from a previous install, so
/// it is cleared on first launch. UserDefaults-based signals are unreliable
/// here: every key the app persists can be legitimately absent for a
/// logged-in user (default appearance, cleared histories), which would log
/// out upgrading users.
struct FreshInstallCredentialCleanup {
    static let sentinelKey = "dev.infinityf4p.tiebapure.firstLaunchCompleted"

    var defaults: UserDefaults
    var storedCredentialCreationState: () throws -> StoredCredentialCreationState
    var sandboxCreationDate: () throws -> Date
    var clearStoredCredentials: () throws -> Void

    @discardableResult
    func runIfNeeded() -> FreshInstallCredentialCleanupResult {
        guard defaults.object(forKey: Self.sentinelKey) == nil else { return .completed }

        do {
            switch try storedCredentialCreationState() {
            case .notFound:
                break
            case let .found(credentialDate):
                let installDate = try sandboxCreationDate()
                if credentialDate < installDate {
                    try clearStoredCredentials()
                }
            }
        } catch {
            // Leave the sentinel unwritten so every lookup, metadata, sandbox,
            // and deletion failure is retried on the next launch.
            return .deferred
        }
        Self.markCompleted(in: defaults)
        return .completed
    }

    static func markCompleted(in defaults: UserDefaults) {
        defaults.set(true, forKey: sentinelKey)
    }
}

enum KeychainError: Error, Equatable {
    case status(OSStatus)
    case invalidItemAttributes
}

enum AccountStoreError: Error, Equatable {
    case cancellationRollbackFailed
    case invalidCredentials
    case sessionChanged
}
