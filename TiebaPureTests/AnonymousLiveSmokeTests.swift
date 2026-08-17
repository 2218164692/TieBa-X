import Foundation
import XCTest
@testable import TiebaPure

/// Read-only production-network smoke coverage used only at the release gate.
///
/// CI deliberately skips this test because the deterministic fixture suite is the
/// source of truth there. Run it explicitly with `RUN_ANONYMOUS_LIVE_SMOKE=1`.
final class AnonymousLiveSmokeTests: XCTestCase {
    func testAnonymousDescendingRepliesStartFromLatestPage() async throws {
        guard ProcessInfo.processInfo.environment["RUN_ANONYMOUS_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("发布前按需运行；日常与 CI 测试不访问贴吧线上服务。")
        }

        let session = SecureRemoteURLSession.make(
            configuration: Self.sessionConfiguration(),
            redirectScope: .baiduHTTPS
        )
        defer { session.invalidateAndCancel() }
        let api = TiebaAPI(client: TiebaHTTPClient(session: session))
        let threads = try await api.forumThreads(
            account: nil,
            forumName: "iphone",
            page: 1,
            category: .replyTime
        )
        let thread = try XCTUnwrap(
            threads.first(where: { $0.replyCount >= 30 }),
            "公开吧页应提供一个至少 30 条回复的帖子用于倒序契约验证"
        )
        let ascending = try await api.threadPage(
            account: nil,
            threadID: thread.id,
            page: 1,
            forumID: thread.forumID,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
        let latestServerPage = ThreadDescendingPaginationPolicy.serverPage(
            logicalPage: 1,
            totalPage: ascending.totalPage
        )
        let latest = try await api.threadPage(
            account: nil,
            threadID: thread.id,
            page: latestServerPage,
            forumID: thread.forumID,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
        let descending = ThreadDescendingPaginationPolicy.normalized(
            latest,
            logicalPage: 1
        )
        let ascendingFloors = ascending.posts.map(\.floor).filter { $0 > 1 }
        let descendingFloors = descending.posts.map(\.floor).filter { $0 > 1 }

        XCTAssertFalse(ascendingFloors.isEmpty)
        XCTAssertFalse(descendingFloors.isEmpty)
        XCTAssertGreaterThan(
            descendingFloors.max() ?? 0,
            ascendingFloors.max() ?? 0,
            "倒序第一页必须从最新楼层开始，而不是只反转正序第一页"
        )
    }

    func testAnonymousHomeForumSearchThreadAndMediaJourney() async throws {
        guard ProcessInfo.processInfo.environment["RUN_ANONYMOUS_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("发布前按需运行；日常与 CI 测试不访问贴吧线上服务。")
        }

        let apiSession = SecureRemoteURLSession.make(
            configuration: Self.sessionConfiguration(),
            redirectScope: .baiduHTTPS
        )
        let mediaSession = SecureRemoteURLSession.make(
            configuration: Self.sessionConfiguration(),
            redirectScope: .publicHTTPS
        )
        defer {
            apiSession.invalidateAndCancel()
            mediaSession.invalidateAndCancel()
        }

        let api = TiebaAPI(client: TiebaHTTPClient(session: apiSession))

        let home = try await api.personalizedThreads(account: nil, page: 1, loadType: 1)
        XCTAssertFalse(home.isEmpty, "匿名首页应返回至少一个帖子")

        let forumThreads = try await api.forumThreads(
            account: nil,
            forumName: "iphone",
            page: 1,
            category: .replyTime
        )
        XCTAssertFalse(forumThreads.isEmpty, "匿名进吧应返回帖子")

        var mediaResult: SearchResult?
        for page in 1...3 where mediaResult == nil {
            let results = try await api.searchThreads(
                keyword: "iPhone 壁纸",
                page: page,
                sortType: 5,
                filterType: 2,
                forumName: nil,
                pageSize: 30
            )
            mediaResult = results.results.first(where: { result in
                result.blocks.contains(where: \ContentBlock.isMedia)
            })
            if results.hasMore == false { break }
        }

        let result = try XCTUnwrap(mediaResult, "匿名搜索前三页应至少包含一个媒体帖子")
        let detail = try await api.threadPage(
            account: nil,
            threadID: result.threadID,
            page: 1,
            forumID: result.forumID,
            postID: result.postID,
            seeLz: false,
            sortType: .ascending
        )
        XCTAssertEqual(detail.thread.id, result.threadID)

        let detailBlocks = detail.thread.blocks
            + (detail.mainPost?.blocks ?? [])
            + detail.posts.flatMap(\.blocks)
        let mediaBlocks = detailBlocks.filter(\ContentBlock.isMedia)
        let candidateBlocks = mediaBlocks.isEmpty ? result.blocks.filter(\ContentBlock.isMedia) : mediaBlocks
        XCTAssertFalse(candidateBlocks.isEmpty, "帖子详情或命中结果应保留媒体映射")

        if let imageURL = candidateBlocks.compactMap(\.safeImageURL).first {
            var request = URLRequest(url: imageURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await BoundedURLSession(session: mediaSession).data(
                for: request,
                maximumBytes: 30 * 1_024 * 1_024,
                requiredMIMEPrefix: "image/"
            )
            XCTAssertFalse(data.isEmpty)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } else {
            let videoURL = try XCTUnwrap(candidateBlocks.compactMap(\.safeVideoURL).first)
            XCTAssertEqual(videoURL.scheme, "https")
        }
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return configuration
    }
}

private extension ContentBlock {
    var isMedia: Bool {
        switch self {
        case .image, .video:
            return true
        default:
            return false
        }
    }

    var safeImageURL: URL? {
        guard case let .image(image) = self else { return nil }
        return [image.originalURL, image.thumbnailURL]
            .compactMap { $0 }
            .compactMap { TiebaURL.image($0.absoluteString) }
            .first
    }

    var safeVideoURL: URL? {
        guard case let .video(video) = self else { return nil }
        return [video.videoURL, video.webURL]
            .compactMap { $0 }
            .compactMap { TiebaURL.video($0.absoluteString) }
            .first
    }
}
