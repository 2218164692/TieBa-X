import XCTest
@testable import TiebaPure

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
}
