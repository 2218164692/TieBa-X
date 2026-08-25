import Foundation
import WebKit

@MainActor
protocol SessionArtifactCleaning {
    func clear() async throws
}

struct LiveSessionArtifactCleaner: SessionArtifactCleaning {
    func clear() async throws {
        try Task.checkCancellation()
        clearFoundationCookies()
        URLCache.shared.removeAllCachedResponses()
        await TiebaImagePipeline.shared.clearCaches()
        try await clearLegacyBaiduWebKitData()
        try Task.checkCancellation()
    }

    private func clearFoundationCookies() {
        HTTPCookieStorage.shared.cookies?
            .filter { Self.isBaiduDomain($0.domain) }
            .forEach(HTTPCookieStorage.shared.deleteCookie)
    }

    private func clearLegacyBaiduWebKitData() async throws {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let baiduRecords = records.filter { Self.isBaiduDomain($0.displayName) }
        guard baiduRecords.isEmpty == false else { return }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: baiduRecords) {
                continuation.resume()
            }
        }
    }

    private static func isBaiduDomain(_ value: String) -> Bool {
        let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "baidu.com" || domain.hasSuffix(".baidu.com")
    }
}

@MainActor
final class LogoutCoordinator {
    private let accountStore: AccountStore
    private let artifactCleaner: any SessionArtifactCleaning
    private let beginWriteInvalidation: @MainActor () async -> Void
    private let endWriteInvalidation: @MainActor () -> Void

    init(
        accountStore: AccountStore,
        artifactCleaner: any SessionArtifactCleaning,
        beginWriteInvalidation: @escaping @MainActor () async -> Void = {},
        endWriteInvalidation: @escaping @MainActor () -> Void = {}
    ) {
        self.accountStore = accountStore
        self.artifactCleaner = artifactCleaner
        self.beginWriteInvalidation = beginWriteInvalidation
        self.endWriteInvalidation = endWriteInvalidation
    }

    convenience init(
        accountStore: AccountStore,
        beginWriteInvalidation: @escaping @MainActor () async -> Void = {},
        endWriteInvalidation: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            accountStore: accountStore,
            artifactCleaner: LiveSessionArtifactCleaner(),
            beginWriteInvalidation: beginWriteInvalidation,
            endWriteInvalidation: endWriteInvalidation
        )
    }

    /// AccountStore publishes the signed-out state only after every other
    /// persisted session artifact has been cleared successfully.
    func logOut() async throws {
        await beginWriteInvalidation()
        do {
            try await artifactCleaner.clear()
            try await accountStore.clear()
        } catch {
            endWriteInvalidation()
            throw error
        }
        // Keep writes blocked while signed out. RootView releases the barrier
        // only after a non-nil account has become the active session.
    }
}
