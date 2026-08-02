import XCTest

final class UserProfileManagementUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testOwnProfileEditorShowsFieldsAndPersistsFixtureSuccess() {
        let app = launchLoggedInFixture()
        openOwnProfile(in: app)

        XCTAssertFalse(app.buttons["user-profile-follow-button"].exists)
        let editButton = app.buttons["user-profile-edit-button"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(editButton.frame.height, 44)
        editButton.tap()

        let nickname = app.textFields["user-profile-edit-nickname"]
        let introduction = app.textViews["user-profile-edit-introduction"]
        let sex = app.segmentedControls["user-profile-edit-sex"]
        XCTAssertTrue(nickname.waitForExistence(timeout: 5))
        XCTAssertTrue(introduction.exists)
        XCTAssertTrue(sex.exists)
        XCTAssertTrue(app.buttons["user-profile-edit-save"].exists)

        nickname.tap()
        nickname.typeText("新")
        app.buttons["男"].tap()
        app.buttons["user-profile-edit-save"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["user-profile-edit-success"]
                .waitForExistence(timeout: 8)
        )
        app.buttons["user-profile-edit-done"].tap()
        XCTAssertTrue(app.staticTexts["模拟登录用户新"].waitForExistence(timeout: 5))
    }

    func testOwnThreadDeleteConfirmsOnceThenReturnsAndRemovesFixtureRow() {
        let app = launchLoggedInFixture()
        openOwnProfile(in: app)

        let thread = app.buttons["user-profile-thread-row-1001"]
        XCTAssertTrue(thread.waitForExistence(timeout: 8))
        thread.tap()

        XCTAssertTrue(
            app.textViews["thread-main-text"].waitForExistence(timeout: 8),
            "必须等本人主题详情和作者身份校验完成后再打开更多菜单"
        )

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()

        let delete = app.buttons["thread-delete-own-thread"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["删除帖子"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["user-profile-screen"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(thread.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["user-profile-thread-row-1002"].exists)
    }

    private func launchLoggedInFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_USE_FIXTURES",
            "UITEST_DISABLE_ANIMATIONS",
            "UITEST_RESET_APPEARANCE",
            "UITEST_RESET_READING_PREFERENCES",
            "UITEST_RESET_BLOCKLIST"
        ]
        app.launchEnvironment["TIEBAPURE_FIXTURE_SCENARIO"] = "profileManagement"
        app.launchEnvironment["TIEBAPURE_FIXTURE_ACCOUNT"] = "loggedIn"
        app.launch()
        return app
    }

    private func openOwnProfile(in app: XCUIApplication) {
        let meTab = rootTab("我的", symbolIdentifier: "person.circle", in: app)
        XCTAssertTrue(meTab.waitForExistence(timeout: 20))
        meTab.tap()

        let profileButton = app.buttons["me-user-profile-button"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 8))
        profileButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["user-profile-screen"]
                .waitForExistence(timeout: 8)
        )
    }

    private func rootTab(
        _ label: String,
        symbolIdentifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let symbolButton = app.buttons.matching(identifier: symbolIdentifier).firstMatch
        if symbolButton.exists { return symbolButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
            .firstMatch
    }
}
