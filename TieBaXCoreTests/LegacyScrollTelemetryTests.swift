import XCTest
@testable import TieBaX

final class LegacyScrollTelemetryTests: XCTestCase {
    func testSnapshotDerivesDistancesAndVisibleContentRect() {
        let snapshot = LegacyScrollTelemetrySnapshot(
            phase: .idle,
            contentOffset: CGPoint(x: -8, y: -14),
            adjustedContentInset: UIEdgeInsets(top: 20, left: 8, bottom: 12, right: 6),
            viewportSize: CGSize(width: 390, height: 800),
            contentSize: CGSize(width: 390, height: 2_000)
        )

        XCTAssertEqual(snapshot.signedDistanceFromTop, 6)
        XCTAssertEqual(snapshot.distanceFromTop, 6)
        XCTAssertEqual(snapshot.pullDistance, 0)
        XCTAssertEqual(
            snapshot.visibleContentRect,
            CGRect(x: 0, y: 6, width: 376, height: 768)
        )
    }

    func testMotionStateClassifiesDirectDecelerationAndIdle() {
        var state = LegacyScrollTelemetryMotionState()

        XCTAssertEqual(state.update(sample(at: 0, y: 0)), .idle)
        XCTAssertEqual(
            state.update(sample(at: 0.01, y: 12, direct: true)),
            .direct
        )
        XCTAssertEqual(
            state.update(sample(at: 0.02, y: 24, decelerating: true)),
            .decelerating
        )
        XCTAssertEqual(state.update(sample(at: 0.05, y: 24)), .decelerating)
        XCTAssertEqual(state.update(sample(at: 0.11, y: 24)), .idle)
    }

    func testMotionStateClassifiesProgrammaticMovementWithoutPan() {
        var state = LegacyScrollTelemetryMotionState()

        XCTAssertEqual(state.update(sample(at: 0, y: 100)), .idle)
        XCTAssertEqual(state.update(sample(at: 0.01, y: 180)), .programmatic)
        XCTAssertEqual(state.update(sample(at: 0.04, y: 220)), .programmatic)
        XCTAssertEqual(state.update(sample(at: 0.09, y: 220)), .programmatic)
        XCTAssertEqual(state.update(sample(at: 0.13, y: 220)), .idle)
    }

    func testMotionStatePrioritizesDirectInteractionAndIgnoresSubpixelNoise() {
        var state = LegacyScrollTelemetryMotionState()

        _ = state.update(sample(at: 0, y: 0))
        XCTAssertEqual(
            state.update(sample(at: 0.01, y: 10, direct: true, decelerating: true)),
            .direct
        )
        XCTAssertEqual(
            state.update(sample(at: 0.02, y: 10.05)),
            .direct
        )
        XCTAssertEqual(state.update(sample(at: 0.10, y: 10.05)), .idle)
    }

    func testMotionStateWaitsForTerminalSettleBeforeLeavingDirectPhase() {
        var state = LegacyScrollTelemetryMotionState()

        XCTAssertEqual(state.update(sample(at: 0, y: 0)), .idle)
        XCTAssertEqual(state.update(sample(at: 0.01, y: -24, direct: true)), .direct)
        XCTAssertEqual(state.update(sample(at: 0.02, y: -24)), .direct)
        XCTAssertEqual(state.update(sample(at: 0.08, y: -24)), .direct)
        XCTAssertEqual(state.update(sample(at: 0.10, y: -24)), .idle)
    }

    func testMotionStateMovesFromDirectThroughProgrammaticReboundToIdle() {
        var state = LegacyScrollTelemetryMotionState()

        _ = state.update(sample(at: 0, y: 0))
        XCTAssertEqual(state.update(sample(at: 0.01, y: -40, direct: true)), .direct)
        XCTAssertEqual(state.update(sample(at: 0.02, y: -22)), .programmatic)
        XCTAssertEqual(state.update(sample(at: 0.09, y: -22)), .programmatic)
        XCTAssertEqual(state.update(sample(at: 0.11, y: -22)), .idle)
    }

    func testTerminalPanLeavesDirectPhaseImmediatelyWithoutDeceleration() {
        var state = LegacyScrollTelemetryMotionState()

        _ = state.update(sample(at: 0, y: 0))
        XCTAssertEqual(state.update(sample(at: 0.01, y: -40, direct: true)), .direct)
        XCTAssertEqual(
            state.finishDirectInteraction(sample(at: 0.02, y: -40)),
            .programmatic,
            "终态当帧不得继续广播 direct"
        )
        XCTAssertEqual(state.update(sample(at: 0.09, y: -40)), .programmatic)
        XCTAssertEqual(state.update(sample(at: 0.11, y: -40)), .idle)
    }

    func testTerminalPanTransitionsDirectlyToDecelerationWhenNeeded() {
        var state = LegacyScrollTelemetryMotionState()

        _ = state.update(sample(at: 0, y: 0))
        _ = state.update(sample(at: 0.01, y: 32, direct: true))
        XCTAssertEqual(
            state.finishDirectInteraction(
                sample(at: 0.02, y: 32, decelerating: true)
            ),
            .decelerating
        )
        XCTAssertEqual(state.update(sample(at: 0.04, y: 48, decelerating: true)), .decelerating)
        XCTAssertEqual(state.update(sample(at: 0.13, y: 48)), .idle)
    }

