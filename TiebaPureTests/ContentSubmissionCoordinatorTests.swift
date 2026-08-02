import XCTest
@testable import TiebaPure

@MainActor
final class ContentSubmissionCoordinatorTests: XCTestCase {
    func testFixtureNewThreadMatchingComposerRequestCompletesAndIsVisible() async throws {
        let api = FixtureTiebaAPI()
        let coordinator = ContentSubmissionCoordinator(api: api)
        let account = FixtureTiebaAPI.account
        let request = ContentSubmissionRequest(
            target: .newThread(in: FixtureTiebaAPI.forum),
            title: "UI自动化草稿主题",
            body: "这是一段确定性的夹具正文 #(呵呵)",
            images: []
        )

        let receipt = try await coordinator.submit(account: account, request: request)

        XCTAssertGreaterThan(receipt.threadID, 0)
        XCTAssertNil(receipt.postID)
        XCTAssertFalse(coordinator.isSubmitting(account: account, target: request.target))
        let threads = try await api.forumThreads(
            account: account,
            forumName: FixtureTiebaAPI.forum.name,
            page: 1,
            category: .replyTime
        )
        let submitted = try XCTUnwrap(threads.first(where: { $0.id == receipt.threadID }))
        XCTAssertEqual(submitted.title, request.title)
        XCTAssertEqual(submitted.textPreview, TiebaEmoticon.plainDisplayText(request.body))
    }

