import XCTest
import UIKit
@testable import TiebaPure

final class VideoPreviewTests: XCTestCase {
    func testPlaybackStartsOnlyAfterPresentationAndStopsForDismissal() {
        XCTAssertFalse(VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: false,
            dismissalStarted: false
        ))
        XCTAssertTrue(VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: true,
            dismissalStarted: false
        ))
        XCTAssertFalse(VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: true,
            dismissalStarted: true
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
