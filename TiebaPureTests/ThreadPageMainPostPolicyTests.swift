import XCTest
@testable import TiebaPure

final class ThreadPageMainPostPolicyTests: XCTestCase {
    func testLaterPageKeepsAlreadyLoadedMainPost() {
        let main = makePost(id: 100, floor: 1)
        let reply = makePost(id: 201, floor: 16)
        let page = makePage(mainPost: nil, posts: [reply], currentPage: 2)

        let merged = ThreadPageMainPostPolicy.merging(
            page,
            previousMainPost: main,
            requestedPage: 2
        )

        XCTAssertEqual(merged.mainPost, main)
        XCTAssertEqual(merged.posts, [reply])
    }

    func testFirstPageRefreshKeepsAlreadyDisplayedMainPost() {
        let main = makePost(id: 100, floor: 1)
        let reply = makePost(id: 201, floor: 2)
        let page = makePage(mainPost: nil, posts: [reply], currentPage: 1)

        let merged = ThreadPageMainPostPolicy.merging(
            page,
            previousMainPost: main,
            requestedPage: 1
        )

        XCTAssertEqual(merged.mainPost, main)
    }

    func testRefreshPreservesSummaryFallbackMarkerWithItsMainPost() {
        let main = makePost(id: 100, floor: 1)
        let page = makePage(
            mainPost: nil,
            posts: [makePost(id: 201, floor: 2)],
            currentPage: 1
        )

        let merged = ThreadPageMainPostPolicy.merging(
            page,
            previousMainPost: main,
            previousMainPostIsSummaryFallback: true,
            requestedPage: 1
        )

        XCTAssertEqual(merged.mainPost, main)
        XCTAssertTrue(merged.mainPostIsSummaryFallback)
    }

    func testReplyOnlyFirstPageRequiresRecovery() {
        let reply = makePost(id: 201, floor: 2)
        let page = makePage(mainPost: nil, posts: [reply], currentPage: 1)

        XCTAssertTrue(
            ThreadPageMainPostPolicy.needsFirstPageRecovery(page, requestedPage: 1)
        )
    }

    func testFirstFloorInsidePostsResolvesWithoutRecovery() {
        let main = makePost(id: 100, floor: 1)
        let reply = makePost(id: 201, floor: 2)
        let page = makePage(mainPost: nil, posts: [main, reply], currentPage: 1)

        XCTAssertEqual(ThreadPageMainPostPolicy.mainPost(in: page), main)
        XCTAssertFalse(
            ThreadPageMainPostPolicy.needsFirstPageRecovery(page, requestedPage: 1)
        )
    }

    func testEmptyFirstPageStillRequiresMainPostRecovery() {
        let page = makePage(mainPost: nil, posts: [], currentPage: 1)

        XCTAssertTrue(
            ThreadPageMainPostPolicy.needsFirstPageRecovery(page, requestedPage: 1)
        )
    }

    func testHomeSummaryFallbackResolvesReplyOnlyFirstPage() throws {
        let reply = makePost(id: 201, floor: 2)
        let page = makePage(mainPost: nil, posts: [reply], currentPage: 1)
        let summary = ThreadSummary(
            id: 1,
            title: "主题",
            author: makeUser(),
            replyCount: 1,
            viewCount: 10,
            likeCount: 12,
            firstPostID: 100,
            blocks: [.text("首页已有的主楼摘要")]
        )

        let fallback = try XCTUnwrap(ThreadMainPostFallback(thread: summary))
        let resolved = ThreadPageMainPostPolicy.applyingFallback(
            fallback,
            to: page,
            threadID: 1
        )

        XCTAssertEqual(resolved.mainPost?.id, 100)
        XCTAssertEqual(resolved.mainPost?.contentPreview, "首页已有的主楼摘要")
        XCTAssertTrue(resolved.mainPostIsSummaryFallback)
        XCTAssertFalse(
            ThreadPageMainPostPolicy.needsFirstPageRecovery(resolved, requestedPage: 1)
        )
    }

    func testFallbackCannotLeakIntoAnotherThread() throws {
        let page = makePage(
            mainPost: nil,
            posts: [makePost(id: 201, floor: 2)],
            currentPage: 1
        )
        let summary = ThreadSummary(
            id: 99,
            title: "其他主题",
            author: makeUser(),
            replyCount: 1,
            viewCount: 10,
            blocks: [.text("不应串入")]
        )

        let fallback = try XCTUnwrap(ThreadMainPostFallback(thread: summary))
        let resolved = ThreadPageMainPostPolicy.applyingFallback(
            fallback,
            to: page,
            threadID: 1
        )

        XCTAssertNil(resolved.mainPost)
        XCTAssertFalse(resolved.mainPostIsSummaryFallback)
    }

    func testEmptyHomeSummaryDoesNotCreateFakeMainPost() {
        let summary = ThreadSummary(
            id: 1,
            title: "空摘要",
            author: makeUser(),
            replyCount: 1,
            viewCount: 10,
            blocks: []
        )

        XCTAssertNil(ThreadMainPostFallback(thread: summary))
    }

    private func makePage(
        mainPost: Post?,
        posts: [Post],
        currentPage: Int
    ) -> ThreadPage {
        ThreadPage(
            thread: ThreadSummary(
                id: 1,
                title: "主题",
                author: makeUser(),
                replyCount: posts.count,
                viewCount: 0,
                blocks: []
            ),
            forum: Forum(
                id: 1,
                name: "测试",
                displayName: "测试吧",
                avatarURL: nil,
                memberCount: 0,
                threadCount: 0
            ),
            mainPost: mainPost,
            posts: posts,
            currentPage: currentPage,
            totalPage: 2,
            hasMore: currentPage < 2
        )
    }

    private func makePost(id: UInt64, floor: Int) -> Post {
        Post(
            id: id,
            threadID: 1,
            floor: floor,
            author: makeUser(),
            ipAddress: nil,
            createdAt: nil,
            blocks: [.text("第\(floor)楼")],
            subpostCount: 0,
            likeCount: 0,
            previewSubposts: []
        )
    }

    private func makeUser() -> UserSummary {
        UserSummary(id: 1, name: "author", displayName: "作者", portrait: "")
    }
}