    func testIdenticalConcurrentSubmissionsShareOneNetworkWrite() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 120_000_000)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let request = makeRequest(body: "同一次发送")

        let first = Task {
            try await coordinator.submit(account: makeAccount(), request: request)
        }
        await waitUntilFirstWriteStarts(api)
        let second = Task {
            try await coordinator.submit(account: makeAccount(), request: request)
        }

        let firstReceipt = try await first.value
        let secondReceipt = try await second.value

        XCTAssertEqual(firstReceipt, secondReceipt)
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertFalse(coordinator.isSubmitting(account: makeAccount(), target: request.target))
    }

    func testDifferentContentForSameAccountAndTargetIsRejectedWhileSending() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 120_000_000)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let firstRequest = makeRequest(body: "先发送的内容")
        let secondRequest = makeRequest(body: "不同的内容")

        let first = Task {
            try await coordinator.submit(account: makeAccount(), request: firstRequest)
        }
        await waitUntilFirstWriteStarts(api)

        do {
            _ = try await coordinator.submit(account: makeAccount(), request: secondRequest)
            XCTFail("同一目标正在发送不同内容时应拒绝第二次写操作")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .operationInProgress)
        }

        _ = try await first.value
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 1)
    }

    func testOperationKeySeparatesAccountsAndTargets() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 80_000_000)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let firstAccount = makeAccount(uid: "42")
        let secondAccount = makeAccount(uid: "84")
        let firstRequest = makeRequest(body: "账号一")
        let secondAccountRequest = makeRequest(body: "账号二")
        let secondTargetRequest = makeRequest(
            body: "另一个帖子",
            target: makeTarget(threadID: 2_002)
        )

        async let first = coordinator.submit(account: firstAccount, request: firstRequest)
        async let second = coordinator.submit(account: secondAccount, request: secondAccountRequest)
        async let third = coordinator.submit(account: firstAccount, request: secondTargetRequest)
        _ = try await (first, second, third)

        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 3)
        XCTAssertNotEqual(
            ContentSubmissionCoordinator.operationKey(account: firstAccount, target: firstRequest.target),
            ContentSubmissionCoordinator.operationKey(account: secondAccount, target: firstRequest.target)
        )
        XCTAssertNotEqual(
            ContentSubmissionCoordinator.operationKey(account: firstAccount, target: firstRequest.target),
            ContentSubmissionCoordinator.operationKey(account: firstAccount, target: secondTargetRequest.target)
        )
    }

    func testOutcomeUnknownIsPreservedAndNeverAutomaticallyRetried() async {
        let api = SubmissionAPISpy(
            delayNanoseconds: 20_000_000,
            result: .failure(ContentSubmissionError.outcomeUnknown)
        )
        let coordinator = ContentSubmissionCoordinator(api: api)
        let request = makeRequest(body: "结果不明确")

        do {
            _ = try await coordinator.submit(account: makeAccount(), request: request)
            XCTFail("应透传结果不明确错误")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionError, .outcomeUnknown)
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertFalse(coordinator.isSubmitting(account: makeAccount(), target: request.target))
    }

    func testStoredSubmissionContinuesAfterCallingTaskIsCancelled() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 100_000_000)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let account = makeAccount()
        let request = makeRequest(body: "调用页面关闭后继续")

        let caller = Task {
            let receipt = try await coordinator.submit(account: account, request: request)
            try Task.checkCancellation()
            return receipt
        }
        await waitUntilFirstWriteStarts(api)
        caller.cancel()
        _ = try? await caller.value

        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertFalse(coordinator.isSubmitting(account: account, target: request.target))
    }

    func testAccountInvalidationCancelsAndAwaitsStoredSubmission() async {
        let api = SubmissionAPISpy(delayNanoseconds: 5_000_000_000)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let account = makeAccount()
        let request = makeRequest(body: "退出账号前取消")
        let caller = Task {
            try await coordinator.submit(account: account, request: request)
        }
        await waitUntilFirstWriteStarts(api)

        await coordinator.cancelAll(accountID: account.id)

        do {
            _ = try await caller.value
            XCTFail("账号失效后旧写请求应被取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(coordinator.isSubmitting(account: account, target: request.target))
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 1)
    }

    func testAccountInvalidationCancelsAndDrainsRegisteredProfileOrDeleteWrite() async throws {
        let coordinator = ContentSubmissionCoordinator(
            api: SubmissionAPISpy(delayNanoseconds: 0)
        )
        let account = makeAccount()
        let started = expectation(description: "account mutation started")
        let caller = Task {
            try await coordinator.performAccountWrite(account: account, target: .profile) {
                started.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        await fulfillment(of: [started], timeout: 1)

        await coordinator.beginInvalidation(accountID: account.id)

        do {
            try await caller.value
            XCTFail("账号失效前应取消资料修改或删帖写操作")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(coordinator.isInvalidating(accountID: account.id))

        do {
            try await coordinator.performAccountWrite(account: account, target: .profile) {}
            XCTFail("屏障释放前不应接受新的账号写操作")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .sessionTransition)
        }
        coordinator.endInvalidation(accountID: account.id)
        try await coordinator.performAccountWrite(account: account, target: .profile) {}
    }

    func testConcurrentDeleteForSameAccountAndThreadSharesOneWrite() async throws {
        let coordinator = ContentSubmissionCoordinator(
            api: SubmissionAPISpy(delayNanoseconds: 0)
        )
        let account = makeAccount()
        let write = ControlledAccountWriteSpy()

        let first = Task {
            try await coordinator.performAccountWrite(
                account: account,
                target: .deleteThread(1_001),
                coalescesConcurrentCalls: true
            ) {
                try await write.run()
            }
        }
        await write.waitForFirstWrite()

        let secondStarted = expectation(description: "second delete caller entered coordinator")
        let second = Task {
            secondStarted.fulfill()
            try await coordinator.performAccountWrite(
                account: account,
                target: .deleteThread(1_001),
                coalescesConcurrentCalls: true
            ) {
                await write.recordAdditionalWrite()
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        let countWhileFirstWriteIsPending = await write.writeCount()
        XCTAssertEqual(countWhileFirstWriteIsPending, 1)

        await write.releaseFirstWrite()
        try await first.value
        try await second.value
        let finalWriteCount = await write.writeCount()
        XCTAssertEqual(finalWriteCount, 1)
    }

    func testConcurrentProfileWritesAreRejectedInsteadOfCoalesced() async throws {
        let coordinator = ContentSubmissionCoordinator(
            api: SubmissionAPISpy(delayNanoseconds: 0)
        )
        let account = makeAccount()
        let write = ControlledAccountWriteSpy()

        let first = Task {
            try await coordinator.performAccountWrite(account: account, target: .profile) {
                try await write.run()
            }
        }
        await write.waitForFirstWrite()

        do {
            try await coordinator.performAccountWrite(account: account, target: .profile) {
                try await write.run()
            }
            XCTFail("资料写入不能把内容不同的并发操作合并为同一次请求")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .operationInProgress)
        }
        var writeCount = await write.writeCount()
        XCTAssertEqual(writeCount, 1)

        await write.releaseFirstWrite()
        try await first.value
        writeCount = await write.writeCount()
        XCTAssertEqual(writeCount, 1)
    }

    func testAccountInvalidationBlocksOnlyMatchingAccountUntilReleased() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 0)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let firstAccount = makeAccount(uid: "42")
        let secondAccount = makeAccount(uid: "84")
        let request = makeRequest(body: "账号屏障")

        await coordinator.beginInvalidation(accountID: firstAccount.id)

        do {
            _ = try await coordinator.submit(account: firstAccount, request: request)
            XCTFail("账号状态切换期间不应接受该账号的新写操作")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .sessionTransition)
            XCTAssertEqual(error.localizedDescription, "账号状态正在切换，请稍后重试。")
        }
        _ = try await coordinator.submit(account: secondAccount, request: request)

        coordinator.endInvalidation(accountID: firstAccount.id)
        _ = try await coordinator.submit(account: firstAccount, request: request)
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 2)
    }

    func testNestedGlobalInvalidationRequiresMatchingReleaseAndExtraReleaseIsSafe() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 0)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let account = makeAccount()
        let request = makeRequest(body: "全局屏障")

        await coordinator.beginInvalidation()
        await coordinator.beginInvalidation()
        coordinator.endInvalidation()

        for blockedAccount in [account, makeAccount(uid: "84")] {
            do {
                _ = try await coordinator.submit(account: blockedAccount, request: request)
                XCTFail("嵌套全局屏障尚未完全释放时不应接受任何账号的发送")
            } catch {
                XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .sessionTransition)
            }
        }

        coordinator.endInvalidation()
        coordinator.endInvalidation()
        _ = try await coordinator.submit(account: account, request: request)
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 1)
    }

    func testCancelAllBlocksReentrantSubmissionWhileDrainIsAwaitingNetworkTask() async throws {
        let api = ControlledSubmissionAPISpy()
        let coordinator = ContentSubmissionCoordinator(api: api)
        let account = makeAccount()
        let firstRequest = makeRequest(body: "正在排空")
        let reentrantRequest = makeRequest(
            body: "排空期间的新请求",
            target: makeTarget(threadID: 2_002)
        )
        let first = Task {
            try await coordinator.submit(account: account, request: firstRequest)
        }
        await api.waitForFirstSubmission()

        let cancellation = Task {
            await coordinator.cancelAll(accountID: account.id)
        }
        for _ in 0..<100 where coordinator.isInvalidating(accountID: account.id) == false {
            await Task.yield()
        }
        XCTAssertTrue(coordinator.isInvalidating(accountID: account.id))

        do {
            _ = try await coordinator.submit(account: account, request: reentrantRequest)
            XCTFail("排空网络任务时不应允许新的同账号写操作进入")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .sessionTransition)
        }
        let countWhileDraining = await api.submissionCount()
        XCTAssertEqual(countWhileDraining, 1)

        await api.releaseFirstSubmission()
        await cancellation.value
        do {
            _ = try await first.value
            XCTFail("排空的旧写操作应收到取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        _ = try await coordinator.submit(account: account, request: reentrantRequest)
        let finalCount = await api.submissionCount()
        XCTAssertEqual(finalCount, 2)
    }

    func testTwoPhaseBarrierRejectsSocialWriteWhileContentDrainIsBlocked() async throws {
        let api = ControlledSubmissionAPISpy()
        let contentCoordinator = ContentSubmissionCoordinator(api: api)
        let socialState = SocialRelationshipState()
        let socialCoordinator = SocialMutationCoordinator(api: api, state: socialState)
        let account = makeAccount()
        let request = makeRequest(body: "注销时正在发送")
        let user = UserSummary(
            id: 99,
            name: "fixture_user",
            displayName: "合成用户",
            portrait: "fixture.portrait"
        )
        let submission = Task {
            try await contentCoordinator.submit(account: account, request: request)
        }
        await api.waitForFirstSubmission()

        socialCoordinator.establishInvalidationBarrier()
        contentCoordinator.establishInvalidationBarrier()
        let socialDrain = Task { @MainActor in
            await socialCoordinator.drainInvalidatedOperations()
        }
        let contentDrain = Task { @MainActor in
            await contentCoordinator.drainInvalidatedOperations()
        }
        await Task.yield()

        XCTAssertTrue(contentCoordinator.isInvalidating(accountID: account.id))
        XCTAssertTrue(socialCoordinator.isInvalidating(session: account.sessionIdentity))
        do {
            try await socialCoordinator.setUserFollowed(
                account: account,
                user: user,
                followed: true
            )
            XCTFail("内容排空仍被阻塞时，社交写入口也必须已经关闭")
        } catch {
            XCTAssertEqual(error as? SocialMutationCoordinatorError, .sessionTransition)
        }
        XCTAssertFalse(socialState.isUserMutationPending(accountID: account.id, user: user))

        await api.releaseFirstSubmission()
        await socialDrain.value
        await contentDrain.value
        do {
            _ = try await submission.value
            XCTFail("排空的旧内容写操作应收到取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        contentCoordinator.endInvalidation()
        socialCoordinator.endInvalidation()
    }

    @MainActor
    func testLogoutCancelsStoredWriteBeforeClearingSession() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 100_000_000)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let account = makeAccount()
        let request = makeRequest(body: "注销前取消")
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(account)
        let cleaner = SubmissionAwareArtifactCleaner {
            coordinator.isSubmitting(account: account, target: request.target) == false
        }
        let logout = LogoutCoordinator(
            accountStore: store,
            artifactCleaner: cleaner,
            beginWriteInvalidation: { await coordinator.beginInvalidation() },
            endWriteInvalidation: { coordinator.endInvalidation() }
        )
        let caller = Task {
            try await coordinator.submit(account: account, request: request)
        }
        await waitUntilFirstWriteStarts(api)

        try await logout.logOut()

        XCTAssertTrue(cleaner.observedNoActiveWrite)
        let storedAccount = try await store.load()
        XCTAssertNil(storedAccount)
        do {
            _ = try await caller.value
            XCTFail("注销前应取消尚未完成的写请求")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        do {
            _ = try await coordinator.submit(account: account, request: request)
            XCTFail("注销成功后、重新登录前应保持写操作屏障")
        } catch {
            XCTAssertEqual(error as? ContentSubmissionCoordinatorError, .sessionTransition)
        }

        coordinator.endInvalidation()
        _ = try await coordinator.submit(account: account, request: request)
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 2)
    }

    func testLogoutFailureReleasesGlobalSubmissionBarrier() async throws {
        let api = SubmissionAPISpy(delayNanoseconds: 0)
        let coordinator = ContentSubmissionCoordinator(api: api)
        let account = makeAccount()
        let request = makeRequest(body: "注销失败后重试")
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(account)
        let logout = LogoutCoordinator(
            accountStore: store,
            artifactCleaner: SubmissionFailingArtifactCleaner(),
            beginWriteInvalidation: { await coordinator.beginInvalidation() },
            endWriteInvalidation: { coordinator.endInvalidation() }
        )

        do {
            try await logout.logOut()
            XCTFail("清理失败时注销应失败")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotRemoveFile)
        }

        _ = try await coordinator.submit(account: account, request: request)
        let submissionCount = await api.submissionCount()
        let storedAccount = try await store.load()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(storedAccount, account)
    }

    private func waitUntilFirstWriteStarts(_ api: SubmissionAPISpy) async {
        for _ in 0..<100 {
            guard await api.submissionCount() == 0 else { break }
            await Task.yield()
        }
        let submissionCount = await api.submissionCount()
        XCTAssertEqual(submissionCount, 1)
    }

    private func makeAccount(uid: String = "42") -> Account {
        Account(
            uid: uid,
            name: "fixture_\(uid)",
            displayName: "合成账号\(uid)",
            portrait: "",
            bduss: "fixture-bduss",
            stoken: "fixture-stoken",
            baiduID: "fixture-baiduid",
            tbs: "fixture-tbs"
        )
    }

    private func makeTarget(threadID: Int64 = 1_001) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: .threadReply,
            forumID: 101,
            forumName: "测试",
            forumDisplayName: "测试吧",
            threadID: threadID,
            threadTitle: "确定性测试帖",
            parentPostID: nil,
            parentFloor: nil,
            subpostID: nil,
            replyUserID: nil,
            replyUserDisplayName: nil
        )
    }

    private func makeRequest(
        body: String,
        target: ContentSubmissionTarget? = nil
    ) -> ContentSubmissionRequest {
        ContentSubmissionRequest(
            target: target ?? makeTarget(),
            title: "",
            body: body,
            images: []
        )
    }
}

