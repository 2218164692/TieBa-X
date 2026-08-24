import XCTest
import UIKit
@testable import TieBaX

final class VideoPreviewTests: XCTestCase {
    func testPlaybackStartsOnlyAfterPresentationAndStopsForDismissal() {
        XCTAssertFalse(VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: false,
            dismissalStarted: false,
            applicationIsActive: true
        ))
        XCTAssertTrue(VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: true,
            dismissalStarted: false,
            applicationIsActive: true
        ))
        XCTAssertFalse(VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: true,
            dismissalStarted: true,
            applicationIsActive: true
        ))
        XCTAssertFalse(VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: true,
            dismissalStarted: false,
            applicationIsActive: false
        ))
    }

    func testPosterStaysVisibleUntilFirstFrameAndDoesNotReturnAfterPlayback() {
        XCTAssertTrue(VideoPreviewPlaybackPolicy.keepsPosterVisible(
            firstFrameReady: false,
            dismissalStarted: false
        ))
        XCTAssertFalse(VideoPreviewPlaybackPolicy.keepsPosterVisible(
            firstFrameReady: true,
            dismissalStarted: false
        ))
        XCTAssertFalse(VideoPreviewPlaybackPolicy.keepsPosterVisible(
            firstFrameReady: true,
            dismissalStarted: true
        ))
    }

    func testVideoLoadingIndicatorStopsForFirstFrameFailureAndDismissal() {
        XCTAssertTrue(VideoPreviewLoadingIndicatorPolicy.shouldAnimate(
            isPreparing: true,
            firstFrameReady: false,
            hasFailure: false,
            dismissalStarted: false
        ))
        XCTAssertFalse(VideoPreviewLoadingIndicatorPolicy.shouldAnimate(
            isPreparing: true,
            firstFrameReady: true,
            hasFailure: false,
            dismissalStarted: false
        ))
        XCTAssertFalse(VideoPreviewLoadingIndicatorPolicy.shouldAnimate(
            isPreparing: true,
            firstFrameReady: false,
            hasFailure: true,
            dismissalStarted: false
        ))
        XCTAssertFalse(VideoPreviewLoadingIndicatorPolicy.shouldAnimate(
            isPreparing: true,
            firstFrameReady: false,
            hasFailure: false,
            dismissalStarted: true
        ))
    }

    func testDismissGestureClaimsOnlyRightwardHorizontalAndVerticalIntent() {
        XCTAssertEqual(
            VideoPreviewDismissGesturePolicy.axis(
                velocity: CGPoint(x: 900, y: 40)
            ),
            .horizontalRight
        )
        XCTAssertNil(VideoPreviewDismissGesturePolicy.axis(
            velocity: CGPoint(x: -900, y: 40)
        ))
        XCTAssertEqual(
            VideoPreviewDismissGesturePolicy.axis(
                velocity: CGPoint(x: 80, y: -900)
            ),
            .vertical
        )
        XCTAssertEqual(
            VideoPreviewDismissGesturePolicy.axis(
                velocity: CGPoint(x: 80, y: 900)
            ),
            .vertical
        )
        XCTAssertNil(VideoPreviewDismissGesturePolicy.axis(velocity: .zero))
    }

    func testDismissGestureUsesDistanceOrIntentionalFlickAndNeverMovesLeft() {
        let viewport = CGSize(width: 390, height: 844)

        XCTAssertEqual(
            VideoPreviewDismissGesturePolicy.adjustedTranslation(
                CGPoint(x: -40, y: 24),
                for: .horizontalRight
            ),
            CGPoint(x: 0, y: 24)
        )
        XCTAssertFalse(VideoPreviewDismissGesturePolicy.shouldDismiss(
            translation: CGPoint(x: 60, y: 0),
            velocity: CGPoint(x: 400, y: 0),
            axis: .horizontalRight,
            viewportSize: viewport
        ))
        XCTAssertTrue(VideoPreviewDismissGesturePolicy.shouldDismiss(
            translation: CGPoint(x: 100, y: 0),
            velocity: CGPoint(x: 400, y: 0),
            axis: .horizontalRight,
            viewportSize: viewport
        ))
        XCTAssertFalse(VideoPreviewDismissGesturePolicy.shouldDismiss(
            translation: CGPoint(x: 0, y: 100),
            velocity: CGPoint(x: 0, y: 400),
            axis: .vertical,
            viewportSize: viewport
        ))
        XCTAssertTrue(VideoPreviewDismissGesturePolicy.shouldDismiss(
            translation: CGPoint(x: 0, y: -160),
            velocity: CGPoint(x: 0, y: -400),
            axis: .vertical,
            viewportSize: viewport
        ))
        XCTAssertTrue(VideoPreviewDismissGesturePolicy.shouldDismiss(
            translation: CGPoint(x: 0, y: 65),
            velocity: CGPoint(x: 0, y: 1_100),
            axis: .vertical,
            viewportSize: viewport
        ))
    }

    func testDismissGestureBackgroundOpacityIsBoundedAndDistanceSensitive() {
        let viewport = CGSize(width: 390, height: 844)
        let resting = VideoPreviewDismissGesturePolicy.backgroundOpacity(
            translation: .zero,
            viewportSize: viewport
        )
        let dragged = VideoPreviewDismissGesturePolicy.backgroundOpacity(
            translation: CGPoint(x: 0, y: 180),
            viewportSize: viewport
        )
        let distant = VideoPreviewDismissGesturePolicy.backgroundOpacity(
            translation: CGPoint(x: 0, y: 1_000),
            viewportSize: viewport
        )

        XCTAssertEqual(resting, 1)
        XCTAssertLessThan(dragged, resting)
        XCTAssertEqual(distant, 0.28, accuracy: 0.001)
    }

    @MainActor
    func testDismissGestureAllowsButtonsButYieldsToContinuousControls() {
        let root = UIView()
        let plainSurface = UIView()
        let button = UIButton(type: .system)
        let buttonLabel = UILabel()
        let slider = UISlider()
        let adjustableControl = UIView()
        adjustableControl.accessibilityTraits = .adjustable

        root.addSubview(plainSurface)
        root.addSubview(button)
        button.addSubview(buttonLabel)
        root.addSubview(slider)
        root.addSubview(adjustableControl)

        XCTAssertTrue(VideoPreviewGestureTouchPolicy.allowsDismissGesture(
            startingAt: plainSurface
        ))
        XCTAssertTrue(VideoPreviewGestureTouchPolicy.allowsDismissGesture(
            startingAt: button
        ))
        XCTAssertTrue(VideoPreviewGestureTouchPolicy.allowsDismissGesture(
            startingAt: buttonLabel
        ))
        XCTAssertFalse(VideoPreviewGestureTouchPolicy.allowsDismissGesture(
            startingAt: slider
        ))
        XCTAssertFalse(VideoPreviewGestureTouchPolicy.allowsDismissGesture(
            startingAt: adjustableControl
        ))
    }

    func testDismissalLifecycleIsIdempotentAndCancellationRestoresActiveState() {
        var lifecycle = VideoPreviewDismissalLifecycleState()

        XCTAssertEqual(lifecycle.phase, .active)
        XCTAssertFalse(lifecycle.dismissalStarted)
        XCTAssertTrue(lifecycle.begin())
        XCTAssertFalse(lifecycle.begin())
        XCTAssertTrue(lifecycle.dismissalStarted)
        XCTAssertTrue(lifecycle.cancel())
        XCTAssertEqual(lifecycle.phase, .active)
        XCTAssertFalse(lifecycle.cancel())

        XCTAssertTrue(lifecycle.begin())
        XCTAssertTrue(lifecycle.finish())
        XCTAssertEqual(lifecycle.phase, .finished)
        XCTAssertFalse(lifecycle.finish())
        XCTAssertFalse(lifecycle.cancel())
    }

    func testDetachedControllerFinishesOnlyAfterBothOwnershipSignalsDisappear() {
        XCTAssertFalse(VideoPreviewDetachmentPolicy.shouldFinishDismissal(
            hasPresentingController: true,
            isInWindow: true
        ))
        XCTAssertFalse(VideoPreviewDetachmentPolicy.shouldFinishDismissal(
            hasPresentingController: false,
            isInWindow: true
        ))
        XCTAssertFalse(VideoPreviewDetachmentPolicy.shouldFinishDismissal(
            hasPresentingController: true,
            isInWindow: false
        ))
        XCTAssertTrue(VideoPreviewDetachmentPolicy.shouldFinishDismissal(
            hasPresentingController: false,
            isInWindow: false
        ))
    }

    func testSameVideoCanQueueImmediateReopenAcrossTenDismissalCycles() {
        let sourceKey = "fixture-video"
        var arbiter = MediaPreviewPresentationArbiterState()
        var active = MediaPreviewPresentationRequest(
            id: UUID(),
            kind: .video,
            sourceKey: sourceKey
        )
        XCTAssertEqual(arbiter.submit(active), .startNow)
        XCTAssertTrue(arbiter.presentationDidFinish(active))

        for _ in 1...10 {
            var lifecycle = VideoPreviewDismissalLifecycleState()
            XCTAssertTrue(lifecycle.begin())
            XCTAssertTrue(arbiter.dismissalWillBegin(active))

            let next = MediaPreviewPresentationRequest(
                id: UUID(),
                kind: .video,
                sourceKey: sourceKey
            )
            XCTAssertEqual(arbiter.submit(next), .queued(replacing: nil))

            XCTAssertTrue(lifecycle.finish())
            XCTAssertTrue(arbiter.dismissalDidFinish(active))
            XCTAssertEqual(arbiter.finishSettlement(), next)
            XCTAssertTrue(arbiter.presentationDidFinish(next))
            active = next
        }

        XCTAssertEqual(arbiter.phase, .presented(active))
    }

    func testVideoSourceIdentityIsStableAndContentSpecific() {
        let first = makeVideo(url: "https://video.example/first.mp4")
        let matching = makeVideo(url: "https://video.example/first.mp4")
        let second = makeVideo(url: "https://video.example/second.mp4")

        XCTAssertEqual(
            VideoPreviewSourceIdentityPolicy.identity(for: first),
            VideoPreviewSourceIdentityPolicy.identity(for: matching)
        )
        XCTAssertNotEqual(
            VideoPreviewSourceIdentityPolicy.identity(for: first),
            VideoPreviewSourceIdentityPolicy.identity(for: second)
        )
    }

    func testVideoReuseRejectsLoadStateAuthorizationAndAnchorFromPreviousVideo() {
        let oldIdentity = "video|old"
        let newIdentity = "video|new"

        XCTAssertEqual(
            VideoPreviewReusePolicy.effectiveLoadState(
                storedState: .success,
                storedIdentity: oldIdentity,
                currentIdentity: newIdentity
            ),
            .empty
        )
        XCTAssertFalse(VideoPreviewReusePolicy.isManualLoadAuthorized(
            authorizedIdentity: oldIdentity,
            currentIdentity: newIdentity
        ))
        XCTAssertFalse(VideoPreviewReusePolicy.canUseSourceAnchor(
            anchorIdentity: oldIdentity,
            currentIdentity: newIdentity
        ))
    }

    func testVideoReusePreservesStateOnlyForTheSameVideoIdentity() {
        let identity = "video|same"

        XCTAssertEqual(
            VideoPreviewReusePolicy.effectiveLoadState(
                storedState: .failure,
                storedIdentity: identity,
                currentIdentity: identity
            ),
            .failure
        )
        XCTAssertTrue(VideoPreviewReusePolicy.isManualLoadAuthorized(
            authorizedIdentity: identity,
            currentIdentity: identity
        ))
        XCTAssertTrue(VideoPreviewReusePolicy.canUseSourceAnchor(
            anchorIdentity: identity,
            currentIdentity: identity
        ))
    }

    func testPresentationAttachmentRequiresEitherUIKitOwnershipRelationship() {
        XCTAssertFalse(MediaPreviewPresentationAttachmentPolicy.wasAccepted(
            presenterOwnsController: false,
            controllerHasPresenter: false,
            controllerHasWindow: false
        ))
        XCTAssertTrue(MediaPreviewPresentationAttachmentPolicy.wasAccepted(
            presenterOwnsController: true,
            controllerHasPresenter: false,
            controllerHasWindow: false
        ))
        XCTAssertTrue(MediaPreviewPresentationAttachmentPolicy.wasAccepted(
            presenterOwnsController: false,
            controllerHasPresenter: true,
            controllerHasWindow: false
        ))
        XCTAssertTrue(MediaPreviewPresentationAttachmentPolicy.wasAccepted(
            presenterOwnsController: false,
            controllerHasPresenter: false,
            controllerHasWindow: true
        ))
    }

    func testMediaArbiterQueuesOnlyLatestCrossMediaRequestUntilSettlement() {
        let image = request(.image)
        let video = request(.video)
        let safari = request(.safari)
        var state = MediaPreviewPresentationArbiterState()

        XCTAssertEqual(state.submit(image), .startNow)
        XCTAssertTrue(state.presentationDidFinish(image))
        XCTAssertTrue(state.dismissalWillBegin(image))
        XCTAssertEqual(state.submit(video), .queued(replacing: nil))
        XCTAssertEqual(state.submit(safari), .queued(replacing: video))
        XCTAssertEqual(state.phase, .dismissing(image))

        XCTAssertTrue(state.dismissalDidFinish(image))
        XCTAssertEqual(state.phase, .settling)
        XCTAssertEqual(state.finishSettlement(), safari)
        XCTAssertEqual(state.phase, .presenting(safari))
    }

    func testMediaArbiterCancelledDismissalKeepsQueuedRequestBehindActiveModal() {
        let image = request(.image)
        let video = request(.video)
        var state = MediaPreviewPresentationArbiterState()

        XCTAssertEqual(state.submit(image), .startNow)
        XCTAssertTrue(state.presentationDidFinish(image))
        XCTAssertTrue(state.dismissalWillBegin(image))
        XCTAssertEqual(state.submit(video), .queued(replacing: nil))

        XCTAssertTrue(state.dismissalDidCancel(image))
        XCTAssertEqual(state.phase, .presented(image))
        XCTAssertEqual(state.pendingRequest, video)
        XCTAssertFalse(state.dismissalDidFinish(image))

        XCTAssertTrue(state.dismissalWillBegin(image))
        XCTAssertTrue(state.dismissalDidFinish(image))
        XCTAssertEqual(state.finishSettlement(), video)
    }

    func testMediaArbiterCanCancelQueuedCrossMediaRequest() {
        let image = request(.image)
        let video = request(.video)
        var state = MediaPreviewPresentationArbiterState()

        XCTAssertEqual(state.submit(image), .startNow)
        XCTAssertTrue(state.presentationDidFinish(image))
        XCTAssertTrue(state.dismissalWillBegin(image))
        XCTAssertEqual(state.submit(video), .queued(replacing: nil))
        XCTAssertTrue(state.cancelPending(video))
        XCTAssertNil(state.pendingRequest)
        XCTAssertTrue(state.dismissalDidFinish(image))
        XCTAssertNil(state.finishSettlement())
        XCTAssertEqual(state.phase, .idle)
    }

    func testMediaArbiterCoalescesRelayAndSwiftUITapForSameSource() {
        let sourceKey = "thread-1-video-1"
        let first = MediaPreviewPresentationRequest(
            id: UUID(),
            kind: .video,
            sourceKey: sourceKey
        )
        let duplicate = MediaPreviewPresentationRequest(
            id: UUID(),
            kind: .video,
            sourceKey: sourceKey
        )
        var state = MediaPreviewPresentationArbiterState()

        XCTAssertEqual(state.submit(first), .startNow)
        XCTAssertEqual(state.submit(duplicate), .ignoredActive)
        XCTAssertNil(state.pendingRequest)
    }

    func testMediaArbiterPresentationCancellationStartsQueuedRequestAfterBarrier() {
        let image = request(.image)
        let video = request(.video)
        var state = MediaPreviewPresentationArbiterState()

        XCTAssertEqual(state.submit(image), .startNow)
        XCTAssertEqual(state.submit(video), .queued(replacing: nil))
        XCTAssertTrue(state.presentationDidCancel(image))
        XCTAssertEqual(state.phase, .settling)
        XCTAssertEqual(state.finishSettlement(), video)
        XCTAssertEqual(state.phase, .presenting(video))
    }

    func testMediaArbiterRejectedPresentationWithoutPendingRequestReturnsToIdle() {
        let video = request(.video)
        var state = MediaPreviewPresentationArbiterState()

        XCTAssertEqual(state.submit(video), .startNow)
        XCTAssertTrue(state.presentationDidCancel(video))
        XCTAssertNil(state.finishSettlement())
        XCTAssertEqual(state.phase, .idle)
    }

    @MainActor
    func testVideoSessionCapturesExactSourceTokenAndRejectsInvalidFrame() {
        let identity = "fixture-video-source"
        let anchor = ImagePreviewSourceAnchor(sourceIdentity: identity)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
            UIColor.systemBlue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        anchor.store(image: image, sourceIdentity: identity)

        let session = VideoPreviewSession(
            video: makeVideo(url: "https://video.example/fixture.mp4"),
            sourceFrame: .zero,
            sourceImage: image,
            sourceAnchor: anchor
        )

        XCTAssertEqual(session.sourceIdentity, identity)
        XCTAssertEqual(session.sourceToken, anchor.transitionToken)
        XCTAssertTrue(session.sourceImage === image)
        XCTAssertNil(session.sourceFrame)
    }

    private func makeVideo(url: String) -> VideoContent {
        VideoContent(
            videoURL: URL(string: url),
            coverURL: URL(string: "https://video.example/cover.jpg"),
            webURL: URL(string: "https://tieba.baidu.com/p/1"),
            width: 1920,
            height: 1080,
            duration: 120
        )
    }

    private func request(
        _ kind: MediaPreviewPresentationKind
    ) -> MediaPreviewPresentationRequest {
        MediaPreviewPresentationRequest(id: UUID(), kind: kind)
    }
}
