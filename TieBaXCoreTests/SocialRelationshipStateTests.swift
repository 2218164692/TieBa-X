import XCTest
@testable import TieBaX

@MainActor
final class SocialRelationshipStateTests: XCTestCase {
    func testForumStateMatchesResolvedIDAndOriginalNameWithoutCrossingAccounts() {
        let state = SocialRelationshipState()
        let unresolved = makeForum(id: 0)
        let resolved = makeForum(id: 73)

        state.recordForumFollow(accountID: "account-a", forum: resolved, isFollowed: true)

        XCTAssertEqual(state.forumFollowState(accountID: "account-a", forum: unresolved), true)
        XCTAssertEqual(state.forumFollowState(accountID: "account-a", forum: resolved), true)
        XCTAssertNil(state.forumFollowState(accountID: "account-b", forum: resolved))
        XCTAssertTrue(SocialRelationshipState.sameForum(unresolved, resolved))
    }

    func testUserStateMatchesIDAndPortraitAliasesAndCanBeResetPerAccount() {
        let state = SocialRelationshipState()
        let identified = makeUser(id: 99)
        let portraitOnly = makeUser(id: 0)

        state.recordUserFollow(accountID: "account-a", user: identified, isFollowed: true)

        XCTAssertEqual(state.userFollowState(accountID: "account-a", user: portraitOnly), true)
        XCTAssertNil(state.userFollowState(accountID: "account-b", user: identified))
        XCTAssertTrue(SocialRelationshipState.sameUser(identified, portraitOnly))

        state.reset(accountID: "account-a")
        XCTAssertNil(state.userFollowState(accountID: "account-a", user: identified))
    }

    func testDifferentUserIDsNeverAliasThroughTheSameDisplayName() {
        let state = SocialRelationshipState()
        let first = UserSummary(id: 1, name: "same", displayName: "同名", portrait: "first")
        let second = UserSummary(id: 2, name: "same", displayName: "同名", portrait: "second")

        state.recordUserFollow(accountID: "account-a", user: first, isFollowed: true)

        XCTAssertFalse(SocialRelationshipState.sameUser(first, second))
        XCTAssertNil(state.userFollowState(accountID: "account-a", user: second))
    }

    func testLocalForumOverrideWinsOverLateServerList() {
        let state = SocialRelationshipState()
        let forum = makeForum(id: 73)

        state.recordForumFollow(accountID: "account-a", forum: forum, isFollowed: false)
        let reconciled = state.reconciledFollowedForums(accountID: "account-a", loaded: [forum])

        XCTAssertTrue(reconciled.isEmpty)
        XCTAssertEqual(state.forumFollowOverride(accountID: "account-a", forum: forum), false)
    }

    func testLocalUserOverrideWinsOverLateFollowingList() {
        let state = SocialRelationshipState()
        let user = makeUser(id: 99)

        state.recordUserFollow(accountID: "account-a", user: user, isFollowed: false)
        let reconciled = state.reconciledFollowingUsers(accountID: "account-a", loaded: [user])

        XCTAssertTrue(reconciled.isEmpty)
        XCTAssertEqual(state.userFollowOverride(accountID: "account-a", user: user), false)
    }

    func testMutationActivityIsAccountScoped() {
        let state = SocialRelationshipState()
        let forum = makeForum(id: 73)

        state.beginForumMutation(accountID: "account-a", forum: forum)
        XCTAssertTrue(state.isForumMutationPending(accountID: "account-a", forum: forum))
        XCTAssertFalse(state.isForumMutationPending(accountID: "account-b", forum: forum))

        state.endForumMutation(accountID: "account-a", forum: forum)
        XCTAssertFalse(state.isForumMutationPending(accountID: "account-a", forum: forum))
    }