private actor ControlledAccountWriteSpy {
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async throws {
        count += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        try Task.checkCancellation()
    }

    func waitForFirstWrite() async {
        guard count == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        continuation?.resume()
        continuation = nil
    }

    func recordAdditionalWrite() {
        count += 1
    }

    func writeCount() -> Int {
        count
    }
}

@MainActor
private final class SubmissionAwareArtifactCleaner: SessionArtifactCleaning {
    private let noActiveWrite: () -> Bool
    private(set) var observedNoActiveWrite = false

    init(noActiveWrite: @escaping () -> Bool) {
        self.noActiveWrite = noActiveWrite
    }

    func clear() async throws {
        observedNoActiveWrite = noActiveWrite()
    }
}

@MainActor
private struct SubmissionFailingArtifactCleaner: SessionArtifactCleaning {
    func clear() async throws {
        throw URLError(.cannotRemoveFile)
    }
}

private actor ControlledSubmissionAPISpy: TiebaAPIService {
    private var count = 0
    private var firstSubmissionContinuation: CheckedContinuation<Void, Never>?
    private var firstSubmissionWaiters: [CheckedContinuation<Void, Never>] = []

    func submissionCount() -> Int {
        count
    }

    func waitForFirstSubmission() async {
        guard count == 0 else { return }
        await withCheckedContinuation { continuation in
            firstSubmissionWaiters.append(continuation)
        }
    }

    func releaseFirstSubmission() {
        firstSubmissionContinuation?.resume()
        firstSubmissionContinuation = nil
    }

    func submitContent(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt {
        _ = account
        _ = request
        count += 1
        if count == 1 {
            let waiters = firstSubmissionWaiters
            firstSubmissionWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstSubmissionContinuation = continuation
            }
            try Task.checkCancellation()
        }
        return ContentSubmissionReceipt(threadID: 1_001, postID: 9_001)
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
    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws { fatalError("unused") }
    func userRelationships(account: Account?, userID: Int64, kind: UserRelationshipKind, page: Int) async throws -> UserRelationshipPage { fatalError("unused") }
    func forumMembership(account: Account, forum: Forum) async throws -> ForumMembership { fatalError("unused") }
    func setForumFollowed(account: Account, forum: Forum, followed: Bool) async throws -> ForumMembership { fatalError("unused") }
    func messages(account: Account, kind: MessageKind, page: Int) async throws -> MessagesPage { fatalError("unused") }
    func setPostLiked(account: Account, threadID: Int64, postID: UInt64, objectType: TiebaLikeObjectType, liked: Bool) async throws { fatalError("unused") }
}

private actor SubmissionAPISpy: TiebaAPIService {
    private var count = 0
    private let delayNanoseconds: UInt64
    private let result: Result<ContentSubmissionReceipt, Error>

    init(
        delayNanoseconds: UInt64,
        result: Result<ContentSubmissionReceipt, Error> = .success(
            ContentSubmissionReceipt(threadID: 1_001, postID: 9_001)
        )
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func submissionCount() -> Int {
        count
    }

    func submitContent(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt {
        _ = account
        _ = request
        count += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
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
    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws { fatalError("unused") }
    func userRelationships(account: Account?, userID: Int64, kind: UserRelationshipKind, page: Int) async throws -> UserRelationshipPage { fatalError("unused") }
    func forumMembership(account: Account, forum: Forum) async throws -> ForumMembership { fatalError("unused") }
    func setForumFollowed(account: Account, forum: Forum, followed: Bool) async throws -> ForumMembership { fatalError("unused") }
    func messages(account: Account, kind: MessageKind, page: Int) async throws -> MessagesPage { fatalError("unused") }
    func setPostLiked(account: Account, threadID: Int64, postID: UInt64, objectType: TiebaLikeObjectType, liked: Bool) async throws { fatalError("unused") }
}
