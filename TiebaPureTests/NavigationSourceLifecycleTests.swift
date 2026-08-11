import XCTest
@testable import TiebaPure

final class NavigationSourceLifecycleTests: XCTestCase {
    func testLocalDestinationKeepsSourceAliveUntilItReappears() {
        var state = NavigationSourceLifecycleState()

        XCTAssertFalse(state.shouldTearDown(isPresentingLocalDestination: true))

        state.didAppear()
        XCTAssertTrue(state.shouldTearDown(isPresentingLocalDestination: false))
    }

    func testParentDestinationKeepsSourceAliveUntilItReappears() {
        var state = NavigationSourceLifecycleState()

        state.beginParentNavigation()
        XCTAssertFalse(state.shouldTearDown(isPresentingLocalDestination: false))

        state.didAppear()
        XCTAssertTrue(state.shouldTearDown(isPresentingLocalDestination: false))
    }

    func testNavigationGestureControllerHostsEdgeSystemsOrExplicitDisable() {
        XCTAssertTrue(
            NavigationPopGestureControlHostingPolicy.requiresController(
                systemMajorVersion: 16,
                isEnabled: true
            )
        )
        XCTAssertTrue(
            NavigationPopGestureControlHostingPolicy.requiresController(
                systemMajorVersion: 18,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            NavigationPopGestureControlHostingPolicy.requiresController(
                systemMajorVersion: 26,
                isEnabled: true
            )
        )
        XCTAssertTrue(
            NavigationPopGestureControlHostingPolicy.requiresController(
                systemMajorVersion: 26,
                isEnabled: false
            )
        )
    }

    func testMeHistoryThreadUserPathReturnsOneLevelAtATime() {
        let thread = ReaderSplitThreadRoute(threadID: 101, forumID: 7)
        let user = UserSummary(
            id: 9,
            name: "user",
            displayName: "User",
            portrait: ""
        )
        var path: [MeNavigationRoute] = [.browsingHistory]
        path = MeNavigationPathPolicy.pushing(.thread(thread), onto: path)
        let userRoute = MeNavigationRoute.user(user: user, sourceThreadID: thread.threadID)
        path = MeNavigationPathPolicy.pushing(userRoute, onto: path)

        path = MeNavigationPathPolicy.removingCurrent(userRoute, from: path)

        XCTAssertEqual(path, [.browsingHistory, .thread(thread)])
    }

    func testMeFollowedUserThreadPathReturnsToProfile() {
        let user = UserSummary(
            id: 9,
            name: "user",
            displayName: "User",
            portrait: ""
        )
        let userRoute = MeNavigationRoute.user(user: user, sourceThreadID: nil)
        let thread = ReaderSplitThreadRoute(threadID: 101, forumID: 7)
        var path: [MeNavigationRoute] = [.followedUsers, userRoute]
        path = MeNavigationPathPolicy.pushing(.thread(thread), onto: path)

        path = MeNavigationPathPolicy.removingCurrent(.thread(thread), from: path)

        XCTAssertEqual(path, [.followedUsers, userRoute])
    }
}
