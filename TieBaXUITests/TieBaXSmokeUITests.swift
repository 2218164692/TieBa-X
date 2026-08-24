import XCTest

final class TieBaXSmokeUITests: XCTestCase {
    func testLaunchShowsTieBaXRoot() {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_USE_FIXTURES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 10))
    }
}