    func testSubscriberRegistrySharesOneLifecycleAcrossSubscribers() {
        var registry = LegacyScrollTelemetrySubscriberRegistry<String>()

        XCTAssertTrue(registry.insert("refresh"), "首个订阅者应安装共享观察器")
        XCTAssertFalse(registry.insert("reading"), "后续订阅者不得重复安装观察器")
        XCTAssertFalse(registry.insert("probe"))
        XCTAssertEqual(registry.identifiers, ["refresh", "reading", "probe"])

        XCTAssertFalse(registry.remove("reading"), "仍有订阅者时不得拆除共享观察器")
        XCTAssertEqual(registry.identifiers, ["refresh", "probe"])
        XCTAssertFalse(registry.remove("missing"))
        XCTAssertFalse(registry.remove("refresh"))
        XCTAssertTrue(registry.remove("probe"), "最后一个订阅者离开时才拆除共享观察器")
        XCTAssertTrue(registry.isEmpty)
    }

    func testSubscriberRegistryRejectsDuplicateSubscriptionWithoutChangingOrder() {
        var registry = LegacyScrollTelemetrySubscriberRegistry<Int>()

        XCTAssertTrue(registry.insert(1))
        XCTAssertFalse(registry.insert(1))
        XCTAssertFalse(registry.insert(2))
        XCTAssertEqual(registry.identifiers, [1, 2])
        XCTAssertFalse(registry.remove(1))
        XCTAssertTrue(registry.remove(2))
    }

    func testPanPolicyForwardsActiveAndTerminalStatesWithExactTranslation() throws {
        let translation = CGSize(width: 17, height: 81)
        let forwardedStates: [UIGestureRecognizer.State] = [
            .began,
            .changed,
            .ended,
            .cancelled,
            .failed
        ]

        for state in forwardedStates {
            let event = try XCTUnwrap(
                LegacyScrollTelemetryPanPolicy.event(
                    state: state,
                    translation: translation
                )
            )
            XCTAssertEqual(event.state, state)
            XCTAssertEqual(event.translation, translation)
        }

        XCTAssertNil(
            LegacyScrollTelemetryPanPolicy.event(
                state: .possible,
                translation: translation
            )
        )
    }

    func testThreadReadingTrackingReplacesLegacyViewportAtomically() {
        let state = ThreadReadingTrackingState()
        state.visiblePostIDs = [2001, 2002]

        XCTAssertTrue(state.replaceVisiblePostIDs([2002, 2003, 0]))
        XCTAssertEqual(state.visiblePostIDs, [2002, 2003])
        XCTAssertFalse(state.replaceVisiblePostIDs([2002, 2003]))
    }

    func testThreadVisibilityUsesViewportIntersectionInsteadOfMaterialization() {
        let entries: [UInt64: ThreadPostViewportEntry] = [
            2001: .init(postID: 2001, floor: 1, minY: -240, maxY: -40),
            2002: .init(postID: 2002, floor: 2, minY: -99, maxY: 1),
            2003: .init(postID: 2003, floor: 3, minY: 20, maxY: 220),
            2004: .init(postID: 2004, floor: 4, minY: 799, maxY: 899),
            2005: .init(postID: 2005, floor: 5, minY: 840, maxY: 940)
        ]

        XCTAssertEqual(
            ThreadReadingViewportPolicy.visiblePostIDs(
                entries: entries,
                viewportSize: CGSize(width: 390, height: 800),
                eligiblePostIDs: [2002, 2003, 2004, 2005]
            ),
            [2002, 2003, 2004]
        )
    }

    func testThreadVisibilityRejectsInvalidAndSubthresholdIntersections() {
        let entries: [UInt64: ThreadPostViewportEntry] = [
            2001: .init(postID: 2001, floor: 1, minY: .nan, maxY: 100),
            2002: .init(postID: 2002, floor: 2, minY: 800, maxY: 1_000),
            2003: .init(postID: 2003, floor: 3, minY: 799.5, maxY: 999.5),
            2004: .init(postID: 2004, floor: 4, minY: 10, maxY: 10)
        ]

        XCTAssertTrue(
            ThreadReadingViewportPolicy.visiblePostIDs(
                entries: entries,
                viewportSize: CGSize(width: 390, height: 800),
                eligiblePostIDs: Set(entries.keys)
            ).isEmpty
        )
        XCTAssertTrue(
            ThreadReadingViewportPolicy.visiblePostIDs(
                entries: entries,
                viewportSize: .zero,
                eligiblePostIDs: Set(entries.keys)
            ).isEmpty
        )
    }

    private func sample(
        at timestamp: TimeInterval,
        y: CGFloat,
        direct: Bool = false,
        decelerating: Bool = false
    ) -> LegacyScrollTelemetryMotionSample {
        LegacyScrollTelemetryMotionSample(
            timestamp: timestamp,
            contentOffset: CGPoint(x: 0, y: y),
            isDirectInteraction: direct,
            isDecelerating: decelerating
        )
    }
}
