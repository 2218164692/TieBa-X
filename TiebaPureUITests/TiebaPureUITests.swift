import XCTest
import UIKit

final class TiebaPureUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchShowsHomeWithoutLoginAndRootTabs() {
        let app = launchApp()

        XCTAssertTrue(
            app.navigationBars["首页"].waitForExistence(timeout: 20)
                || rootTab("首页", in: app).exists
        )
        XCTAssertTrue(rootTab("首页", in: app).exists)
        XCTAssertTrue(rootTab("进吧", in: app).exists)
        XCTAssertTrue(rootTab("我的", in: app).exists)
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 45))
    }

    func testThreadAuthorOpensPublicUserProfile() {
        let app = launchApp()
        openFirstThread(in: app)

        let userButton = app.buttons["thread-main-user-button"]
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        XCTAssertTrue(userButton.isHittable)
        userButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["合成内容作者"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["user-profile-metadata"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["user-profile-follow-button"].exists)
        XCTAssertTrue(app.buttons["user-profile-posts-tab"].exists)
        XCTAssertTrue(app.buttons["user-profile-thread-row-1001"].waitForExistence(timeout: 8))
        attachScreenshot(named: "fixture-public-user-profile-posts")

        let forumsTab = app.buttons["user-profile-forums-tab"]
        XCTAssertTrue(scrollToHittable(forumsTab, in: app.scrollViews["user-profile-screen"]))
        forumsTab.tap()
        XCTAssertTrue(app.buttons["user-profile-forum-row-0"].waitForExistence(timeout: 5))
        attachScreenshot(named: "fixture-public-user-profile")
    }

    func testPrivateUserProfileShowsExplicitPrivacyStates() {
        let app = launchApp(scenario: "privateProfile")
        openFirstThread(in: app)

        let userButton = app.buttons["thread-main-user-button"]
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        userButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["user-profile-private-posts"].waitForExistence(timeout: 8))
        attachScreenshot(named: "fixture-private-user-profile-posts")
        let forumsTab = app.buttons["user-profile-forums-tab"]
        XCTAssertTrue(scrollToHittable(forumsTab, in: app.scrollViews["user-profile-screen"]))
        forumsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-private-forums"].waitForExistence(timeout: 5))
        attachScreenshot(named: "fixture-private-user-profile")
    }

    func testLoggedInAccountHeaderOpensOwnUserProfile() {
        let app = launchApp(account: "loggedIn")
        rootTab("我的", in: app).tap()

        let profileButton = app.buttons["me-user-profile-button"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 8))
        XCTAssertTrue(profileButton.isHittable)
        profileButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["模拟登录用户"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["user-profile-follow-button"].exists)
    }

    func testMessagesGuestPromptAndLoggedInFixtureJourney() {
        var app = launchApp()
        rootTab("我的", in: app).tap()

        XCTAssertTrue(app.staticTexts["未登录也可以浏览公开帖子"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["手机号验证码登录"].exists)
        XCTAssertFalse(app.buttons["me-messages-entry"].exists)

        app.terminate()
        app = launchApp(account: "loggedIn")
        rootTab("我的", in: app).tap()

        let messagesEntry = app.buttons["me-messages-entry"]
        XCTAssertTrue(messagesEntry.waitForExistence(timeout: 8))
        XCTAssertTrue(messagesEntry.isHittable)
        messagesEntry.tap()

        XCTAssertTrue(app.descendants(matching: .any)["messages-screen"].waitForExistence(timeout: 8))
        let replyRow = app.buttons["message-row-reply-1001-2002"]
        XCTAssertTrue(replyRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["这是回复我的第一条合成消息，内容完全离线生成。"].exists)

        let atSegment = app.segmentedControls.buttons["@我的"]
        XCTAssertTrue(atSegment.waitForExistence(timeout: 5))
        XCTAssertTrue(atSegment.isHittable)
        atSegment.tap()

        let atRow = app.buttons["message-row-at-1001-2002"]
        XCTAssertTrue(atRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["@模拟登录用户 这是一条合成的提及消息。"].exists)
        XCTAssertTrue(atRow.isHittable)
        atRow.tap()

        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLabelContaining("已定位搜索命中回复", in: app, maxSwipes: 10))
    }

    func testLoggedInUserCanToggleProfileFollowState() {
        let app = launchApp(account: "loggedIn")
        openFirstThread(in: app)

        let userButton = app.buttons["thread-main-user-button"]
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        userButton.tap()

        let followButton = app.buttons["user-profile-follow-button"]
        XCTAssertTrue(followButton.waitForExistence(timeout: 8))
        XCTAssertEqual(followButton.label, "关注用户")
        followButton.tap()

        let unfollowButton = app.buttons["user-profile-follow-button"]
        let followed = NSPredicate(format: "label == %@", "取消关注")
        expectation(for: followed, evaluatedWith: unfollowButton)
        waitForExpectations(timeout: 5)
        unfollowButton.tap()

        let unfollowed = NSPredicate(format: "label == %@", "关注用户")
        expectation(for: unfollowed, evaluatedWith: followButton)
        waitForExpectations(timeout: 5)
    }

    func testLoggedInUserCanOpenFollowedUsersFromMe() {
        let app = launchApp(account: "loggedIn")
        rootTab("我的", in: app).tap()

        let entry = app.buttons["followed-users-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertTrue(entry.isHittable)
        entry.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["followed-users-screen"]
                .waitForExistence(timeout: 8)
        )
        let followedUser = app.buttons["followed-user-row-1"]
        XCTAssertTrue(followedUser.waitForExistence(timeout: 8))
        XCTAssertTrue(followedUser.isHittable)
        XCTAssertTrue(app.staticTexts["另一个合成关注用户"].exists)

        followedUser.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["user-profile-screen"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["合成内容作者"].waitForExistence(timeout: 8))

        middleSwipeRight(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["followed-users-screen"]
                .waitForExistence(timeout: 5),
            "关注用户主页右划只能返回关注用户列表"
        )
        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
    }

    func testMeFollowRowsMatchBrowsingRowHeight() {
        let app = launchApp(account: "loggedIn")
        rootTab("我的", in: app).tap()

        let followedUsers = app.buttons["followed-users-entry"]
        let followedForums = app.buttons["我的关注吧"]
        let favorites = app.buttons["thread-favorites-entry"]
        let history = app.buttons["browsing-history-entry"]
        XCTAssertTrue(followedUsers.waitForExistence(timeout: 8))
        XCTAssertTrue(followedForums.exists)
        XCTAssertTrue(favorites.exists)
        XCTAssertTrue(history.exists)

        let baselineHeight = favorites.frame.height
        XCTAssertGreaterThanOrEqual(baselineHeight, 44)
        XCTAssertEqual(history.frame.height, baselineHeight, accuracy: 1)
        XCTAssertEqual(followedUsers.frame.height, baselineHeight, accuracy: 1)
        XCTAssertEqual(followedForums.frame.height, baselineHeight, accuracy: 1)
    }

    func testLoggedInUserCanLikeThreadReplyAndSubpost() {
        let app = launchApp(scenario: "subpostReference", account: "loggedIn")
        openFirstThread(in: app)

        let mainLikeButton = app.buttons["thread-main-like-button"]
        XCTAssertTrue(mainLikeButton.waitForExistence(timeout: 8))
        XCTAssertEqual(mainLikeButton.label, "点赞")
        XCTAssertTrue(mainLikeButton.value as? String == "当前12个赞")
        mainLikeButton.tap()
        XCTAssertTrue(waitForLikeState(mainLikeButton, label: "取消点赞", count: 13))

        XCTAssertTrue(waitForElement(named: "thread-like-button-2002", in: app, maxSwipes: 12))
        let replyLikeButton = app.buttons["thread-like-button-2002"]
        XCTAssertEqual(replyLikeButton.label, "点赞")
        replyLikeButton.tap()
        XCTAssertTrue(waitForLikeState(replyLikeButton, label: "取消点赞", count: 4))

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 8))
        app.buttons["查看全部4条回复"].tap()
        XCTAssertTrue(app.navigationBars["2楼的回复(4条)"].waitForExistence(timeout: 8))

        let parentLikeButton = app.buttons["thread-subpost-parent-like-button"]
        XCTAssertTrue(parentLikeButton.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLikeState(parentLikeButton, label: "取消点赞", count: 4))

        XCTAssertTrue(waitForElement(named: "thread-subpost-like-button-3051", in: app, maxSwipes: 8))
        let subpostLikeButton = app.buttons["thread-subpost-like-button-3051"]
        XCTAssertEqual(subpostLikeButton.label, "点赞")
        subpostLikeButton.tap()
        XCTAssertTrue(waitForLikeState(subpostLikeButton, label: "取消点赞", count: 1))
    }

    func testLargeLikeCountsStayOnOneLineAtTheTrailingEdge() {
        let app = launchApp(scenario: "largeLikeCount", account: "loggedIn")
        openFirstThread(in: app)

        let mainLike = app.buttons["thread-main-like-button"]
        XCTAssertTrue(mainLike.waitForExistence(timeout: 8))
        assertTrailingLikeControl(
            mainLike,
            fullCount: 9_876,
            authorID: 1,
            isMainPost: true,
            in: app
        )

        XCTAssertTrue(waitForElement(named: "thread-like-button-2002", in: app, maxSwipes: 12))
        let replyLike = app.buttons["thread-like-button-2002"]
        assertTrailingLikeControl(
            replyLike,
            fullCount: 123_456,
            authorID: 2,
            isMainPost: false,
            in: app
        )

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 8))
        app.buttons["查看全部4条回复"].tap()
        XCTAssertTrue(app.navigationBars["2楼的回复(4条)"].waitForExistence(timeout: 8))

        let subpostLike = app.buttons["thread-subpost-like-button-3061"]
        XCTAssertTrue(subpostLike.waitForExistence(timeout: 8))
        assertTrailingLikeControl(
            subpostLike,
            fullCount: 98_765,
            authorID: 4,
            isMainPost: false,
            in: app
        )
        attachScreenshot(named: "fixture-trailing-single-line-large-like-counts")
    }

    func testPullingHomeFeedRefreshesContentAndPreservesExistingRows() {
        let app = launchApp(scenario: "refreshUpdate")

        let firstRow = threadRows(in: app).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 45))
        let originalThread = app.buttons["确定性主帖：回复筛选与媒体布局"]
        XCTAssertTrue(originalThread.waitForExistence(timeout: 5))
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["home-search-button"].isHittable)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(app.buttons["下拉刷新已更新"].waitForExistence(timeout: 5))
        XCTAssertTrue(originalThread.exists, "刷新后应保留之前加载的帖子")
        let refreshedRow = threadRows(in: app).firstMatch
        let navigationBar = app.navigationBars["首页"]
        XCTAssertLessThanOrEqual(refreshedRow.frame.minY - navigationBar.frame.maxY, 24)
    }

    func testShortPullRefreshesThreadDetailAtSameDistanceAsHome() {
        let app = launchApp(scenario: "refreshUpdate")
        openFirstThread(in: app)

        let mainText = app.textViews["thread-main-text"]
        XCTAssertTrue(mainText.waitForExistence(timeout: 8))
        XCTAssertFalse((mainText.value as? String)?.contains("帖子下拉刷新已更新") == true)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        start.press(forDuration: 0.1, thenDragTo: end)

        let refreshed = NSPredicate(format: "value CONTAINS %@", "帖子下拉刷新已更新")
        expectation(for: refreshed, evaluatedWith: mainText)
        waitForExpectations(timeout: 8)
    }

    func testHomeAndThreadRefreshKeepTopIndicatorsVisible() {
        let app = launchApp(
            scenario: "refreshUpdate",
            additionalArguments: ["UITEST_EXTENDED_REFRESH_ANIMATION"]
        )
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 45))

        let homeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
        let homeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        homeStart.press(forDuration: 0.1, thenDragTo: homeEnd)
        XCTAssertTrue(
            app.descendants(matching: .any)["home-refresh-animation"].waitForExistence(timeout: 2)
        )
        attachScreenshot(named: "fixture-home-refresh-indicator")

        openFirstThread(in: app)
        let threadStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
        let threadEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        threadStart.press(forDuration: 0.1, thenDragTo: threadEnd)
        XCTAssertTrue(
            app.descendants(matching: .any)["thread-refresh-animation"].waitForExistence(timeout: 2)
        )
        attachScreenshot(named: "fixture-thread-refresh-indicator")
    }

    func testPullingDownAwayFromHomeTopDoesNotRefresh() {
        let app = launchApp(
            scenario: "refreshUpdate",
            additionalArguments: ["UITEST_EXTENDED_REFRESH_ANIMATION"]
        )

        let homeScrollView = app.scrollViews["home-feed-scroll-view"]
        let firstThread = app.buttons["确定性主帖：回复筛选与媒体布局"]
        XCTAssertTrue(homeScrollView.waitForExistence(timeout: 10))
        XCTAssertTrue(firstThread.waitForExistence(timeout: 45))
        for _ in 0..<6 where firstThread.isHittable {
            homeScrollView.swipeUp()
        }
        XCTAssertFalse(firstThread.isHittable, "测试必须先让首页明确离开顶部")

        let refreshAnimation = app.descendants(matching: .any)["home-refresh-animation"]
        XCTAssertFalse(refreshAnimation.exists)

        let start = homeScrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        let end = homeScrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertFalse(
            refreshAnimation.waitForExistence(timeout: 1.5),
            "首页不在顶部时向下滑动不得触发刷新"
        )
    }

    func testPullingEmptyForumStateLoadsContent() {
        let app = launchApp(scenario: "emptyThenSuccess")

        rootTab("进吧", in: app).tap()
        let forumField = app.textFields["输入吧名"]
        XCTAssertTrue(forumField.waitForExistence(timeout: 10))
        forumField.tap()
        forumField.typeText("测试")
        let enterForum = app.buttons["进入贴吧"]
        XCTAssertTrue(enterForum.isHittable)
        enterForum.tap()

        XCTAssertTrue(app.navigationBars["测试吧"].waitForExistence(timeout: 10))
        let emptyTitle = app.staticTexts["暂无帖子"]
        XCTAssertTrue(emptyTitle.waitForExistence(timeout: 10))
        let stateScrollView = app.scrollViews["reader-state-scroll-view"]
        XCTAssertTrue(stateScrollView.exists)

        let start = stateScrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = stateScrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.2, thenDragTo: end)

        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 10))
    }

    func testHomeTabReselectAfterScrollingRefreshesContent() {
        let app = launchApp(scenario: "refreshUpdate")

        let firstRow = threadRows(in: app).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 45))
        let homeTab = rootTab("首页", in: app)
        XCTAssertTrue(homeTab.isHittable)
        let appFrame = app.frame
        let homeTabFrame = homeTab.frame
        let homeTabCoordinate = app.coordinate(withNormalizedOffset: CGVector(
            dx: homeTabFrame.midX / appFrame.width,
            dy: homeTabFrame.midY / appFrame.height
        ))

        app.swipeUp()
        app.swipeUp()
        homeTabCoordinate.tap()

        XCTAssertTrue(app.buttons["下拉刷新已更新"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["确定性主帖：回复筛选与媒体布局"].exists)
    }

    func testForumHubAndMeKeepLoginOutOfHome() {
        let app = launchApp()

        rootTab("进吧", in: app).tap()
        XCTAssertTrue(app.navigationBars["进吧"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["输入吧名"].exists)

        rootTab("我的", in: app).tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))
        let loginButton = app.buttons["手机号验证码登录"]
        let followedForumsButton = app.buttons["我的关注吧"]
        XCTAssertTrue(
            loginButton.waitForExistence(timeout: 5) || followedForumsButton.waitForExistence(timeout: 5)
        )
    }

    func testViewingThreadAddsBrowsingHistoryInMeAndReopensIt() {
        let app = launchApp()
        openFirstThread(in: app)
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))

        let threadBackButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(threadBackButton.isHittable)
        threadBackButton.tap()
        XCTAssertTrue(rootTab("我的", in: app).waitForExistence(timeout: 8))

        rootTab("我的", in: app).tap()
        let historyEntry = app.buttons["browsing-history-entry"]
        XCTAssertTrue(
            waitForElement(named: "browsing-history-entry", in: app, maxSwipes: 4),
            "小屏设备滚动后应能找到浏览历史入口"
        )
        historyEntry.tap()

        XCTAssertTrue(app.navigationBars["浏览历史"].waitForExistence(timeout: 8))
        let historyRow = app.buttons["browsing-history-row-1001"]
        XCTAssertTrue(historyRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["确定性主帖：回复筛选与媒体布局"].exists)

        historyRow.tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))

        middleSwipeRight(in: app)
        XCTAssertTrue(
            app.navigationBars["浏览历史"].waitForExistence(timeout: 5),
            "历史帖子右划只能返回浏览历史"
        )
        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
    }

    func testBrowsingHistoryThreadRightSwipeKeepsEveryRouteAcrossRepeatedCycles() {
        let app = launchApp()
        openFirstThread(in: app)
        app.navigationBars.buttons.firstMatch.tap()
        rootTab("我的", in: app).tap()
        XCTAssertTrue(
            waitForElement(named: "browsing-history-entry", in: app, maxSwipes: 4),
            "小屏设备滚动后应能找到浏览历史入口"
        )
        app.buttons["browsing-history-entry"].tap()

        let historyBar = app.navigationBars["浏览历史"]
        let historyRow = app.buttons["browsing-history-row-1001"]
        XCTAssertTrue(historyBar.waitForExistence(timeout: 8))

        for cycle in 1...5 {
            XCTAssertTrue(historyRow.waitForExistence(timeout: 5), "第\(cycle)轮缺少历史帖子")
            historyRow.tap()
            XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8), "第\(cycle)轮未进入帖子")
            middleSwipeRight(in: app)
            XCTAssertTrue(
                historyBar.waitForExistence(timeout: 5),
                "第\(cycle)轮帖子右划必须且只能回到浏览历史"
            )
        }

        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
    }

    func testThreadFavoriteAppearsInMeAndReopensIt() {
        let app = launchApp()
        openFirstThread(in: app)

        let favoriteButton = app.buttons["thread-favorite-button"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 8))
        XCTAssertTrue(favoriteButton.isHittable)
        favoriteButton.tap()
        let favoriteUpdated = NSPredicate(format: "label == %@", "取消收藏帖子")
        expectation(for: favoriteUpdated, evaluatedWith: favoriteButton)
        waitForExpectations(timeout: 5)

        let threadBackButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(threadBackButton.isHittable)
        threadBackButton.tap()
        rootTab("我的", in: app).tap()

        let favoritesEntry = app.buttons["thread-favorites-entry"]
        XCTAssertTrue(favoritesEntry.waitForExistence(timeout: 8))
        favoritesEntry.tap()
        XCTAssertTrue(app.navigationBars["帖子收藏"].waitForExistence(timeout: 8))

        let favoriteRow = app.buttons["thread-favorite-row-1001"]
        XCTAssertTrue(favoriteRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["确定性主帖：回复筛选与媒体布局"].exists)
        favoriteRow.tap()
        XCTAssertTrue(app.buttons["thread-favorite-button"].waitForExistence(timeout: 8))

        middleSwipeRight(in: app)
        XCTAssertTrue(
            app.navigationBars["帖子收藏"].waitForExistence(timeout: 5),
            "收藏帖子右划只能返回帖子收藏"
        )
        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
    }

    func testSavedReadingPositionAutoRestoresAndReturnsToTop() {
        let app = launchApp(additionalArguments: ["UITEST_SEED_LOCAL_THREAD_LIBRARY"])
        rootTab("我的", in: app).tap()

        let favoritesEntry = app.buttons["thread-favorites-entry"]
        XCTAssertTrue(favoritesEntry.waitForExistence(timeout: 8))
        favoritesEntry.tap()
        XCTAssertTrue(app.buttons["thread-library-manage"].waitForExistence(timeout: 8))
        let favoriteRow = app.buttons["thread-favorite-row-1001"]
        XCTAssertTrue(favoriteRow.waitForExistence(timeout: 8))
        favoriteRow.tap()

        // The saved position restores automatically: the targeted reply is
        // scrolled into view without any manual step.
        let replyText = app.textViews["thread-reply-text"].firstMatch
        XCTAssertTrue(replyText.waitForExistence(timeout: 8))
        let replyBecameVisible = NSPredicate(format: "hittable == true")
        expectation(for: replyBecameVisible, evaluatedWith: replyText)
        waitForExpectations(timeout: 5)
        // The fixture marks post-ID-targeted loads with this distinct reply
        // body, proving the first request itself carried the saved post ID.
        XCTAssertTrue((replyText.value as? String)?.contains("已定位搜索命中回复") == true)

        let banner = app.otherElements["restored-reading-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        let returnToTop = app.buttons["restored-reading-return-top"]
        XCTAssertTrue(returnToTop.waitForExistence(timeout: 5))
        returnToTop.tap()

        let mainText = app.textViews["thread-main-text"].firstMatch
        XCTAssertTrue(mainText.waitForExistence(timeout: 8))
        let mainBecameVisible = NSPredicate(format: "hittable == true")
        expectation(for: mainBecameVisible, evaluatedWith: mainText)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(banner.exists)
    }

    func testVerifiedLoginSkipPasswordStaysInAppAndPublishesAccount() {
        let app = launchApp(additionalArguments: ["UITEST_LOGIN_REDIRECT_FIXTURE"])

        rootTab("我的", in: app).tap()
        let loginButton = app.buttons["手机号验证码登录"]
        XCTAssertTrue(loginButton.waitForExistence(timeout: 8))
        loginButton.tap()

        let skipPassword = app.links["跳过设置密码"]
        XCTAssertTrue(skipPassword.waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts["登录失败"].exists)
        skipPassword.tap()

        XCTAssertTrue(app.staticTexts["模拟登录用户"].waitForExistence(timeout: 8))
        let loginNavigationBar = app.navigationBars["手机号验证码登录"]
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: loginNavigationBar
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertFalse(app.alerts["登录失败"].exists)
        XCTAssertTrue(app.state == .runningForeground)
    }

    func testSearchResultRoutesToMatchedReply() {
        let app = launchApp()

        let searchField = openGlobalSearch(in: app)
        searchField.typeText("iPhone")
        searchField.typeText("\n")

        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.segmentedControls.buttons["全部"].waitForExistence(timeout: 10))
        let firstResult = threadRows(in: app).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10))
        app.descendants(matching: .any).matching(identifier: "thread-open-area").firstMatch.tap()
        XCTAssertTrue(waitForLabelContaining("已定位搜索命中回复", in: app, maxSwipes: 10))
    }

    func testSearchBackButtonDismissesFocusedSearchInOneStepAndHistoryPersists() {
        let app = launchApp()
        let searchField = openGlobalSearch(in: app)
        searchField.typeText("history-test")
        searchField.typeText("\n")
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))

        let backButton = app.navigationBars["搜索"].buttons.firstMatch
        XCTAssertTrue(backButton.isHittable)
        backButton.tap()

        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["搜索"].exists)

        let reopenedField = openGlobalSearch(in: app)
        XCTAssertTrue(reopenedField.exists)
        let historyItem = app.buttons["search-history-item-0"]
        XCTAssertTrue(historyItem.waitForExistence(timeout: 5))
        XCTAssertTrue(historyItem.label.contains("history-test"))
        XCTAssertTrue(app.buttons["search-history-clear-all"].exists)
    }

    func testSearchUsesSystemBackSwipeToPreviousPage() {
        let app = launchApp()
        _ = openGlobalSearch(in: app)
        let searchNavigationBar = app.navigationBars["搜索"]

        middleSwipeRight(in: app)

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: searchNavigationBar
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["首页"].exists)
        XCTAssertTrue(rootTab("首页", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(rootTab("进吧", in: app).exists)
        XCTAssertTrue(rootTab("我的", in: app).exists)
    }

    func testRootTabsRestoreAfterReturningFromFollowedUserProfileAndThread() {
        let app = launchApp(account: "loggedIn")
        openFirstThread(in: app)

        let userButton = app.buttons["thread-main-user-button"]
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        userButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))

        let followButton = app.buttons["user-profile-follow-button"]
        XCTAssertTrue(followButton.waitForExistence(timeout: 5))
        followButton.tap()
        let followed = NSPredicate(format: "label == %@", "取消关注")
        expectation(for: followed, evaluatedWith: followButton)
        waitForExpectations(timeout: 5)

        let profileNavigationBar = app.navigationBars["用户主页"]
        XCTAssertTrue(profileNavigationBar.waitForExistence(timeout: 5))
        let profileBackButton = profileNavigationBar.buttons.element(boundBy: 0)
        XCTAssertTrue(profileBackButton.isHittable)
        profileBackButton.tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 5))

        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 5))
        XCTAssertTrue(rootTab("首页", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(rootTab("进吧", in: app).exists)
        XCTAssertTrue(rootTab("我的", in: app).exists)
    }

    func testThreadDetailUsesSystemBackSwipeToPreviousPage() {
        let app = launchApp()
        openFirstThread(in: app)
        let detailMarker = app.buttons["更多"]
        XCTAssertTrue(detailMarker.exists)

        middleSwipeRight(in: app)

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: detailMarker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["首页"].exists)
        XCTAssertTrue(rootTab("首页", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(rootTab("进吧", in: app).exists)
        XCTAssertTrue(rootTab("我的", in: app).exists)
    }

    func testThreadShortRightDragCancelsWithoutChangingRoute() {
        let app = launchApp()
        openFirstThread(in: app)

        let detailMarker = app.buttons["更多"]
        XCTAssertTrue(detailMarker.waitForExistence(timeout: 8))
        let startX: CGFloat
        let endX: CGFloat
        if #available(iOS 26.0, *) {
            startX = 0.45
            endX = 0.55
        } else {
            startX = 0.01
            endX = 0.08
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.38))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.38))
        start.press(
            forDuration: 0.1,
            thenDragTo: end,
            withVelocity: 100,
            thenHoldForDuration: 0.1
        )

        XCTAssertTrue(
            detailMarker.waitForExistence(timeout: 3),
            "未达到完成阈值的右划必须回弹并留在帖子页"
        )
        XCTAssertFalse(app.navigationBars["首页"].exists)

        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 5))
    }

    func testUserProfileMiddleRightSwipeReturnsOnlyOneLevelToThread() {
        let app = launchApp()
        openFirstThread(in: app)

        let userButton = app.buttons["thread-main-user-button"]
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        userButton.tap()

        let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
        XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
        middleSwipeRight(in: app)

        let profileDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: profileScreen
        )
        XCTAssertEqual(XCTWaiter.wait(for: [profileDismissed], timeout: 5), .completed)
        attachScreenshot(named: "fixture-thread-after-profile-right-swipe")
        XCTAssertTrue(
            app.descendants(matching: .any)["thread-favorite-button"].waitForExistence(timeout: 5),
            "从用户主页右划后应回到帖子，而不是越过帖子直接回首页。当前层级：\n\(app.debugDescription)"
        )

        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 5))
    }

    func testRepeatedUserProfileRightSwipesNeverSkipTheThread() {
        let app = launchApp()
        openFirstThread(in: app)

        for iteration in 0..<6 {
            let userButton = app.buttons["thread-main-user-button"]
            XCTAssertTrue(userButton.waitForExistence(timeout: 8))
            userButton.tap()

            let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
            XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
            middleSwipeRight(in: app)

            let profileDismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: profileScreen
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [profileDismissed], timeout: 5),
                .completed,
                "第\(iteration + 1)次返回时用户主页没有关闭"
            )
            XCTAssertTrue(
                app.descendants(matching: .any)["thread-favorite-button"].waitForExistence(timeout: 5),
                "第\(iteration + 1)次返回越过帖子直接回到了首页"
            )
            XCTAssertFalse(app.navigationBars["首页"].exists)
        }
    }

    func testUserProfileThreadRightSwipeReturnsOnlyToUserProfile() {
        let app = launchApp()
        openFirstThread(in: app)

        let originalThreadMarker = app.descendants(matching: .any)["thread-favorite-button"]
        let userButton = app.buttons["thread-main-user-button"]
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        userButton.tap()

        let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
        XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
        let profileThread = app.buttons["user-profile-thread-row-1002"]
        XCTAssertTrue(profileThread.waitForExistence(timeout: 8))
        XCTAssertTrue(scrollToHittable(profileThread, in: app.scrollViews["user-profile-screen"]))
        profileThread.tap()
        let profileCoveredByThread = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: profileScreen
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [profileCoveredByThread], timeout: 8),
            .completed,
            "点击用户主页帖子后应进入帖子详情"
        )

        middleSwipeRight(in: app, y: 0.2)
        XCTAssertTrue(
            profileScreen.waitForExistence(timeout: 5),
            "用户主页中的帖子右划只能返回用户主页，不能越过用户主页"
        )

        middleSwipeRight(in: app)
        XCTAssertTrue(originalThreadMarker.waitForExistence(timeout: 5))
    }

    func testUserProfileSourceThreadReturnsToExistingThreadWithoutDuplicatePush() {
        let app = launchApp()
        openFirstThread(in: app)

        let userButton = app.buttons["thread-main-user-button"]
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        userButton.tap()

        let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
        XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
        let sourceThread = app.buttons["user-profile-thread-row-1001"]
        XCTAssertTrue(sourceThread.waitForExistence(timeout: 8))
        XCTAssertTrue(scrollToHittable(sourceThread, in: app.scrollViews["user-profile-screen"]))
        sourceThread.tap()

        let profileDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: profileScreen
        )
        XCTAssertEqual(XCTWaiter.wait(for: [profileDismissed], timeout: 8), .completed)
        middleSwipeRight(in: app, y: 0.2)
        XCTAssertTrue(
            app.navigationBars["首页"].waitForExistence(timeout: 5),
            "来源帖子不应被重复压入导航栈"
        )
    }

    func testSearchUserProfileRightSwipeReturnsOnlyToSearch() {
        let app = launchApp()
        let searchField = openGlobalSearch(in: app)
        searchField.typeText("iPhone")
        searchField.typeText("\n")

        let result = threadRows(in: app).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let userButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-user-button-"))
            .firstMatch
        XCTAssertTrue(userButton.waitForExistence(timeout: 8))
        XCTAssertTrue(scrollToHittable(userButton, in: app.scrollViews.firstMatch))
        userButton.tap()

        let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
        XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
        middleSwipeRight(in: app)
        XCTAssertTrue(
            app.navigationBars["搜索"].waitForExistence(timeout: 5),
            "搜索结果用户主页右划只能返回搜索结果"
        )
        XCTAssertTrue(result.exists)

        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 5))
    }

    func testForumUserProfileRightSwipeReturnsOnlyToForum() {
        let app = launchApp()
        rootTab("进吧", in: app).tap()

        let forumField = app.textFields["输入吧名"]
        XCTAssertTrue(forumField.waitForExistence(timeout: 10))
        forumField.tap()
        forumField.typeText("测试")
        app.buttons["进入贴吧"].tap()

        XCTAssertTrue(app.navigationBars["测试吧"].waitForExistence(timeout: 10))
        let userButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-user-button-"))
            .firstMatch
        XCTAssertTrue(userButton.waitForExistence(timeout: 10))
        userButton.tap()

        let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
        XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
        middleSwipeRight(in: app)
        XCTAssertTrue(
            app.navigationBars["测试吧"].waitForExistence(timeout: 5),
            "贴吧列表用户主页右划只能返回原贴吧"
        )

        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["进吧"].waitForExistence(timeout: 5))
    }

    func testForumThreadUserProfileRightSwipeNeverSkipsThread() {
        let app = launchApp()
        rootTab("进吧", in: app).tap()

        let forumField = app.textFields["输入吧名"]
        XCTAssertTrue(forumField.waitForExistence(timeout: 10))
        forumField.tap()
        forumField.typeText("测试")
        app.buttons["进入贴吧"].tap()

        XCTAssertTrue(app.navigationBars["测试吧"].waitForExistence(timeout: 10))
        openFirstThread(in: app)

        for iteration in 0..<8 {
            let userButton = app.buttons["thread-main-user-button"]
            XCTAssertTrue(userButton.waitForExistence(timeout: 8))
            userButton.tap()

            let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
            XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
            middleSwipeRight(in: app)

            let profileDismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: profileScreen
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [profileDismissed], timeout: 5),
                .completed,
                "第\(iteration + 1)次从用户主页返回时，用户主页没有关闭"
            )
            XCTAssertTrue(
                app.buttons["thread-favorite-button"].waitForExistence(timeout: 5),
                "第\(iteration + 1)次从用户主页返回越过了帖子详情，直接落到贴吧列表"
            )
        }

        middleSwipeRight(in: app)
        XCTAssertTrue(
            threadRows(in: app).firstMatch.waitForExistence(timeout: 5),
            "帖子详情右划后应只回到当前贴吧列表"
        )
        XCTAssertFalse(app.buttons["thread-favorite-button"].exists)
    }

    func testRightSwipeOnThreadImageDismissesWithoutOpeningPreview() {
        let app = launchApp(scenario: "imageGesture")
        openFirstThread(in: app)

        let inlineImage = visibleThreadInlineImage(in: app)
        XCTAssertNotNil(inlineImage)
        guard let inlineImage else { return }

        if #available(iOS 26.0, *) {
            inlineImage.swipeRight()
        } else {
            let imageFrame = inlineImage.frame
            let appFrame = app.frame
            let visibleY = min(max(imageFrame.midY, appFrame.minY + 140), appFrame.maxY - 120)
            let localY = min(max((visibleY - imageFrame.minY) / imageFrame.height, 0.1), 0.9)
            let start = inlineImage.coordinate(
                withNormalizedOffset: CGVector(dx: 0.4, dy: localY)
            )
            let end = app.coordinate(withNormalizedOffset: CGVector(
                dx: 0.9,
                dy: (visibleY - appFrame.minY) / appFrame.height
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        let preview = app.descendants(matching: .any)["full-screen-image-pager"]
        XCTAssertFalse(preview.waitForExistence(timeout: 1), "图片区域右划不得打开全屏预览")
        if #available(iOS 26.0, *) {
            XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 5))
        } else {
            XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 3))
            middleSwipeRight(in: app)
            XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 5))
        }
    }

    func testTappingThreadImageStillOpensPreview() {
        let app = launchApp(scenario: "imageGesture")
        openFirstThread(in: app)

        for iteration in 0..<3 {
            let inlineImage = visibleThreadInlineImage(in: app)
            XCTAssertNotNil(inlineImage)
            guard let inlineImage else { return }
            inlineImage.tap()

            XCTAssertTrue(
                app.descendants(matching: .any)["full-screen-image-pager"].waitForExistence(timeout: 5),
                "第\(iteration + 1)次真正点按图片仍应打开全屏预览"
            )
            app.buttons["关闭图片"].tap()

            let sourceIsHittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"),
                object: inlineImage
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [sourceIsHittable], timeout: 5),
                .completed,
                "第\(iteration + 1)次关闭后应缩回同一张帖子图片"
            )
            XCTAssertTrue(app.buttons["thread-favorite-button"].exists)
        }
    }

    func testHomeImageStaysAlignedAfterPreviewDismissAndScrollReuse() {
        let app = launchApp(scenario: "imageGesture")
        let media = app.buttons["media-item-image-1001-1"]
        XCTAssertTrue(media.waitForExistence(timeout: 8))
        if media.isHittable == false {
            let feed = app.scrollViews.firstMatch
            XCTAssertTrue(feed.exists)
            feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                .press(
                    forDuration: 0.05,
                    thenDragTo: feed.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)
                    )
                )
        }
        let mediaIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: media
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [mediaIsHittable], timeout: 5),
            .completed,
            "小屏或无障碍大字体下，短距离滚动后主页图片应完整可见"
        )

        let initialFrame = media.frame
        let initialImage = media.screenshot().image
        let initialAttachment = XCTAttachment(image: initialImage)
        initialAttachment.name = "home-image-before-preview"
        initialAttachment.lifetime = .deleteOnSuccess
        add(initialAttachment)
        print("HOME_IMAGE_REUSE initialFrame=\(initialFrame)")
        media.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["full-screen-image-pager"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["关闭图片"].tap()
        XCTAssertTrue(media.waitForExistence(timeout: 5))

        let feed = app.scrollViews["home-feed-scroll-view"]
        XCTAssertTrue(feed.exists)
        let upwardStart = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let upwardEnd = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        var upwardDragCount = 0
        while media.isHittable, upwardDragCount < 3 {
            upwardStart.press(
                forDuration: 0.05,
                thenDragTo: upwardEnd,
                withVelocity: 300,
                thenHoldForDuration: 0.1
            )
            upwardDragCount += 1
        }
        XCTAssertFalse(media.isHittable, "滚动后应先让图片离屏，以覆盖 LazyVStack 复用路径")

        let downwardStart = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let downwardEnd = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        for _ in 0..<upwardDragCount {
            downwardStart.press(
                forDuration: 0.05,
                thenDragTo: downwardEnd,
                withVelocity: 300,
                thenHoldForDuration: 0.1
            )
        }

        XCTAssertTrue(media.isHittable, "返回并滚动后应能再次看到同一张主页图片")
        let finalFrame = media.frame
        let finalImage = media.screenshot().image
        let finalAttachment = XCTAttachment(image: finalImage)
        finalAttachment.name = "home-image-after-scroll-reuse"
        finalAttachment.lifetime = .deleteOnSuccess
        add(finalAttachment)
        print("HOME_IMAGE_REUSE finalFrame=\(finalFrame)")
        XCTAssertGreaterThanOrEqual(
            finalFrame.minY,
            app.frame.minY,
            "像素比较前图片顶部必须完整回到可见区域"
        )
        XCTAssertLessThanOrEqual(
            finalFrame.maxY,
            app.tabBars.firstMatch.frame.minY,
            "像素比较前图片底部不得被标签栏遮挡"
        )
        XCTAssertEqual(media.frame.width, initialFrame.width, accuracy: 1)
        XCTAssertEqual(media.frame.height, initialFrame.height, accuracy: 1)
        assertScreenshotsVisuallyMatch(
            initialImage,
            finalImage,
            context: "主页图片预览返回并滚动复用后"
        )
        media.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["full-screen-image-pager"]
                .waitForExistence(timeout: 5),
            "滚动复用后的图片仍应从当前位置打开"
        )
    }

    func testHomeImageStaysAlignedAcrossRapidDismissAndScrollCycles() {
        let app = launchApp(scenario: "imageGesture")
        let media = app.buttons["media-item-image-1001-1"]
        XCTAssertTrue(media.waitForExistence(timeout: 8))
        XCTAssertTrue(media.isHittable)
        let baselineFrame = media.frame
        let baselineImage = media.screenshot().image
        let feed = app.scrollViews["home-feed-scroll-view"]
        XCTAssertTrue(feed.exists)

        let upwardStart = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let upwardEnd = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        let downwardStart = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        let downwardEnd = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))

        for cycle in 1...8 {
            media.tap()
            let pager = app.descendants(matching: .any)["full-screen-image-pager"]
            XCTAssertTrue(pager.waitForExistence(timeout: 3), "第\(cycle)轮没有打开图片")
            let surface = app.images["full-screen-image-zoom-surface-0"]
            XCTAssertTrue(surface.waitForExistence(timeout: 2))
            surface.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)
            ).tap()

            // Deliberately submit the scroll immediately after the dismissal
            // gesture instead of waiting for a source-is-hittable expectation.
            upwardStart.press(forDuration: 0.01, thenDragTo: upwardEnd)
            downwardStart.press(forDuration: 0.01, thenDragTo: downwardEnd)

            // The physical drags deliberately overlap dismissal, but their
            // inertial scrolling is not guaranteed to cancel at the same
            // instant. Wait for the source cell itself to stop moving before
            // beginning the next open cycle; otherwise a tap can merely stop
            // UIScrollView deceleration and never reach the image button.
            XCTAssertNotNil(
                waitForStableFrame(of: media),
                "第\(cycle)轮滚动未在下一次点击前稳定"
            )
            XCTAssertTrue(media.isHittable, "第\(cycle)轮返回滚动后图片不可点击")
            XCTAssertEqual(media.frame.minX, baselineFrame.minX, accuracy: 1)
            XCTAssertEqual(media.frame.width, baselineFrame.width, accuracy: 1)
            XCTAssertEqual(media.frame.height, baselineFrame.height, accuracy: 1)
            assertScreenshotsVisuallyMatch(
                baselineImage,
                media.screenshot().image,
                context: "第\(cycle)轮图片返回后立即滚动"
            )
        }
    }

    func testHomeImageCanScrollInTheFirstPostDismissalFrameWithoutMovingTheThumbnailLayer() {
        let app = launchApp(
            scenario: "imageGesture",
            additionalArguments: [
                "UITEST_IMAGE_DISMISS_SCROLL_RACE",
                "UITEST_IMAGE_DISMISS_SCROLL_RACE_VISUAL_HOLD",
                "UITEST_FORCE_IMAGE_TRANSITIONS"
            ]
        )
        let media = app.buttons["media-item-image-1001-1"]
        XCTAssertTrue(media.waitForExistence(timeout: 8))
        let feed = app.scrollViews["home-feed-scroll-view"]
        XCTAssertTrue(feed.exists)
        // `hittable` is insufficient on an SE-sized viewport: UIKit can tap a
        // partially clipped thumbnail, while production correctly refuses to
        // fly a hero into geometry that is not wholly represented on screen.
        // Centre the fixture first so this test exercises the real hero path on
        // every simulator rather than accidentally validating the fade fallback.
        for _ in 0..<4 {
            let visibleFeedFrame = feed.frame.insetBy(dx: 2, dy: 4)
            let mediaFrame = media.frame
            let isFullyVisible = media.isHittable
                && visibleFeedFrame.contains(mediaFrame)
            if isFullyVisible { break }

            let movesContentUp = mediaFrame.midY > visibleFeedFrame.midY
            let startY: CGFloat = movesContentUp ? 0.78 : 0.24
            let endY: CGFloat = movesContentUp ? 0.38 : 0.68
            feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                .press(
                    forDuration: 0.05,
                    thenDragTo: feed.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
                    )
                )
        }
        let sourceIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: media
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sourceIsHittable], timeout: 5), .completed)
        XCTAssertTrue(
            feed.frame.insetBy(dx: 2, dy: 4).contains(media.frame),
            "图片必须完整进入列表可视区后再验证 hero 转场"
        )
        let probe = app.descendants(matching: .any)["image-dismiss-scroll-race-probe"]
        for cycle in 1...6 {
            XCTAssertTrue(media.isHittable, "第\(cycle)轮图片没有恢复到可点击位置")
            media.tap()

            let pager = app.descendants(matching: .any)["full-screen-image-pager"]
            XCTAssertTrue(pager.waitForExistence(timeout: 5))
            let surface = app.images["full-screen-image-zoom-surface-0"]
            XCTAssertTrue(surface.waitForExistence(timeout: 3))
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()

            XCTAssertTrue(probe.waitForExistence(timeout: 5))
            let expectedResult = "cycle=\(cycle);completed=1"
            let completed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value BEGINSWITH %@", expectedResult),
                object: probe
            )
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)

            let result = probe.value as? String ?? ""
            print("IMAGE_DISMISS_SCROLL_RACE \(result)")
            let firstObservedScroll = diagnosticMetric(
                "firstScrollMs",
                from: result
            ) ?? -1
            XCTAssertGreaterThanOrEqual(firstObservedScroll, 0)
            let firstScrollAfterFinish = diagnosticMetric(
                "firstScrollAfterFinishMs",
                from: result
            ) ?? -1
            XCTAssertGreaterThanOrEqual(
                firstScrollAfterFinish,
                0,
                "转场代理销毁前不允许底层列表滚动"
            )
            XCTAssertLessThanOrEqual(
                firstScrollAfterFinish,
                34,
                "代理清理并恢复正式缩略图后，应在两个显示帧内允许列表滚动"
            )
            XCTAssertGreaterThanOrEqual(
                diagnosticMetric("scrollDeltaMilli", from: result) ?? 0,
                96_000
            )
            XCTAssertEqual(
                diagnosticMetric("sourceBitmap", from: result),
                1,
                "列表正式缩略图必须始终保留自己的 bitmap"
            )
            XCTAssertEqual(
                diagnosticMetric("maxHeroProxyCount", from: result),
                1,
                "自定义转场同时最多只能存在一个临时图片代理"
            )
            XCTAssertGreaterThanOrEqual(
                diagnosticMetric("heroProxySamples", from: result) ?? 0,
                3
            )
            XCTAssertEqual(
                diagnosticMetric("sourceVisibleWhileProxy", from: result),
                0,
                "正式缩略图与临时代理不得同时显示"
            )
            XCTAssertEqual(
                diagnosticMetric("scrollBeforeProxyCleanup", from: result),
                0,
                "临时代理存在时底层列表不得改变 contentOffset"
            )
            XCTAssertEqual(
                diagnosticMetric("proxyCountAtFirstScroll", from: result),
                0,
                "第一帧真实滚动前临时代理必须已完全销毁"
            )
            XCTAssertEqual(
                diagnosticMetric("sourceVisibleAtFirstScroll", from: result),
                1,
                "第一帧真实滚动必须由已恢复的正式缩略图负责显示"
            )
            XCTAssertEqual(diagnosticMetric("visibleImageStable", from: result), 1)
            XCTAssertEqual(
                diagnosticMetric("sourceRestored", from: result),
                1,
                "图片转场结束后必须完整恢复真实缩略图的位图、层级、透明度和变换"
            )
        }
    }

    func testHomeOpensAnotherImageOnFirstTapAfterDismissal() {
        let app = launchApp(scenario: "imageGesture")
        let firstImage = app.buttons["media-item-image-1001-1"]
        let secondImage = app.buttons["media-item-image-1001-2"]
        XCTAssertTrue(firstImage.waitForExistence(timeout: 8))
        XCTAssertTrue(secondImage.waitForExistence(timeout: 8))
        XCTAssertTrue(firstImage.isHittable)
        XCTAssertTrue(secondImage.isHittable)

        // Cache physical coordinates before a modal covers the feed. Calling
        // `element.tap()` during an over-full-screen dismissal makes XCUITest
        // resolve {-1, -1} and inject no touch; users tap window coordinates.
        let appFrame = app.frame
        let firstImageFrame = firstImage.frame
        let secondImageFrame = secondImage.frame
        XCTAssertTrue(appFrame.intersects(firstImageFrame))
        XCTAssertTrue(appFrame.intersects(secondImageFrame))
        // SwiftUI can expose every child Button with the media container's
        // union frame. The fixture shows three equal-width thumbnails; derive
        // the first tile centre only in that overlap case.
        let usesSharedAccessibilityFrame =
            abs(firstImageFrame.minX - secondImageFrame.minX) < 1
            && abs(firstImageFrame.width - secondImageFrame.width) < 1
        let firstImageMidX = usesSharedAccessibilityFrame
            ? firstImageFrame.minX + firstImageFrame.width / 6
            : firstImageFrame.midX
        let firstImageCoordinate = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (firstImageMidX - appFrame.minX) / appFrame.width,
                dy: (firstImageFrame.midY - appFrame.minY) / appFrame.height
            )
        )
        let secondImageCoordinate = app.coordinate(
                withNormalizedOffset: CGVector(
                    dx: (secondImageFrame.midX - appFrame.minX) / appFrame.width,
                    dy: (secondImageFrame.midY - appFrame.minY) / appFrame.height
                )
        )

        for cycle in 1...6 {
            firstImageCoordinate.tap()
            let pager = app.descendants(matching: .any)["full-screen-image-pager"]
            XCTAssertTrue(pager.waitForExistence(timeout: 3), "第\(cycle)轮第一张图未打开")
            XCTAssertTrue(
                app.staticTexts["image-page-indicator"].waitForExistence(timeout: 2)
                    && app.staticTexts["image-page-indicator"].label == "第1张，共4张",
                "第\(cycle)轮应打开第一张图"
            )
            let closeButton = app.buttons["关闭图片"]
            XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
            closeButton.tap()
            XCTAssertTrue(
                pager.waitForNonExistence(timeout: 2),
                "第\(cycle)轮第一张图的 dismissal 未完成"
            )

            // UIKit intentionally suppresses new input while a modal
            // transition is active. Start at the semantic dismissal boundary,
            // then inject exactly one physical tap with no cooldown or retry.
            secondImageCoordinate.tap()
            XCTAssertTrue(
                pager.waitForExistence(timeout: 2),
                "第\(cycle)轮返回后首次点击第二张图被丢弃"
            )
            XCTAssertTrue(
                app.staticTexts["image-page-indicator"].waitForExistence(timeout: 2)
                    && app.staticTexts["image-page-indicator"].label == "第2张，共4张",
                "第\(cycle)轮应直接打开第二张图，而不是残留第一张会话"
            )
            let secondCloseButton = app.buttons["关闭图片"]
            XCTAssertTrue(secondCloseButton.waitForExistence(timeout: 2))
            secondCloseButton.tap()
            XCTAssertTrue(
                pager.waitForNonExistence(timeout: 2),
                "第\(cycle)轮第二张图的 dismissal 未完成"
            )
        }
    }

    func testThreadDetailShowsReplyControls() {
        let app = launchApp()

        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "全部回复", in: app, maxSwipes: 30))
        XCTAssertTrue(app.descendants(matching: .any)["只看楼主"].exists)
        XCTAssertTrue(app.buttons["按热门排列回复"].exists)
        XCTAssertTrue(app.buttons["按正序排列回复"].exists)
        XCTAssertTrue(app.buttons["按倒序排列回复"].exists)

        XCTAssertTrue(app.buttons["更多"].exists)
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["复制链接"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["刷新"].exists)
        app.buttons["复制链接"].tap()
        XCTAssertTrue(app.alerts["已复制链接"].waitForExistence(timeout: 5))
        app.alerts["已复制链接"].buttons["好"].tap()

        XCTAssertTrue(app.buttons["搜索本吧"].exists)
        app.buttons["搜索本吧"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 10))
    }

    func testThreadLevelBadgeStaysOnOneLine() {
        let app = launchApp()
        openFirstThread(in: app)

        let referenceHeight = visibleLevelBadge(authorID: 1, in: app).frame.height
        assertAuthorIdentityIsSingleRow(authorID: 1, isMainPost: true, includesThreadAuthorBadge: true, in: app)
        let badge = visibleLevelBadge(authorID: 2, in: app)
        XCTAssertEqual(badge.label, "贴吧等级13 血之磐涅")
        XCTAssertEqual(
            badge.frame.height,
            referenceHeight,
            accuracy: 1,
            "长等级徽章应与同字号短徽章保持相同的单行高度"
        )
        assertAuthorIdentityIsSingleRow(authorID: 2, isMainPost: false, in: app)
        attachScreenshot(named: "fixture-single-line-user-level-badge")
    }

    func testThreadLevelBadgeStaysOnOneLineAtAccessibilityXXXL() {
        let app = launchApp(additionalArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openFirstThread(in: app)

        let referenceHeight = visibleLevelBadge(authorID: 1, in: app).frame.height
        assertAuthorIdentityIsSingleRow(authorID: 1, isMainPost: true, includesThreadAuthorBadge: true, in: app)
        let badge = visibleLevelBadge(authorID: 2, in: app)
        XCTAssertEqual(badge.label, "贴吧等级13 血之磐涅")
        XCTAssertEqual(
            badge.frame.height,
            referenceHeight,
            accuracy: 1,
            "无障碍大字体下长等级徽章仍应保持单行高度"
        )
        assertAuthorIdentityIsSingleRow(authorID: 2, isMainPost: false, in: app)
        attachScreenshot(named: "fixture-single-line-user-level-badge-axxxl")
    }

    func testAboutShowsTiebaLiteAttributionAndGPL() {
        let app = launchApp()

        rootTab("我的", in: app).tap()
        XCTAssertTrue(waitForElement(named: "关于 TiebaPure", in: app, maxSwipes: 4))
        app.buttons["关于 TiebaPure"].tap()
        XCTAssertTrue(waitForLabelContaining("infinityf4p", in: app, maxSwipes: 2))
        XCTAssertTrue(waitForLabelContaining("开源与来源", in: app, maxSwipes: 4))
        XCTAssertTrue(waitForLabelContaining("GPL-3.0-only", in: app, maxSwipes: 5))
        XCTAssertTrue(waitForLabelContaining("查看 TiebaLite 来源项目", in: app, maxSwipes: 5))
    }

    func testFixtureEmptyStateIsDeterministic() {
        let app = launchApp(scenario: "empty")
        XCTAssertTrue(app.staticTexts["暂无推荐"].waitForExistence(timeout: 8))
    }

    func testFixtureErrorStateOffersAccessibleRetry() {
        let app = launchApp(scenario: "error")
        XCTAssertTrue(waitForLabelContaining("网络不可用", in: app, maxSwipes: 1))
        XCTAssertTrue(app.buttons["重试"].exists)
    }

    func testPaginationFailureKeepsContentAndRetriesSamePage() {
        let app = launchApp(scenario: "paginationFailure")
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        let retry = app.buttons["重试"]
        if waitForElement(named: "重试", in: app, maxSwipes: 8) == false {
            XCTAssertTrue(waitForElement(named: "加载更多", in: app, maxSwipes: 8))
            app.buttons["加载更多"].tap()
            XCTAssertTrue(waitForElement(named: "重试", in: app, maxSwipes: 8))
        }
        retry.tap()
        XCTAssertFalse(retry.waitForExistence(timeout: 2))
        XCTAssertTrue(threadRows(in: app).firstMatch.exists)
    }

    func testTallInlineImageOffersOriginalEntry() {
        let app = launchApp(scenario: "longContent")
        openFirstThread(in: app)
        XCTAssertTrue(waitForLabelContaining("查看原图", in: app, maxSwipes: 20))
    }

    func testThreadDetailMainReplyAndSubpostsWrapWithoutTruncation() {
        let app = launchApp(scenario: "longContent")
        openFirstThread(in: app)

        let mainText = elementWithIdentifier(
            "thread-main-text",
            in: app,
            maxSwipes: 0
        )
        XCTAssertNotNil(mainText)
        XCTAssertGreaterThan(mainText?.frame.height ?? 0, 120)

        let replyText = elementWithIdentifier(
            "thread-reply-text",
            in: app,
            maxSwipes: 20
        )
        XCTAssertNotNil(replyText)
        XCTAssertGreaterThan(replyText?.frame.height ?? 0, 100)

        let previewText = elementWithIdentifier(
            "thread-subpost-preview-text",
            in: app,
            maxSwipes: 8
        )
        XCTAssertNotNil(previewText)
        XCTAssertGreaterThan(previewText?.frame.height ?? 0, 80)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 6))
        app.buttons["查看全部4条回复"].tap()
        XCTAssertTrue(app.navigationBars["2楼的回复(4条)"].waitForExistence(timeout: 8))

        let parentText = elementWithIdentifier(
            "thread-subpost-parent-text",
            in: app,
            maxSwipes: 0
        )
        XCTAssertNotNil(parentText)
        XCTAssertGreaterThan(parentText?.frame.height ?? 0, 100)

        let subpostText = elementWithIdentifier(
            "thread-subpost-text",
            in: app,
            maxSwipes: 8
        )
        XCTAssertNotNil(subpostText)
        XCTAssertGreaterThan(subpostText?.frame.height ?? 0, 80)
        XCTAssertTrue(app.descendants(matching: .any)["thread-subpost-metadata"].exists)
    }

    func testSubpostPreviewSeparatesRepliesWithoutExpandingOpenAllButton() {
        let app = launchApp(scenario: "subpostReference")
        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 20))
        let previewRows = app.descendants(matching: .any)
            .matching(identifier: "thread-subpost-preview-text")
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(previewRows.count, 3)

        for index in 1..<3 {
            let verticalGap = previewRows[index].frame.minY - previewRows[index - 1].frame.maxY
            XCTAssertEqual(verticalGap, 8, accuracy: 1)
        }

        XCTAssertEqual(app.buttons["查看全部4条回复"].frame.height, 36, accuracy: 1)
    }

    func testSubpostPreviewAuthorAndReplyTargetOpenIndependentProfiles() {
        let app = launchApp(scenario: "subpostReference")
        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 20))
        let authorLink = app.links["合成内容作者"].firstMatch
        XCTAssertTrue(authorLink.waitForExistence(timeout: 5))
        XCTAssertTrue(authorLink.isHittable)

        let replyTargetLink = app.links["被回复用户"]
        XCTAssertTrue(
            replyTargetLink.waitForExistence(timeout: 5),
            "被回复用户名应保留用户链接语义"
        )
        XCTAssertTrue(replyTargetLink.isHittable)
        attachScreenshot(named: "fixture-subpost-preview-two-native-links")

        authorLink.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["合成内容作者"].waitForExistence(timeout: 5))
        app.navigationBars["用户主页"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 5))

        let restoredReplyTargetLink = app.links["被回复用户"]
        XCTAssertTrue(restoredReplyTargetLink.waitForExistence(timeout: 5))
        restoredReplyTargetLink.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["被回复用户"].waitForExistence(timeout: 5))
    }

    func testSubpostPreviewLayoutRemainsStableAfterProfileRoundTrip() {
        let app = launchApp(scenario: "subpostReference")
        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 20))
        let initialRows = app.descendants(matching: .any)
            .matching(identifier: "thread-subpost-preview-text")
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(initialRows.count, 3)
        let initialFrames = initialRows.prefix(3).map(\.frame)
        attachScreenshot(named: "fixture-subpost-preview-before-profile")

        let authorLink = app.links["合成内容作者"].firstMatch
        XCTAssertTrue(authorLink.waitForExistence(timeout: 5))
        authorLink.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        middleSwipeRight(in: app)
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))

        let restoredRows = app.descendants(matching: .any)
            .matching(identifier: "thread-subpost-preview-text")
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(restoredRows.count, 3)
        let restoredFrames = restoredRows.prefix(3).map(\.frame)
        attachScreenshot(named: "fixture-subpost-preview-after-profile")

        for index in 0..<3 {
            XCTAssertEqual(restoredFrames[index].height, initialFrames[index].height, accuracy: 1)
            if index > 0 {
                let initialGap = initialFrames[index].minY - initialFrames[index - 1].maxY
                let restoredGap = restoredFrames[index].minY - restoredFrames[index - 1].maxY
                XCTAssertEqual(restoredGap, initialGap, accuracy: 1)
                XCTAssertEqual(restoredGap, 8, accuracy: 1)
            }
        }
    }

    func testSubpostPreviewLayoutRemainsStableAfterNativeBackRoundTrip() {
        let app = launchApp(scenario: "subpostReference")
        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 20))
        let initialRows = app.descendants(matching: .any)
            .matching(identifier: "thread-subpost-preview-text")
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(initialRows.count, 3)
        let initialFrames = initialRows.prefix(3).map(\.frame)

        let authorLink = app.links["合成内容作者"].firstMatch
        XCTAssertTrue(authorLink.waitForExistence(timeout: 5))
        authorLink.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        app.navigationBars["用户主页"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))

        let restoredRows = app.descendants(matching: .any)
            .matching(identifier: "thread-subpost-preview-text")
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(restoredRows.count, 3)
        let restoredFrames = restoredRows.prefix(3).map(\.frame)

        for index in 0..<3 {
            XCTAssertEqual(restoredFrames[index].height, initialFrames[index].height, accuracy: 1)
            if index > 0 {
                let initialGap = initialFrames[index].minY - initialFrames[index - 1].maxY
                let restoredGap = restoredFrames[index].minY - restoredFrames[index - 1].maxY
                XCTAssertEqual(restoredGap, initialGap, accuracy: 1)
                XCTAssertEqual(restoredGap, 8, accuracy: 1)
            }
        }
    }

    func testExpandedSubpostUsesSecondaryInteractiveUserNames() {
        let app = launchApp(scenario: "subpostReference")
        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 20))
        app.buttons["查看全部4条回复"].tap()
        XCTAssertTrue(app.navigationBars["2楼的回复(4条)"].waitForExistence(timeout: 8))

        let authorButton = app.buttons
            .matching(identifier: "thread-user-button-1")
            .firstMatch
        XCTAssertTrue(authorButton.waitForExistence(timeout: 5))
        XCTAssertEqual(authorButton.value as? String, "灰色用户名")

        let replyText = app.descendants(matching: .any)
            .matching(identifier: "thread-subpost-text")
            .firstMatch
        XCTAssertTrue(replyText.waitForExistence(timeout: 5))
        XCTAssertTrue(replyText.isHittable)
        XCTAssertTrue((replyText.value as? String)?.contains("被回复用户") == true)
        attachScreenshot(named: "fixture-expanded-subpost-secondary-usernames")

        authorButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["合成内容作者"].waitForExistence(timeout: 5))
        app.navigationBars["用户主页"].buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.navigationBars["2楼的回复(4条)"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.links["被回复用户"].waitForExistence(timeout: 5))
        let replyTargetLinks = app.links
            .matching(identifier: "被回复用户")
            .allElementsBoundByIndex
        let restoredReplyTargetLink = replyTargetLinks.first(where: \.isHittable)
        XCTAssertNotNil(
            restoredReplyTargetLink,
            "完整楼中楼中应有一个位于当前 sheet、可点击的被回复用户名链接"
        )
        guard let restoredReplyTargetLink else { return }
        restoredReplyTargetLink.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-profile-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["被回复用户"].waitForExistence(timeout: 5))
    }

    func testSubpostUserProfileRightSwipeReturnsOnlyToSubpostSheet() {
        let app = launchApp(scenario: "subpostReference")
        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 20))
        app.buttons["查看全部4条回复"].tap()
        let subpostNavigationBar = app.navigationBars["2楼的回复(4条)"]
        XCTAssertTrue(subpostNavigationBar.waitForExistence(timeout: 8))

        let authorButton = app.buttons
            .matching(identifier: "thread-user-button-1")
            .firstMatch
        XCTAssertTrue(authorButton.waitForExistence(timeout: 5))
        authorButton.tap()

        let profileScreen = app.descendants(matching: .any)["user-profile-screen"]
        XCTAssertTrue(profileScreen.waitForExistence(timeout: 8))
        middleSwipeRight(in: app)

        let profileDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: profileScreen
        )
        XCTAssertEqual(XCTWaiter.wait(for: [profileDismissed], timeout: 5), .completed)
        XCTAssertTrue(
            subpostNavigationBar.waitForExistence(timeout: 5),
            "楼中楼用户主页右划只能返回楼中楼，不能同时关闭楼中楼"
        )

        subpostDismissSwipeRight(in: app)
        XCTAssertFalse(subpostNavigationBar.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 5))
    }

    func testThreadDetailTextSupportsNativeCopySelection() {
        let app = launchApp(scenario: "longContent")
        openFirstThread(in: app)

        let mainText = app.textViews["thread-main-text"]
        XCTAssertTrue(mainText.waitForExistence(timeout: 8))
        XCTAssertTrue(mainText.isHittable)
        mainText.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.2))
            .press(forDuration: 1.2)

        let copyControl = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["复制", "拷贝", "Copy"]))
            .firstMatch
        XCTAssertTrue(copyControl.waitForExistence(timeout: 5))
        XCTAssertTrue(copyControl.isHittable)
        copyControl.tap()
        XCTAssertTrue(app.buttons["更多"].exists)
    }

    func testSubpostRightSwipeDismissesTheWholeSheet() {
        let app = launchApp(scenario: "subpostReference")
        openFirstThread(in: app)

        XCTAssertTrue(waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 20))
        let openAllButton = app.buttons["查看全部4条回复"]
        XCTAssertEqual(openAllButton.frame.height, 36, accuracy: 1)
        openAllButton.tap()
        let navigationBar = app.navigationBars["2楼的回复(4条)"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 8))
        let sheetSurface = app.descendants(matching: .any)["subpost-sheet-surface"]
        XCTAssertTrue(sheetSurface.waitForExistence(timeout: 5))
        XCTAssertEqual(
            sheetSurface.frame.maxY,
            app.frame.maxY,
            accuracy: 1,
            "楼中楼可移动表面必须覆盖底部安全区，不能露出灰色底层页面"
        )
        attachScreenshot(named: "fixture-subpost-reference-layout")

        let downwardStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let downwardEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        downwardStart.press(forDuration: 0.05, thenDragTo: downwardEnd)
        XCTAssertTrue(navigationBar.exists, "楼中楼下滑只能滚动内容，不应退出")

        let restingFrame = navigationBar.frame
        let partialSwipeStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)
        )
        let partialSwipeEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.49, dy: 0.45)
        )
        partialSwipeStart.press(
            forDuration: 0.05,
            thenDragTo: partialSwipeEnd,
            withVelocity: 80,
            thenHoldForDuration: 0.25
        )
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 3))
        XCTAssertEqual(navigationBar.frame.minY, restingFrame.minY, accuracy: 2)
        XCTAssertEqual(navigationBar.frame.minX, restingFrame.minX, accuracy: 2)

        for cycle in 0..<4 {
            if cycle > 0 {
                XCTAssertTrue(
                    waitForElement(named: "查看全部4条回复", in: app, maxSwipes: 5)
                )
                app.buttons["查看全部4条回复"].tap()
                XCTAssertTrue(navigationBar.waitForExistence(timeout: 8))
            }

            XCTAssertEqual(
                app.navigationBars.matching(identifier: "2楼的回复(4条)").count,
                1,
                "任一时刻只能存在一层楼中楼"
            )
            let swipeStart = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)
            )
            let swipeEnd = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45)
            )
            swipeStart.press(
                forDuration: 0.05,
                thenDragTo: swipeEnd,
                withVelocity: 300,
                thenHoldForDuration: 0.4
            )

            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: navigationBar
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [dismissed], timeout: 5),
                .completed,
                "第 \(cycle + 1) 轮楼中楼应只关闭一次"
            )
            XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 3))
        }

        attachScreenshot(named: "fixture-subpost-returned-to-thread")
    }

    func testFullScreenImageOffersDownloadAndTapReturnsToSource() {
        let app = launchApp(additionalArguments: [
            "UITEST_IMAGE_VIEWER",
            "UITEST_ZOOM_DIAGNOSTICS"
        ])

        let saveButton = app.buttons["save-current-image"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["关闭图片"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["full-screen-image-pager"].exists)

        let zoomSurface = app.images["full-screen-image-zoom-surface-0"]
        XCTAssertTrue(zoomSurface.waitForExistence(timeout: 5))
        XCTAssertEqual(zoomSurface.value as? String, "缩放 100%")
        let zoomDiagnostics = app.descendants(matching: .any)[
            "full-screen-image-zoom-diagnostics-0"
        ]
        XCTAssertTrue(zoomDiagnostics.waitForExistence(timeout: 3))

        if app.frame.width < 700 {
            zoomSurface.pinch(withScale: 1.5, velocity: 1)
        } else {
            // XCUITest does not reliably synthesize a two-finger pinch into a
            // page-hosted zoom surface on iPad. Exercise the same surface
            // through its supported double-tap path there; phones continue to
            // cover the real pinch recognizer above.
            zoomSurface.doubleTap()
        }
        let zoomed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "缩放 100%"),
            object: zoomSurface
        )
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["关闭图片"].exists, "捏合缩放不应关闭图片页")

        let enlargedPercentage = Int(
            (zoomSurface.value as? String ?? "").filter(\.isNumber)
        ) ?? 100
        XCTAssertGreaterThan(enlargedPercentage, 100)
        let zoomDiagnosticValue = zoomDiagnostics.value as? String ?? ""
        XCTAssertTrue(
            zoomDiagnosticValue.contains("layer=UIImageView"),
            "全屏缩放必须直接作用在 UIKit 图片层"
        )
        let firstCallback = diagnosticMetric(
            "first",
            from: zoomDiagnosticValue
        )
        XCTAssertNotNil(firstCallback)
        XCTAssertGreaterThanOrEqual(firstCallback ?? -1, 0)
        XCTAssertGreaterThan(
            diagnosticMetric("callbacks", from: zoomDiagnosticValue) ?? 0,
            0,
            "真实捏合必须持续驱动原生图片层：\(zoomDiagnosticValue)"
        )

        // XCUITest intentionally emits a synthetic pinch at roughly 6–8 Hz,
        // so its 130 ms gap measures event generation rather than app latency.
        // Drive the same production zoom path at display cadence and assert
        // that each image-layer update stays within a frame budget instead.
        let renderProbe = app.descendants(matching: .any)[
            "full-screen-image-render-probe-result-0"
        ]
        XCTAssertTrue(renderProbe.waitForExistence(timeout: 3))
        let renderProbeCompleted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "completed=true"),
            object: renderProbe
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [renderProbeCompleted], timeout: 5),
            .completed,
            "缩放渲染探针未完成：result=\(renderProbe.value ?? "nil")"
        )
        let renderProbeValue = renderProbe.value as? String ?? ""
        print("ZOOM_RENDER_PROBE \(renderProbeValue)")
        XCTAssertGreaterThanOrEqual(
            diagnosticMetric("frames", from: renderProbeValue) ?? 0,
            30,
            "缩放渲染探针应覆盖足够多帧：\(renderProbeValue)"
        )
        XCTAssertLessThanOrEqual(
            diagnosticMetric("p95FrameGap", from: renderProbeValue) ?? .max,
            34,
            "至少 95% 的缩放帧应在两帧预算内：\(renderProbeValue)"
        )
        XCTAssertLessThanOrEqual(
            diagnosticMetric("maxFrameGap", from: renderProbeValue) ?? .max,
            100,
            "即使模拟器受外部调度干扰，也不应出现 100ms 以上停顿：\(renderProbeValue)"
        )
        XCTAssertLessThanOrEqual(
            diagnosticMetric("maxWork", from: renderProbeValue) ?? .max,
            8,
            "每次缩放更新应在单帧预算内完成：\(renderProbeValue)"
        )

        // The real pinch (or the iPad fallback double tap) above has already
        // enlarged the image. A single double tap must therefore reset it.
        // Waiting for "!= 100%" here used to pass immediately on the existing
        // 130% state and never proved that the gesture had been delivered.
        zoomSurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)
        ).doubleTap()
        let reset = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "缩放 100%"),
            object: zoomSurface
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reset], timeout: 5),
            .completed,
            "双击缩小未完成：surface=\(zoomSurface.value ?? "nil"), diagnostics=\(zoomDiagnostics.value ?? "nil")"
        )
        XCTAssertGreaterThanOrEqual(
            diagnosticMetric(
                "doubleTaps",
                from: zoomDiagnostics.value as? String ?? ""
            ) ?? 0,
            1,
            "双击必须由原生缩放控制器处理：\(zoomDiagnostics.value ?? "nil")"
        )

        saveButton.tap()
        XCTAssertTrue(app.alerts["图片已保存"].waitForExistence(timeout: 5))
        app.alerts["图片已保存"].buttons["好"].tap()

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()

        XCTAssertTrue(app.staticTexts["图片来源页"].waitForExistence(timeout: 5))

        let sourceImage = app.descendants(matching: .any)["image-viewer-source-image"]
        XCTAssertTrue(sourceImage.waitForExistence(timeout: 3))
        let sourceIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: sourceImage
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sourceIsHittable], timeout: 3), .completed)
        sourceImage.tap()
        let reopened = app.descendants(matching: .any)["full-screen-image-pager"]
            .waitForExistence(timeout: 5)
        XCTAssertTrue(reopened, "缩回来源位置后应能再次从同一图片放大")
        app.buttons["关闭图片"].tap()
        let sourceIsHittableAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: sourceImage
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sourceIsHittableAgain], timeout: 5), .completed)
    }

    func testFullScreenImageRejectsSwipeDismissalButSingleTapReturns() {
        let app = launchApp(additionalArguments: ["UITEST_IMAGE_VIEWER"])
        let pager = app.descendants(matching: .any)["full-screen-image-pager"]
        let zoomSurface = app.images["full-screen-image-zoom-surface-0"]
        XCTAssertTrue(pager.waitForExistence(timeout: 8))
        XCTAssertTrue(zoomSurface.waitForExistence(timeout: 5))

        zoomSurface.swipeRight()
        XCTAssertTrue(pager.waitForExistence(timeout: 2), "图片详情页中间右划不得退出")

        let edgeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let edgeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        edgeStart.press(forDuration: 0.05, thenDragTo: edgeEnd)
        XCTAssertTrue(pager.waitForExistence(timeout: 2), "图片详情页边缘右划不得退出")

        let downStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let downEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        downStart.press(forDuration: 0.05, thenDragTo: downEnd)
        XCTAssertTrue(pager.waitForExistence(timeout: 2), "图片详情页下划不得退出")

        zoomSurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)
        ).tap()
        XCTAssertTrue(app.staticTexts["图片来源页"].waitForExistence(timeout: 5))
        XCTAssertFalse(pager.exists)
    }

    func testRemoteImageReplacesBitmapWhenReusableViewChangesURL() {
        let app = launchApp(additionalArguments: ["UITEST_REMOTE_IMAGE_REUSE"])
        let surface = app.descendants(matching: .any)["remote-image-reuse-surface"]
        let state = app.staticTexts["remote-image-reuse-state"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertTrue(state.waitForExistence(timeout: 5))

        let loadedA = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "已加载 A"),
            object: state
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loadedA], timeout: 5), .completed)
        let imageA = surface.screenshot().image.pngData()

        app.buttons["remote-image-reuse-switch"].tap()
        let loadedB = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "已加载 B"),
            object: state
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loadedB], timeout: 5), .completed)
        let imageB = surface.screenshot().image.pngData()

        XCTAssertNotEqual(
            imageA,
            imageB,
            "同一个列表图片视图换成新 URL 后必须替换位图，不能继续显示旧图片"
        )
    }

    func testFullScreenImageTransitionHandlesCroppedThumbnailAndOriginalRatio() {
        let arguments = [
            "UITEST_IMAGE_VIEWER",
            "UITEST_IMAGE_VIEWER_CROPPED_THUMBNAIL"
        ]
        let app = launchApp(additionalArguments: arguments)

        XCTAssertTrue(app.descendants(matching: .any)["full-screen-image-pager"]
            .waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["关闭图片"].waitForExistence(timeout: 3))
        app.buttons["关闭图片"].tap()

        let sourceImage = app.descendants(matching: .any)["image-viewer-source-image"]
        XCTAssertTrue(sourceImage.waitForExistence(timeout: 5))
        XCTAssertTrue(sourceImage.isHittable)
        sourceImage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["full-screen-image-pager"]
            .waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(sourceImage.waitForExistence(timeout: 5))
    }

    func testSyntheticScreenshotMatrix() {
        let app = launchApp()
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        attachScreenshot(named: "fixture-home")

        let searchField = openGlobalSearch(in: app)
        searchField.typeText("合成测试")
        searchField.typeText("\n")
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        attachScreenshot(named: "fixture-search-controls")

        app.descendants(matching: .any).matching(identifier: "thread-open-area").firstMatch.tap()
        XCTAssertTrue(waitForElement(named: "全部回复", in: app, maxSwipes: 10))
        app.swipeUp()
        attachScreenshot(named: "fixture-thread-controls")
    }

    func testLandscapeHomeAndSearchLayout() {
        let app = launchApp()
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }

        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(rootTab("首页", in: app).isHittable)
        attachScreenshot(named: "fixture-landscape-home")

        let searchField = openGlobalSearch(in: app)
        searchField.typeText("横屏")
        searchField.typeText("\n")
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["排序：最新"].exists || waitForLabelContaining("最新", in: app, maxSwipes: 1))
        attachScreenshot(named: "fixture-landscape-search")
    }

    func testFixtureMediaCountMatrixIsAccessible() {
        let app = launchApp()
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLabelContaining("共4项媒体", in: app, maxSwipes: 2))
        XCTAssertTrue(waitForLabelContaining("共1项媒体", in: app, maxSwipes: 6))
        XCTAssertTrue(waitForLabelContaining("共3项媒体", in: app, maxSwipes: 6))
        attachScreenshot(named: "fixture-media-count-matrix")
    }

    func testForegroundBackgroundKeepsFixtureContent() {
        let app = launchApp()
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(rootTab("首页", in: app).isHittable)
    }

    func testFollowedForumWholeRowNavigatesWithoutGestureConflict() {
        let app = launchApp(account: "loggedIn")
        rootTab("我的", in: app).tap()
        XCTAssertTrue(app.buttons["我的关注吧"].waitForExistence(timeout: 8))
        app.buttons["我的关注吧"].tap()
        XCTAssertTrue(app.navigationBars["我的关注吧"].waitForExistence(timeout: 8))

        let row = app.buttons.matching(identifier: "followed-forum-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()

        XCTAssertTrue(app.navigationBars["测试吧"].waitForExistence(timeout: 8))
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))

        middleSwipeRight(in: app)
        XCTAssertTrue(
            app.navigationBars["我的关注吧"].waitForExistence(timeout: 5),
            "关注吧进入贴吧后右划只能返回关注吧列表"
        )
        middleSwipeRight(in: app)
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
    }

    func testAppearanceSettingWorksForGuestAndPersistsAcrossRelaunch() {
        let expectedSystemAppearance = UITraitCollection.current.userInterfaceStyle == .dark
            ? "深色"
            : "浅色"
        var app = launchApp()
        rootTab("我的", in: app).tap()

        let settingsEntry = app.descendants(matching: .any)["app-settings-entry"]
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 8))
        XCTAssertTrue(settingsEntry.isHittable)
        settingsEntry.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitForAppearance(expectedSystemAppearance, in: app))

        let darkOption = appearanceOption("深色", in: app)
        XCTAssertTrue(darkOption.waitForExistence(timeout: 5))
        darkOption.tap()
        XCTAssertTrue(waitForAppearance("深色", in: app))
        attachScreenshot(named: "fixture-settings-dark")

        app.terminate()
        app = launchApp(resetAppearance: false)
        rootTab("我的", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["app-settings-entry"].waitForExistence(timeout: 8))
        app.descendants(matching: .any)["app-settings-entry"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitForAppearance("深色", in: app))

        let lightOption = appearanceOption("浅色", in: app)
        XCTAssertTrue(lightOption.waitForExistence(timeout: 5))
        lightOption.tap()
        XCTAssertTrue(waitForAppearance("浅色", in: app))

        let systemOption = appearanceOption("跟随系统", in: app)
        XCTAssertTrue(systemOption.waitForExistence(timeout: 5))
        systemOption.tap()
        XCTAssertTrue(waitForAppearance(expectedSystemAppearance, in: app))
    }

    func testFailedInlineImageRetryDoesNotOpenOrClosePreview() {
        let app = launchApp(scenario: "longContent")
        openFirstThread(in: app)

        let retry = buttonLabelContaining("图片加载失败", in: app, maxSwipes: 20)
        XCTAssertNotNil(retry)
        retry?.tap()

        XCTAssertFalse(app.buttons["关闭图片"].exists)
        XCTAssertTrue(app.buttons["更多"].exists)
    }

    func testEmptyFilteredSearchKeepsControlsAvailable() {
        let app = launchApp()
        let searchField = openGlobalSearch(in: app)
        searchField.typeText("仅回复命中")
        searchField.typeText("\n")
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))

        let topicFilter = app.segmentedControls.buttons["主题"]
        XCTAssertTrue(topicFilter.isHittable)
        topicFilter.tap()
        XCTAssertTrue(app.staticTexts["没有结果"].waitForExistence(timeout: 8))

        let allFilter = app.segmentedControls.buttons["全部"]
        XCTAssertTrue(allFilter.exists)
        XCTAssertTrue(allFilter.isHittable)
        allFilter.tap()
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
    }

    func testPostHTTPSLinkExposesNativeLinkTrait() {
        let app = launchApp()
        openFirstThread(in: app)

        let link = app.links["百度贴吧 HTTPS 链接"]
        if link.waitForExistence(timeout: 5) == false || link.isHittable == false {
            for _ in 0..<20 {
                if link.exists, link.isHittable { break }
                app.swipeUp()
            }
        }
        XCTAssertTrue(link.exists)
        XCTAssertTrue(link.isHittable)
    }

    func testReplyFirstLineGlyphsRemainVisibleAfterScrollReuse() {
        let app = launchApp(scenario: "textClipping")
        openFirstThread(in: app)

        attachScreenshot(named: "text-clipping-top")
        let expectedReplies = [
            "翻译这段回复",
            "A\u{0301} E\u{0302} Ü",
            "A\u{0301}\u{0307}",
            "ภาษาไทย မြန်မာ",
            "首行含贴吧表情",
            "首行包含可点击用户名",
            "多行回复用于触发"
        ]
        let replyQuery = app.textViews.matching(identifier: "thread-reply-text")
        let visibleFrame = app.windows.firstMatch.frame

        for (index, fragment) in expectedReplies.enumerated() {
            let reply = replyQuery.matching(
                NSPredicate(format: "value CONTAINS %@", fragment)
            ).firstMatch
            for _ in 0..<16 {
                if reply.exists, reply.frame.intersects(visibleFrame) { break }
                app.swipeUp()
            }
            XCTAssertTrue(reply.exists, "未找到回复夹具：\(fragment)")
            XCTAssertTrue(reply.frame.intersects(visibleFrame), "回复未滚动到可见区域：\(fragment)")
            XCTAssertGreaterThan(reply.frame.height, 0)
            attachScreenshot(named: "text-clipping-reply-\(index + 1)")
            assertRenderedTextContainsInk(
                reply,
                context: "回复夹具 \(fragment)"
            )
        }

        for _ in 0..<8 {
            app.swipeDown()
        }
        let reusedReply = replyQuery.matching(
            NSPredicate(format: "value CONTAINS %@", expectedReplies.last!)
        ).firstMatch
        for _ in 0..<20 {
            if reusedReply.exists, reusedReply.frame.intersects(visibleFrame) { break }
            app.swipeUp()
        }
        attachScreenshot(named: "text-clipping-after-reuse")
        XCTAssertTrue(reusedReply.exists)
        XCTAssertTrue(reusedReply.frame.intersects(visibleFrame))
        XCTAssertGreaterThan(reusedReply.frame.height, 0)
        assertRenderedTextContainsInk(
            reusedReply,
            context: "离屏复用后的末条回复"
        )
    }

    private func assertRenderedTextContainsInk(
        _ element: XCUIElement,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let image = element.screenshot().image
        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            XCTFail("\(context)：无法读取文字截图像素", file: file, line: line)
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard width > 2, height > 2, bytesPerPixel >= 3 else {
            XCTFail("\(context)：文字截图像素格式异常", file: file, line: line)
            return
        }

        func components(x: Int, y: Int) -> (Int, Int, Int) {
            let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
            return (
                Int(bytes[offset]),
                Int(bytes[offset + 1]),
                Int(bytes[offset + 2])
            )
        }

        let firstBackground = components(x: 0, y: 0)
        let secondBackground = components(x: width - 1, y: 0)
        let background = (
            (firstBackground.0 + secondBackground.0) / 2,
            (firstBackground.1 + secondBackground.1) / 2,
            (firstBackground.2 + secondBackground.2) / 2
        )

        var firstInkRow: Int?
        rowSearch: for y in 0..<height {
            for x in 0..<width {
                let pixel = components(x: x, y: y)
                let distance = abs(pixel.0 - background.0)
                    + abs(pixel.1 - background.1)
                    + abs(pixel.2 - background.2)
                if distance >= 90 {
                    firstInkRow = y
                    break rowSearch
                }
            }
        }

        guard let firstInkRow else {
            XCTFail("\(context)：截图中没有检测到文字像素", file: file, line: line)
            return
        }
        XCTAssertLessThan(
            firstInkRow,
            height,
            "\(context)：实际文字没有出现在元素截图内",
            file: file,
            line: line
        )
    }

    private func assertScreenshotsVisuallyMatch(
        _ expected: UIImage,
        _ actual: UIImage,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let expectedImage = expected.cgImage,
              let rawActualImage = actual.cgImage else {
            XCTFail("\(context)：无法读取截图", file: file, line: line)
            return
        }
        let widthDelta = abs(expectedImage.width - rawActualImage.width)
        let heightDelta = abs(expectedImage.height - rawActualImage.height)
        guard widthDelta <= 2, heightDelta <= 2 else {
            XCTFail(
                "\(context)：截图尺寸明显变化（"
                    + "\(expectedImage.width)×\(expectedImage.height) → "
                    + "\(rawActualImage.width)×\(rawActualImage.height)）",
                file: file,
                line: line
            )
            return
        }
        let actualImage: CGImage
        if widthDelta == 0, heightDelta == 0 {
            actualImage = rawActualImage
        } else {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let rendererContext = CGContext(
                data: nil,
                width: expectedImage.width,
                height: expectedImage.height,
                bitsPerComponent: 8,
                bytesPerRow: expectedImage.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                XCTFail("\(context)：无法统一截图像素尺寸", file: file, line: line)
                return
            }
            rendererContext.interpolationQuality = .high
            rendererContext.draw(
                rawActualImage,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: expectedImage.width,
                    height: expectedImage.height
                )
            )
            guard let normalizedImage = rendererContext.makeImage() else {
                XCTFail("\(context)：无法生成同尺寸截图", file: file, line: line)
                return
            }
            actualImage = normalizedImage
        }
        guard
              let expectedData = expectedImage.dataProvider?.data,
              let actualData = actualImage.dataProvider?.data,
              let expectedBytes = CFDataGetBytePtr(expectedData),
              let actualBytes = CFDataGetBytePtr(actualData) else {
            XCTFail("\(context)：无法读取同尺寸截图", file: file, line: line)
            return
        }

        let expectedBytesPerPixel = expectedImage.bitsPerPixel / 8
        let actualBytesPerPixel = actualImage.bitsPerPixel / 8
        guard expectedBytesPerPixel >= 3, actualBytesPerPixel >= 3 else {
            XCTFail("\(context)：截图像素格式异常", file: file, line: line)
            return
        }

        var differenceTotal = 0
        var changedPixelCount = 0
        var sampledPixelCount = 0
        for y in stride(from: 0, to: expectedImage.height, by: 2) {
            for x in stride(from: 0, to: expectedImage.width, by: 2) {
                let expectedOffset = y * expectedImage.bytesPerRow + x * expectedBytesPerPixel
                let actualOffset = y * actualImage.bytesPerRow + x * actualBytesPerPixel
                let difference = (0..<3).reduce(0) { result, component in
                    result + abs(
                        Int(expectedBytes[expectedOffset + component])
                            - Int(actualBytes[actualOffset + component])
                    )
                }
                differenceTotal += difference
                changedPixelCount += difference >= 60 ? 1 : 0
                sampledPixelCount += 1
            }
        }

        let meanDifference = Double(differenceTotal) / Double(max(sampledPixelCount * 3, 1))
        let changedFraction = Double(changedPixelCount) / Double(max(sampledPixelCount, 1))
        XCTAssertLessThan(meanDifference, 8, "\(context)：平均像素偏差过大", file: file, line: line)
        XCTAssertLessThan(changedFraction, 0.08, "\(context)：图片内容出现明显错位", file: file, line: line)
    }

    func testReduceMotionSuppressesCustomRefreshAnimation() throws {
        guard UIAccessibility.isReduceMotionEnabled else {
            throw XCTSkip("仅在已启用 Reduce Motion 的设备矩阵中运行。")
        }
        let app = launchApp()
        let firstRow = threadRows(in: app).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8))

        let start = firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let end = firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.35))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertFalse(app.descendants(matching: .any)["home-refresh-animation"].waitForExistence(timeout: 2))
    }

    func testForumListMediaIsDecorativeAndWholeRowOpensThread() {
        let app = launchApp()
        rootTab("进吧", in: app).tap()
        let forumField = app.textFields["输入吧名"]
        XCTAssertTrue(forumField.waitForExistence(timeout: 8))
        forumField.tap()
        forumField.typeText("测试\n")

        XCTAssertTrue(app.navigationBars["测试吧"].waitForExistence(timeout: 8))
        let row = threadRows(in: app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "帖子图片")).count, 0)

        row.tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))
    }

    func testSwitchingToHomeDoesNotTriggerReselectRefresh() {
        let app = launchApp()
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        rootTab("进吧", in: app).tap()
        XCTAssertTrue(app.navigationBars["进吧"].waitForExistence(timeout: 8))

        rootTab("首页", in: app).tap()
        XCTAssertTrue(threadRows(in: app).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["home-refresh-animation"].exists)
    }

    func testIPadTabBarBlankSpaceDoesNotSelectOrRefreshHome() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("仅在 iPad 设备矩阵中运行。")
        }
        let app = launchApp()
        rootTab("进吧", in: app).tap()
        XCTAssertTrue(app.navigationBars["进吧"].waitForExistence(timeout: 8))

        let tabElements = ["首页", "进吧", "我的"].map { rootTab($0, in: app) }
        XCTAssertTrue(tabElements.allSatisfy(\.exists))
        let leadingX = tabElements.map(\.frame.minX).min() ?? 0
        XCTAssertGreaterThan(leadingX, 24)
        let tabY = tabElements.map(\.frame.midY).reduce(0, +) / CGFloat(tabElements.count)
        let appFrame = app.frame
        app.coordinate(withNormalizedOffset: CGVector(
            dx: max(2, leadingX - 20) / appFrame.width,
            dy: tabY / appFrame.height
        )).tap()

        XCTAssertTrue(app.navigationBars["进吧"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home-refresh-animation"].exists)
    }

    func testIPadHomeThreadTitleAndSummaryBothOpenDetail() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("仅在 iPad 设备矩阵中运行。")
        }
        let app = launchApp()
        var openArea = app.descendants(matching: .any).matching(identifier: "thread-open-area").firstMatch
        XCTAssertTrue(openArea.waitForExistence(timeout: 8))

        openArea.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))

        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.isHittable)
        backButton.tap()

        openArea = app.descendants(matching: .any).matching(identifier: "thread-open-area").firstMatch
        XCTAssertTrue(openArea.waitForExistence(timeout: 8))
        openArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 8))
    }

    func testIPadForumThreadOpensSharedDetailInsteadOfLeadingLocalStack() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("仅在 iPad 设备矩阵中运行。")
        }
        let app = launchApp()
        rootTab("进吧", in: app).tap()

        let forumField = app.textFields["输入吧名"]
        XCTAssertTrue(forumField.waitForExistence(timeout: 8))
        forumField.tap()
        forumField.typeText("测试\n")
        XCTAssertTrue(app.navigationBars["测试吧"].waitForExistence(timeout: 8))

        let placeholder = app.descendants(matching: .any)["split-detail-placeholder"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        let openArea = app.descendants(matching: .any)
            .matching(identifier: "thread-open-area")
            .firstMatch
        XCTAssertTrue(openArea.waitForExistence(timeout: 8))
        openArea.tap()

        let moreButton = app.buttons["更多"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 8))
        XCTAssertFalse(
            placeholder.isHittable,
            "帖子必须覆盖共享 detail 的占位页"
        )
        XCTAssertGreaterThan(
            moreButton.frame.midX,
            app.frame.midX,
            "帖子工具栏必须位于 iPad 右侧共享 detail，而不是压入左侧局部栈"
        )
        XCTAssertTrue(
            openArea.isHittable,
            "打开共享 detail 后左栏帖子列表必须继续可操作"
        )
        XCTAssertTrue(
            app.navigationBars["测试吧"].exists,
            "打开共享 detail 后左栏贴吧列表必须继续保留"
        )
    }

    private func launchApp(
        scenario: String = "success",
        account: String? = nil,
        additionalArguments: [String] = [],
        resetAppearance: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var launchArguments = [
            "UITEST_USE_FIXTURES",
            "UITEST_DISABLE_ANIMATIONS",
            "UITEST_RESET_SEARCH_HISTORY",
            "UITEST_RESET_BROWSING_HISTORY",
            "UITEST_RESET_LOCAL_THREAD_LIBRARY",
            "UITEST_RESET_BLOCKLIST"
        ]
        if resetAppearance {
            launchArguments.append("UITEST_RESET_APPEARANCE")
        }
        app.launchArguments = launchArguments + additionalArguments
        app.launchEnvironment["TIEBAPURE_FIXTURE_SCENARIO"] = scenario
        if let account {
            app.launchEnvironment["TIEBAPURE_FIXTURE_ACCOUNT"] = account
        }
        app.launch()
        return app
    }

    private func diagnosticMetric(_ name: String, from value: String) -> Int? {
        value.split(separator: ";").compactMap { component -> Int? in
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(name) else { return nil }
            return Int(parts[1])
        }.first
    }

    private func waitForStableFrame(
        of element: XCUIElement,
        timeout: TimeInterval = 3,
        consecutiveSamples: Int = 5,
        tolerance: CGFloat = 0.5
    ) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        var stableSamples = 0

        while Date() < deadline {
            guard element.exists else {
                previousFrame = nil
                stableSamples = 0
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                continue
            }

            let frame = element.frame
            if let previousFrame,
               abs(frame.minX - previousFrame.minX) <= tolerance,
               abs(frame.minY - previousFrame.minY) <= tolerance,
               abs(frame.width - previousFrame.width) <= tolerance,
               abs(frame.height - previousFrame.height) <= tolerance {
                stableSamples += 1
            } else {
                stableSamples = 1
            }
            if stableSamples >= consecutiveSamples {
                return frame
            }
            previousFrame = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func waitForAppearance(_ appearance: String, in app: XCUIApplication) -> Bool {
        let effectiveMode = app.descendants(matching: .any)["appearance-effective-mode"]
        let predicate = NSPredicate(format: "label CONTAINS %@", appearance)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: effectiveMode)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitForLikeState(
        _ button: XCUIElement,
        label: String,
        count: Int
    ) -> Bool {
        let predicate = NSPredicate(
            format: "label == %@ AND value == %@",
            label,
            "当前\(count)个赞"
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func visibleLevelBadge(authorID: Int64, in app: XCUIApplication) -> XCUIElement {
        let badge = app.descendants(matching: .any)["thread-user-level-badge-\(authorID)"]
        if badge.waitForExistence(timeout: 5) == false || badge.isHittable == false {
            for _ in 0..<12 {
                if badge.exists, badge.isHittable { break }
                app.swipeUp()
            }
        }
        XCTAssertTrue(badge.exists)
        XCTAssertTrue(badge.isHittable)
        return badge
    }

    private func assertAuthorIdentityIsSingleRow(
        authorID: Int64,
        isMainPost: Bool,
        includesThreadAuthorBadge: Bool = false,
        in app: XCUIApplication
    ) {
        let nameIdentifier = isMainPost ? "thread-main-user-name" : "thread-user-name-\(authorID)"
        let name = app.descendants(matching: .any)[nameIdentifier]
        let badge = app.descendants(matching: .any)["thread-user-level-badge-\(authorID)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertEqual(
            name.frame.midY,
            badge.frame.midY,
            accuracy: 2,
            "用户名和贴吧等级徽章必须保持在同一行"
        )
        if includesThreadAuthorBadge {
            let threadAuthorBadge = app.descendants(matching: .any)["thread-author-badge-\(authorID)"]
            XCTAssertTrue(threadAuthorBadge.waitForExistence(timeout: 5))
            XCTAssertEqual(
                name.frame.midY,
                threadAuthorBadge.frame.midY,
                accuracy: 2,
                "用户名和楼主徽章必须保持在同一行"
            )
        }
    }

    private func assertTrailingLikeControl(
        _ control: XCUIElement,
        fullCount: Int,
        authorID: Int64,
        isMainPost: Bool,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(control.exists)
        let accessibilityValue = control.value as? String ?? ""
        let reportedDigits = accessibilityValue.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()
        XCTAssertEqual(reportedDigits, "\(fullCount)")
        XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        XCTAssertLessThan(
            control.frame.height,
            80,
            "即使在 Accessibility XXXL 下，点赞图标和数字也只能占一行"
        )
        XCTAssertGreaterThan(control.frame.midX, app.frame.midX)

        let badge = app.descendants(matching: .any)["thread-user-level-badge-\(authorID)"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            badge.frame.maxX,
            control.frame.minX + 1,
            "左侧用户信息不得覆盖右侧点赞区"
        )
        XCTAssertEqual(
            badge.frame.midY,
            control.frame.midY,
            accuracy: 3,
            "点赞区应在作者行右侧居中且保持单行"
        )

        let nameIdentifier = isMainPost ? "thread-main-user-name" : "thread-user-name-\(authorID)"
        let name = app.descendants(matching: .any)[nameIdentifier]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        if name.frame.maxX.isFinite {
            XCTAssertLessThanOrEqual(name.frame.maxX, control.frame.minX + 1)
        }
    }

    private func appearanceOption(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(identifier: "appearance-picker")
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    private func threadRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "thread-row")
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        maxSwipes: Int = 8
    ) -> Bool {
        guard element.waitForExistence(timeout: 2), scrollView.exists else { return false }
        for _ in 0..<maxSwipes where element.isHittable == false {
            scrollView.swipeUp()
        }
        return element.isHittable
    }

    private func openGlobalSearch(in app: XCUIApplication) -> XCUIElement {
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        let searchButton = app.buttons["home-search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 8))
        XCTAssertTrue(searchButton.isHittable)
        searchButton.tap()

        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 8))
        let searchField = app.textFields["search-input"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        XCTAssertTrue(searchField.isHittable)
        searchField.tap()
        return searchField
    }

    private func rootTab(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let symbolIdentifier: String?
        switch label {
        case "首页": symbolIdentifier = "house"
        case "进吧": symbolIdentifier = "square.grid.2x2"
        case "我的": symbolIdentifier = "person.circle"
        default: symbolIdentifier = nil
        }
        if let symbolIdentifier {
            let symbolButton = app.buttons.matching(identifier: symbolIdentifier).firstMatch
            if symbolButton.exists { return symbolButton }
        }
        let labeledButton = app.buttons.matching(
            NSPredicate(format: "label == %@ OR identifier == %@", label, label)
        ).firstMatch
        if labeledButton.exists { return labeledButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
            .firstMatch
    }

    private func openFirstThread(in app: XCUIApplication) {
        let firstOpenArea = app.descendants(matching: .any).matching(identifier: "thread-open-area").firstMatch
        XCTAssertTrue(firstOpenArea.waitForExistence(timeout: 45))
        firstOpenArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        if app.buttons["更多"].waitForExistence(timeout: 5) == false, firstOpenArea.exists {
            firstOpenArea.tap()
        }
        let didOpenDetail = app.buttons["更多"].waitForExistence(timeout: 8)
        XCTAssertTrue(didOpenDetail)
    }

    private func middleSwipeRight(in app: XCUIApplication, y: CGFloat = 0.38) {
        if #available(iOS 26.0, *) {
            // XCTest's coordinate press/drag injection does not enter UIKit's
            // iOS 26 content-pop recognizer, even in an otherwise empty native
            // UINavigationController. The system swipe event does.
            app.swipeRight()
            return
        }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func subpostDismissSwipeRight(in app: XCUIApplication, y: CGFloat = 0.38) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func visibleThreadInlineImage(in app: XCUIApplication) -> XCUIElement? {
        let inlineImage = app.descendants(matching: .any)["thread-inline-image"]
        guard inlineImage.waitForExistence(timeout: 8) else { return nil }
        for _ in 0..<8 where inlineImage.isHittable == false {
            app.swipeUp()
        }
        return inlineImage.isHittable ? inlineImage : nil
    }

    private func waitForElement(named name: String, in app: XCUIApplication, maxSwipes: Int) -> Bool {
        let element = app.buttons[name]
        if element.waitForExistence(timeout: 5), element.isHittable {
            return true
        }

        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable {
                return true
            }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func waitForStaticText(named name: String, in app: XCUIApplication, maxSwipes: Int) -> Bool {
        let element = app.staticTexts[name]
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<maxSwipes {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func waitForLabelContaining(_ text: String, in app: XCUIApplication, maxSwipes: Int) -> Bool {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<maxSwipes {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func buttonLabelContaining(
        _ text: String,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> XCUIElement? {
        let element = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        if element.waitForExistence(timeout: 8), element.isHittable { return element }
        for _ in 0..<maxSwipes {
            if element.exists, element.isHittable { return element }
            app.swipeUp()
        }
        return element.exists && element.isHittable ? element : nil
    }

    private func elementWithIdentifier(
        _ identifier: String,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> XCUIElement? {
        let element = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        if element.waitForExistence(timeout: 5) { return element }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return element }
        }
        return element.exists ? element : nil
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
