import XCTest
@testable import TiebaPure

final class HomeNavigationTests: XCTestCase {
    func testBackFromForumThreadKeepsForumAsCurrentRoute() {
        let threadA = ReaderSplitThreadRoute(threadID: 101, forumID: 7)
        let threadB = ReaderSplitThreadRoute(threadID: 202, forumID: 7)
        let forum = Forum(
            id: 7,
            name: "test",
            displayName: "test forum",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )

        var path: [HomeNavigationRoute] = [.thread(threadA)]
        path = HomeNavigationPathPolicy.pushing(.fromForum(forum), onto: path)
        path = HomeNavigationPathPolicy.pushing(.thread(threadB), onto: path)

        path = HomeNavigationPathPolicy.removingCurrent(.thread(threadB), from: path)

        XCTAssertEqual(path, [.thread(threadA), .fromForum(forum)])
    }

    func testStaleRouteRemovalDoesNotPopAnotherLayer() {
        let threadA = ReaderSplitThreadRoute(threadID: 101, forumID: 7)
        let threadB = ReaderSplitThreadRoute(threadID: 202, forumID: 7)
        let path: [HomeNavigationRoute] = [.thread(threadA), .thread(threadB)]

        XCTAssertEqual(
            HomeNavigationPathPolicy.removingCurrent(.thread(threadA), from: path),
            path
        )
    }

    func testInheritedReaderHandlerDoesNotEscapeCompactLocalStack() {
        XCTAssertEqual(
            ForumThreadsOpenRoutingPolicy.destination(
                hasExplicitParentHandler: false,
                hasReaderSplitHandler: true,
                isReaderSplitListColumn: false
            ),
            .localStack
        )
        XCTAssertEqual(
            ForumThreadsOpenRoutingPolicy.destination(
                hasExplicitParentHandler: true,
                hasReaderSplitHandler: true,
                isReaderSplitListColumn: false
            ),
            .parentReader
        )
        XCTAssertEqual(
            ForumThreadsOpenRoutingPolicy.destination(
                hasExplicitParentHandler: false,
                hasReaderSplitHandler: true,
                isReaderSplitListColumn: true
            ),
            .parentReader
        )
    }
}
