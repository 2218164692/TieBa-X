import XCTest
@testable import TiebaPure

final class CompatibleUIFoundationTests: XCTestCase {
    func testInitialAppearanceReportsCurrentValueAsOldAndNew() throws {
        var tracker = CompatibleValueChangeTracker(initialValue: 7)

        let change = try XCTUnwrap(tracker.appear(with: 9, sendsInitialChange: true))

        XCTAssertEqual(change.oldValue, 9)
        XCTAssertEqual(change.newValue, 9)
        XCTAssertTrue(tracker.hasAppeared)
        XCTAssertNil(tracker.appear(with: 9, sendsInitialChange: true))
    }

    func testAppearanceWithoutInitialNotificationSynchronizesPreviousValue() throws {
        var tracker = CompatibleValueChangeTracker(initialValue: "stale")

        XCTAssertNil(tracker.appear(with: "current", sendsInitialChange: false))
        let change = try XCTUnwrap(tracker.update(to: "next"))

        XCTAssertEqual(change.oldValue, "current")
        XCTAssertEqual(change.newValue, "next")
    }

    func testUpdateSuppressesEqualValuesAndRetainsOldNewOrdering() throws {
        var tracker = CompatibleValueChangeTracker(initialValue: 1)

        XCTAssertNil(tracker.update(to: 1))
        let change = try XCTUnwrap(tracker.update(to: 2))

        XCTAssertEqual(change.oldValue, 1)
        XCTAssertEqual(change.newValue, 2)
        XCTAssertEqual(tracker.previousValue, 2)
    }
}
