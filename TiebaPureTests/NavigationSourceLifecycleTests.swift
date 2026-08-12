import XCTest
import SwiftUI
import UIKit
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

    @MainActor
    func testGestureControlStateChangeKeepsPresentedContentIdentity() async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw XCTSkip("iOS 26 才会在启用状态省略手势控制器")
        }

        let probe = NavigationGestureContentIdentityProbe()
        let host = UIHostingController(
            rootView: NavigationGestureContentIdentityHost(
                isEnabled: true,
                probe: probe
            )
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        await waitForRenderCycle()

        XCTAssertEqual(probe.makeCount, 1)
        XCTAssertEqual(probe.dismantleCount, 0)

        host.rootView = NavigationGestureContentIdentityHost(
            isEnabled: false,
            probe: probe
        )
        await waitForRenderCycle()

        XCTAssertEqual(
            probe.makeCount,
            1,
            "挂载手势控制器不能重建承载系统 sheet 的页面内容"
        )
        XCTAssertEqual(probe.dismantleCount, 0)

        window.isHidden = true
    }

    @MainActor
    private func waitForRenderCycle() async {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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

@MainActor
private final class NavigationGestureContentIdentityProbe {
    var makeCount = 0
    var dismantleCount = 0
}

private struct NavigationGestureContentIdentityHost: View {
    let isEnabled: Bool
    let probe: NavigationGestureContentIdentityProbe

    var body: some View {
        NavigationGestureContentIdentityRepresentable(probe: probe)
            .fullScreenInteractiveNavigationPop(isEnabled: isEnabled)
    }
}

private struct NavigationGestureContentIdentityRepresentable: UIViewRepresentable {
    let probe: NavigationGestureContentIdentityProbe

    func makeUIView(context: Context) -> UIView {
        probe.makeCount += 1
        return NavigationGestureProbeView(probe: probe)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? NavigationGestureProbeView)?.probe.dismantleCount += 1
    }
}

@MainActor
private final class NavigationGestureProbeView: UIView {
    let probe: NavigationGestureContentIdentityProbe

    init(probe: NavigationGestureContentIdentityProbe) {
        self.probe = probe
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