    func testCoordinatorFinishesUserMutationAfterCallingViewTaskIsCancelled() async throws {
        let state = SocialRelationshipState()
        let api = FixtureTiebaAPI(delayMilliseconds: 120)
        let coordinator = SocialMutationCoordinator(api: api, state: state)
        let account = FixtureTiebaAPI.account
        let user = makeUser(id: 99)

        let callingTask = Task {
            try await coordinator.setUserFollowed(account: account, user: user, followed: true)
            try Task.checkCancellation()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        callingTask.cancel()
        _ = try? await callingTask.value

        XCTAssertEqual(state.userFollowState(accountID: account.id, user: user), true)
        XCTAssertFalse(state.isUserMutationPending(accountID: account.id, user: user))
    }

    func testCoordinatorFinishesForumMutationAfterCallingViewTaskIsCancelled() async throws {
        let state = SocialRelationshipState()
        let api = FixtureTiebaAPI(delayMilliseconds: 120)
        let coordinator = SocialMutationCoordinator(api: api, state: state)
        let account = FixtureTiebaAPI.account
        let forum = makeForum(id: 73)

        let callingTask = Task {
            _ = try await coordinator.setForumFollowed(
                account: account,
                forum: forum,
                followed: false
            )
            try Task.checkCancellation()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        callingTask.cancel()
        _ = try? await callingTask.value

        XCTAssertEqual(state.forumFollowState(accountID: account.id, forum: forum), false)
        XCTAssertFalse(state.isForumMutationPending(accountID: account.id, forum: forum))
    }

    func testSameUIDCredentialReplacementCancelsOldMutationAndRejectsItsLateResult() async throws {
        let state = SocialRelationshipState()
        let api = ControlledSocialMutationAPI()
        let coordinator = SocialMutationCoordinator(api: api, state: state)
        let oldAccount = makeAccount(credential: "old")
        let replacementAccount = makeAccount(credential: "replacement")
        let user = makeUser(id: 99)

        let oldMutation = Task {
            try await coordinator.setUserFollowed(
                account: oldAccount,
                user: user,
                followed: true
            )
        }
        await api.waitForFirstUserMutation()

        let invalidation = Task {
            await coordinator.beginInvalidation(session: oldAccount.sessionIdentity)
        }
        await waitForInvalidation(coordinator, session: oldAccount.sessionIdentity)

        do {
            try await coordinator.setUserFollowed(
                account: oldAccount,
                user: user,
                followed: true
            )
            XCTFail("旧会话处于切换屏障时不应接受新的社交写操作")
        } catch {
            XCTAssertEqual(error as? SocialMutationCoordinatorError, .sessionTransition)
        }

        await api.releaseFirstUserMutation()
        await invalidation.value
        do {
            try await oldMutation.value
            XCTFail("忽略网络取消后晚到的旧会话结果不应成功返回")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(state.userFollowState(accountID: oldAccount.id, user: user))
        XCTAssertFalse(state.isUserMutationPending(accountID: oldAccount.id, user: user))

        coordinator.endInvalidation(session: oldAccount.sessionIdentity)
        try await coordinator.setUserFollowed(
            account: replacementAccount,
            user: user,
            followed: true
        )
        XCTAssertEqual(state.userFollowState(accountID: replacementAccount.id, user: user), true)
        let sessions = await api.userMutationSessions()
        XCTAssertEqual(sessions, [oldAccount.sessionIdentity, replacementAccount.sessionIdentity])
    }

    func testLogoutDrainsSocialMutationAndKeepsGlobalBarrierUntilNewSessionIsVisible() async throws {
        let state = SocialRelationshipState()
        let api = ControlledSocialMutationAPI()
        let coordinator = SocialMutationCoordinator(api: api, state: state)
        let account = makeAccount(credential: "logout")
        let replacementAccount = makeAccount(credential: "replacement")
        let user = makeUser(id: 99)
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(account)
        let cleaner = SocialMutationAwareArtifactCleaner {
            state.isUserMutationPending(accountID: account.id, user: user) == false
        }
        let logout = LogoutCoordinator(
            accountStore: store,
            artifactCleaner: cleaner,
            beginWriteInvalidation: { await coordinator.beginInvalidation() },
            endWriteInvalidation: { coordinator.endInvalidation() }
        )

        let mutation = Task {
            try await coordinator.setUserFollowed(account: account, user: user, followed: true)
        }
        await api.waitForFirstUserMutation()
        let logoutTask = Task {
            try await logout.logOut()
        }
        await waitForInvalidation(coordinator, session: account.sessionIdentity)

        await api.releaseFirstUserMutation()
        try await logoutTask.value
        XCTAssertTrue(cleaner.observedNoActiveMutation)
        let storedAccount = try await store.load()
        XCTAssertNil(storedAccount)
        do {
            try await mutation.value
            XCTFail("注销排空的旧社交写操作应收到取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(state.userFollowState(accountID: account.id, user: user))

        do {
            try await coordinator.setUserFollowed(
                account: replacementAccount,
                user: user,
                followed: true
            )
            XCTFail("注销成功后、新会话显示前应保持全局社交写屏障")
        } catch {
            XCTAssertEqual(error as? SocialMutationCoordinatorError, .sessionTransition)
        }

        coordinator.endInvalidation()
        try await coordinator.setUserFollowed(
            account: replacementAccount,
            user: user,
            followed: true
        )
        XCTAssertEqual(state.userFollowState(accountID: account.id, user: user), true)
    }

    func testLogoutFailureReleasesGlobalSocialBarrier() async throws {
        let state = SocialRelationshipState()
        let api = ControlledSocialMutationAPI(blocksFirstUserMutation: false)
        let coordinator = SocialMutationCoordinator(api: api, state: state)
        let account = makeAccount(credential: "failure")
        let user = makeUser(id: 99)
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(account)
        let logout = LogoutCoordinator(
            accountStore: store,
            artifactCleaner: FailingSocialArtifactCleaner(),
            beginWriteInvalidation: { await coordinator.beginInvalidation() },
            endWriteInvalidation: { coordinator.endInvalidation() }
        )

        do {
            try await logout.logOut()
            XCTFail("清理失败时注销应失败")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotRemoveFile)
        }

        try await coordinator.setUserFollowed(account: account, user: user, followed: true)
        XCTAssertEqual(state.userFollowState(accountID: account.id, user: user), true)
        let storedAccount = try await store.load()
        XCTAssertEqual(storedAccount, account)
    }

    func testNestedInvalidationRequiresMatchingRelease() async throws {
        let state = SocialRelationshipState()
        let api = ControlledSocialMutationAPI(blocksFirstUserMutation: false)
        let coordinator = SocialMutationCoordinator(api: api, state: state)
        let account = makeAccount(credential: "nested")
        let user = makeUser(id: 99)

        await coordinator.beginInvalidation(session: account.sessionIdentity)
        await coordinator.beginInvalidation(session: account.sessionIdentity)
        coordinator.endInvalidation(session: account.sessionIdentity)

        do {
            try await coordinator.setUserFollowed(account: account, user: user, followed: true)
            XCTFail("嵌套会话屏障尚未完全释放")
        } catch {
            XCTAssertEqual(error as? SocialMutationCoordinatorError, .sessionTransition)
        }

        coordinator.endInvalidation(session: account.sessionIdentity)
        coordinator.endInvalidation(session: account.sessionIdentity)
        try await coordinator.setUserFollowed(account: account, user: user, followed: true)
        XCTAssertEqual(state.userFollowState(accountID: account.id, user: user), true)
    }

    func testAccountTransitionPolicyInvalidatesExactOldSessionOnlyForCredentialChanges() {
        let oldAccount = makeAccount(credential: "old")
        var metadataUpdate = oldAccount
        metadataUpdate.displayName = "新昵称"
        metadataUpdate.tbs = "refreshed-tbs"
        let replacementAccount = makeAccount(credential: "replacement")

        XCTAssertNil(AccountTransitionPolicy.invalidatedSession(
            previous: oldAccount,
            next: metadataUpdate
        ))
        XCTAssertEqual(AccountTransitionPolicy.invalidatedSession(
            previous: oldAccount,
            next: replacementAccount
        ), oldAccount.sessionIdentity)
        XCTAssertNotEqual(oldAccount.sessionIdentity, replacementAccount.sessionIdentity)
    }

    func testGlobalInvalidationRejectsLateForumAndLikeResults() async throws {
        let state = SocialRelationshipState()
        let api = ControlledSocialMutationAPI(blocksFirstUserMutation: false)
        let coordinator = SocialMutationCoordinator(api: api, state: state)
        let account = makeAccount(credential: "global")
        let forum = makeForum(id: 73)

        let forumMutation = Task {
            try await coordinator.setForumFollowed(
                account: account,
                forum: forum,
                followed: true
            )
        }
        let likeMutation = Task {
            try await coordinator.setPostLiked(
                account: account,
                threadID: 1_001,
                postID: 9_001,
                objectType: .post,
                liked: true
            )
        }
        await api.waitForFirstForumMutation()
        await api.waitForFirstLikeMutation()

        let invalidation = Task {
            await coordinator.beginInvalidation()
        }
        await waitForInvalidation(coordinator, session: account.sessionIdentity)
        await api.releaseFirstForumMutation()
        await api.releaseFirstLikeMutation()
        await invalidation.value

        do {
            _ = try await forumMutation.value
            XCTFail("全局屏障不应提交晚到的吧关注结果")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            try await likeMutation.value
            XCTFail("全局屏障不应接受晚到的点赞结果")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(state.forumFollowState(accountID: account.id, forum: forum))
        XCTAssertFalse(state.isForumMutationPending(accountID: account.id, forum: forum))
        coordinator.endInvalidation()
    }

    func testLikeSettingRejectsBeforeNetworkAndObservesLiveValue() async throws {
        var likesEnabled = false
        let state = SocialRelationshipState()
        let api = ControlledSocialMutationAPI(blocksFirstUserMutation: false)
        let coordinator = SocialMutationCoordinator(
            api: api,
            state: state,
            allowsLikes: { likesEnabled }
        )
        let account = makeAccount(credential: "like-setting")

        do {
            try await coordinator.setPostLiked(
                account: account,
                threadID: 1_001,
                postID: 9_001,
                objectType: .post,
                liked: true
            )
            XCTFail("关闭点赞开关后不应进入网络层")
        } catch {
            XCTAssertEqual(error as? SocialMutationCoordinatorError, .likesDisabled)
        }
        let didStartWhileDisabled = await api.hasStartedLikeMutation()
        XCTAssertFalse(didStartWhileDisabled)

        likesEnabled = true
        let mutation = Task {
            try await coordinator.setPostLiked(
                account: account,
                threadID: 1_001,
                postID: 9_001,
                objectType: .post,
                liked: true
            )
        }
        await api.waitForFirstLikeMutation()
        let didStartAfterEnabling = await api.hasStartedLikeMutation()
        XCTAssertTrue(didStartAfterEnabling)
        await api.releaseFirstLikeMutation()
        try await mutation.value
    }

    func testTwoPhaseBarrierRejectsContentWriteWhileSocialDrainIsBlocked() async throws {
        let state = SocialRelationshipState()
        let api = ControlledSocialMutationAPI()
        let socialCoordinator = SocialMutationCoordinator(api: api, state: state)
        let contentCoordinator = ContentSubmissionCoordinator(api: api)
        let account = makeAccount(credential: "two-phase")
        let user = makeUser(id: 99)
        let mutation = Task {
            try await socialCoordinator.setUserFollowed(
                account: account,
                user: user,
                followed: true
            )
        }
        await api.waitForFirstUserMutation()

        socialCoordinator.establishInvalidationBarrier()
        contentCoordinator.establishInvalidationBarrier()
        let socialDrain = Task { @MainActor in
            await socialCoordinator.drainInvalidatedOperations()
        }
        let contentDrain = Task { @MainActor in
            await contentCoordinator.drainInvalidatedOperations()
        }
        await Task.yield()

        XCTAssertTrue(socialCoordinator.isInvalidating(session: account.sessionIdentity))
        XCTAssertTrue(contentCoordinator.isInvalidating(accountID: account.id))
        do {
            try await contentCoordinator.performAccountWrite(
                account: account,
                target: .profile
            ) {
                XCTFail("屏障建立后不应启动新的内容写任务")
            }
            XCTFail("社交排空仍被阻塞时，内容写入口也必须已经关闭")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .sessionTransition)
        }

        await api.releaseFirstUserMutation()
        await socialDrain.value
        await contentDrain.value
        do {
            try await mutation.value
            XCTFail("排空的旧社交写操作应收到取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        contentCoordinator.endInvalidation()
        socialCoordinator.endInvalidation()
    }

    private func makeForum(id: Int64) -> Forum {
        Forum(
            id: id,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
    }

    private func makeUser(id: Int64) -> UserSummary {
        UserSummary(
            id: id,
            name: "fixture_user",
            displayName: "合成用户",
            portrait: "fixture.portrait"
        )
    }

    private func makeAccount(credential: String) -> Account {
        Account(
            uid: "42",
            name: "fixture_user",
            displayName: "合成账号",
            portrait: "fixture.portrait",
            bduss: "bduss-\(credential)",
            stoken: "stoken-\(credential)",
            baiduID: "baiduid-\(credential)",
            tbs: "tbs-\(credential)"
        )
    }

    private func waitForInvalidation(
        _ coordinator: SocialMutationCoordinator,
        session: AccountSessionIdentity
    ) async {
        for _ in 0..<100 where coordinator.isInvalidating(session: session) == false {
            await Task.yield()
        }
        XCTAssertTrue(coordinator.isInvalidating(session: session))
    }
}

@MainActor
private final class SocialMutationAwareArtifactCleaner: SessionArtifactCleaning {
    private let noActiveMutation: () -> Bool
    private(set) var observedNoActiveMutation = false

    init(noActiveMutation: @escaping () -> Bool) {
        self.noActiveMutation = noActiveMutation
    }

    func clear() async throws {
        observedNoActiveMutation = noActiveMutation()
    }
}

@MainActor
private struct FailingSocialArtifactCleaner: SessionArtifactCleaning {
    func clear() async throws {
        throw URLError(.cannotRemoveFile)
    }
}

private actor ControlledSocialMutationAPI: TiebaAPIService {
    private let blocksFirstUserMutation: Bool
    private var userSessions: [AccountSessionIdentity] = []
    private var firstUserContinuation: CheckedContinuation<Void, Never>?
    private var firstUserWaiters: [CheckedContinuation<Void, Never>] = []
    private var forumMutationStarted = false
    private var firstForumContinuation: CheckedContinuation<Void, Never>?
    private var firstForumWaiters: [CheckedContinuation<Void, Never>] = []
    private var likeMutationStarted = false
    private var firstLikeContinuation: CheckedContinuation<Void, Never>?
    private var firstLikeWaiters: [CheckedContinuation<Void, Never>] = []

    init(blocksFirstUserMutation: Bool = true) {
        self.blocksFirstUserMutation = blocksFirstUserMutation
    }

    func waitForFirstUserMutation() async {
        guard userSessions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstUserWaiters.append(continuation)
        }
    }

    func releaseFirstUserMutation() {
        firstUserContinuation?.resume()
        firstUserContinuation = nil
    }

    func userMutationSessions() -> [AccountSessionIdentity] {
        userSessions
    }

    func waitForFirstForumMutation() async {
        guard forumMutationStarted == false else { return }
        await withCheckedContinuation { continuation in
            firstForumWaiters.append(continuation)
        }
    }

    func releaseFirstForumMutation() {
        firstForumContinuation?.resume()
        firstForumContinuation = nil
    }

    func waitForFirstLikeMutation() async {
        guard likeMutationStarted == false else { return }
        await withCheckedContinuation { continuation in
            firstLikeWaiters.append(continuation)
        }
    }

    func hasStartedLikeMutation() -> Bool {
        likeMutationStarted
    }

    func releaseFirstLikeMutation() {
        firstLikeContinuation?.resume()
        firstLikeContinuation = nil
    }

    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws {
        _ = user
        _ = followed
        userSessions.append(account.sessionIdentity)
        let callNumber = userSessions.count
        let waiters = firstUserWaiters
        firstUserWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if blocksFirstUserMutation, callNumber == 1 {
            // Deliberately ignore task cancellation to prove the coordinator's
            // commit barrier rejects a late success from the stale session.
            await withCheckedContinuation { continuation in
                firstUserContinuation = continuation
            }
        }
    }

    func validateLogin(cookies: BaiduCookies) async throws -> Account { fatalError("unused") }
    func personalizedThreads(account: Account?, page: Int, loadType: Int) async throws -> [ThreadSummary] { fatalError("unused") }
    func followedForums(account: Account) async throws -> [Forum] { fatalError("unused") }
    func forumThreads(account: Account?, forumName: String, page: Int, category: ForumThreadCategory) async throws -> [ThreadSummary] { fatalError("unused") }
    func searchThreads(keyword: String, page: Int, sortType: Int, filterType: Int, forumName: String?, pageSize: Int) async throws -> SearchResultsPage { fatalError("unused") }
    func resolveUser(named name: String) async throws -> UserSummary { fatalError("unused") }
    func threadPage(account: Account?, threadID: Int64, page: Int, forumID: Int64?, postID: UInt64?, seeLz: Bool, sortType: ThreadReplySort) async throws -> ThreadPage { fatalError("unused") }
    func subposts(account: Account?, threadID: Int64, postID: UInt64, forumID: Int64, page: Int, subpostID: UInt64) async throws -> [Subpost] { fatalError("unused") }
    func userProfile(account: Account?, user: UserSummary) async throws -> UserProfile { fatalError("unused") }
    func userThreads(account: Account?, userID: Int64, page: Int) async throws -> UserThreadsPage { fatalError("unused") }
    func userRelationships(account: Account?, userID: Int64, kind: UserRelationshipKind, page: Int) async throws -> UserRelationshipPage { fatalError("unused") }
    func forumMembership(account: Account, forum: Forum) async throws -> ForumMembership { fatalError("unused") }
    func setForumFollowed(account: Account, forum: Forum, followed: Bool) async throws -> ForumMembership {
        _ = account
        forumMutationStarted = true
        let waiters = firstForumWaiters
        firstForumWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstForumContinuation = continuation
        }
        return ForumMembership(forumID: forum.id, isFollowed: followed)
    }
    func messages(account: Account, kind: MessageKind, page: Int) async throws -> MessagesPage { fatalError("unused") }
    func setPostLiked(account: Account, threadID: Int64, postID: UInt64, objectType: TiebaLikeObjectType, liked: Bool) async throws {
        _ = account
        _ = threadID
        _ = postID
        _ = objectType
        _ = liked
        likeMutationStarted = true
        let waiters = firstLikeWaiters
        firstLikeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstLikeContinuation = continuation
        }
    }
    func submitContent(account: Account, request: ContentSubmissionRequest) async throws -> ContentSubmissionReceipt { fatalError("unused") }
}
