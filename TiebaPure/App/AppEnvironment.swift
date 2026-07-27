import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let accountStore: AccountStore
    let api: any TiebaAPIService
    let logoutCoordinator: LogoutCoordinator

    init(accountStore: AccountStore, api: any TiebaAPIService, logoutCoordinator: LogoutCoordinator) {
        self.accountStore = accountStore
        self.api = api
        self.logoutCoordinator = logoutCoordinator
    }

    static func live() -> AppEnvironment {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_RESET_SEARCH_HISTORY") {
            requireUIFixturePersistence(
                SearchHistoryStore.shared.clear(),
                operation: "清空搜索历史"
            )
        }
        if arguments.contains("UITEST_RESET_BROWSING_HISTORY") {
            requireUIFixturePersistence(
                BrowsingHistoryStore.shared.clear(),
                operation: "清空浏览历史"
            )
        }
        if arguments.contains("UITEST_RESET_LOCAL_THREAD_LIBRARY") {
            requireUIFixturePersistence(
                LocalThreadLibraryStore.shared.clearAll(),
                operation: "清空本机帖子记录"
            )
        }
        if arguments.contains("UITEST_RESET_BLOCKLIST") {
            BlocklistEntryKind.allCases.forEach {
                BlocklistStore.shared.clear(kind: $0)
            }
        }
        if arguments.contains("UITEST_SEED_LOCAL_THREAD_LIBRARY") {
            requireUIFixturePersistence(
                LocalThreadLibraryStore.shared.addFavorite(
                    thread: FixtureTiebaAPI.threads[0],
                    forum: FixtureTiebaAPI.forum
                ),
                operation: "写入帖子收藏夹具"
            )
            requireUIFixturePersistence(
                LocalThreadLibraryStore.shared.recordReadingPosition(
                    threadID: FixtureTiebaAPI.threads[0].id,
                    postID: 2002,
                    floor: 2
                ),
                operation: "写入阅读位置夹具"
            )
        }
        if arguments.contains("UITEST_USE_FIXTURES") {
            return fixture()
        }
#endif
        let keychainService = KeychainAccountStoreService()
        FreshInstallCredentialCleanup(
            defaults: .standard,
            storedCredentialCreationDate: keychainService.storedItemCreationDate,
            sandboxCreationDate: Self.sandboxCreationDate,
            clearStoredCredentials: keychainService.deleteStoredItem
        ).runIfNeeded()
        let accountStore = AccountStore(
            service: MigratingAccountStoreService(
                keychain: keychainService,
                legacyFile: FileAccountStoreService()
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return AppEnvironment(
            accountStore: accountStore,
            api: TiebaAPI(client: TiebaHTTPClient(session: SecureRemoteURLSession.make(
                configuration: configuration,
                redirectScope: .baiduHTTPS
            ))),
            logoutCoordinator: LogoutCoordinator(accountStore: accountStore)
        )
    }

    /// When this install's sandbox came into existence. The Library directory
    /// is created at install time and never by user action, unlike Documents.
    private static func sandboxCreationDate() -> Date? {
        guard let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.creationDate] as? Date
    }

#if DEBUG
    private static func requireUIFixturePersistence(
        _ succeeded: @autoclosure () -> Bool,
        operation: String
    ) {
        guard succeeded() else {
            preconditionFailure("UI 测试夹具持久化失败：\(operation)")
        }
    }

    private static func fixture() -> AppEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let scenario = FixtureScenario(rawValue: environment["TIEBAPURE_FIXTURE_SCENARIO"] ?? "success") ?? .success
        let delay = Int(environment["TIEBAPURE_FIXTURE_DELAY_MS"] ?? "0") ?? 0
        let accountData: Data?
        if environment["TIEBAPURE_FIXTURE_ACCOUNT"] == "loggedIn" {
            accountData = try? JSONEncoder().encode(FixtureTiebaAPI.account)
        } else {
            accountData = nil
        }
        let service = MemoryAccountStoreService(data: accountData)
        let store = AccountStore(service: service)
        return AppEnvironment(
            accountStore: store,
            api: FixtureTiebaAPI(scenario: scenario, delayMilliseconds: delay),
            logoutCoordinator: LogoutCoordinator(accountStore: store, artifactCleaner: FixtureSessionArtifactCleaner())
        )
    }
#endif
}

#if DEBUG
@MainActor
private struct FixtureSessionArtifactCleaner: SessionArtifactCleaning {
    func clear() async throws {}
}
#endif
