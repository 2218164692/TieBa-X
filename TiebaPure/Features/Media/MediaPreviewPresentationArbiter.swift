import Foundation
import UIKit

enum MediaPreviewPresentationKind: String, Equatable, Hashable {
    case image
    case video
    case safari
}

struct MediaPreviewPresentationRequest: Equatable, Hashable {
    let id: UUID
    let kind: MediaPreviewPresentationKind
    let sourceKey: String?

    init(
        id: UUID,
        kind: MediaPreviewPresentationKind,
        sourceKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sourceKey = sourceKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    func matchesSource(of other: MediaPreviewPresentationRequest) -> Bool {
        guard kind == other.kind,
              let sourceKey,
              let otherSourceKey = other.sourceKey else {
            return id == other.id
        }
        return sourceKey == otherSourceKey
    }
}

enum MediaPreviewPresentationPhase: Equatable {
    case idle
    case presenting(MediaPreviewPresentationRequest)
    case presented(MediaPreviewPresentationRequest)
    case dismissing(MediaPreviewPresentationRequest)
    case settling

    var activeRequest: MediaPreviewPresentationRequest? {
        switch self {
        case .idle, .settling:
            return nil
        case let .presenting(request),
             let .presented(request),
             let .dismissing(request):
            return request
        }
    }
}

enum MediaPreviewSubmissionDisposition: Equatable {
    case startNow
    case queued(replacing: MediaPreviewPresentationRequest?)
    case ignoredActive
}

enum MediaPreviewPresentationAttachmentPolicy {
    static func wasAccepted(
        presenterOwnsController: Bool,
        controllerHasPresenter: Bool,
        controllerHasWindow: Bool
    ) -> Bool {
        presenterOwnsController || controllerHasPresenter || controllerHasWindow
    }
}

/// UIKit can reject `present` asynchronously without invoking its completion
/// block. Verify the ownership relationship on the next main-runloop turn so
/// the global arbiter cannot remain stuck in `presenting` after that rejection.
@MainActor
enum MediaPreviewPresentationAttachmentVerifier {
    static func verify(
        controller: UIViewController,
        presenter: UIViewController,
        onRejected: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.async { [weak controller, weak presenter] in
            MainActor.assumeIsolated {
                guard let controller else {
                    onRejected()
                    return
                }
                let wasAccepted = MediaPreviewPresentationAttachmentPolicy.wasAccepted(
                    presenterOwnsController: presenter?.presentedViewController === controller,
                    controllerHasPresenter: controller.presentingViewController != nil,
                    controllerHasWindow: controller.viewIfLoaded?.window != nil
                )
                guard wasAccepted else {
                    onRejected()
                    return
                }
            }
        }
    }
}

/// Pure state machine behind the app-wide media modal arbiter.
///
/// `settling` is intentional: UIKit has completed the old modal dismissal,
/// but a new presentation is not allowed until the next main-runloop turn.
struct MediaPreviewPresentationArbiterState {
    private(set) var phase: MediaPreviewPresentationPhase = .idle
    private(set) var pendingRequest: MediaPreviewPresentationRequest?

    mutating func submit(
        _ request: MediaPreviewPresentationRequest
    ) -> MediaPreviewSubmissionDisposition {
        switch phase {
        case .idle:
            phase = .presenting(request)
            return .startNow
        case .presenting, .presented:
            guard phase.activeRequest?.matchesSource(of: request) != true else {
                return .ignoredActive
            }
            let replaced = pendingRequest
            pendingRequest = request
            return .queued(replacing: replaced)
        case .dismissing:
            let replaced = pendingRequest
            pendingRequest = request
            return .queued(replacing: replaced)
        case .settling:
            let replaced = pendingRequest
            pendingRequest = request
            return .queued(replacing: replaced)
        }
    }

    mutating func presentationDidFinish(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard phase == .presenting(request) else { return false }
        phase = .presented(request)
        return true
    }

    mutating func dismissalWillBegin(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        switch phase {
        case let .presenting(activeRequest),
             let .presented(activeRequest):
            guard activeRequest == request else { return false }
            phase = .dismissing(request)
            return true
        case let .dismissing(activeRequest):
            return activeRequest == request
        default:
            return false
        }
    }

    mutating func dismissalDidFinish(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard phase == .dismissing(request) else { return false }
        phase = .settling
        return true
    }

    mutating func presentationDidCancel(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard phase == .presenting(request) else { return false }
        phase = .settling
        return true
    }

    mutating func dismissalDidCancel(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard phase == .dismissing(request) else { return false }
        phase = .presented(request)
        return true
    }

    mutating func cancelPending(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        return true
    }

    /// Ends the post-dismissal barrier and reserves the next request for
    /// presentation. The caller must invoke the matching start closure.
    mutating func finishSettlement() -> MediaPreviewPresentationRequest? {
        guard phase == .settling else { return nil }
        guard let pendingRequest else {
            phase = .idle
            return nil
        }
        self.pendingRequest = nil
        phase = .presenting(pendingRequest)
        return pendingRequest
    }
}

/// Serializes image, direct-video, and Safari media presentations app-wide.
/// Only the newest request is retained while another modal is active.
@MainActor
final class MediaPreviewPresentationArbiter {
    static let shared = MediaPreviewPresentationArbiter()

    typealias StartAction = @MainActor () -> Bool

    private struct PendingPresentation {
        let request: MediaPreviewPresentationRequest
        let start: StartAction
    }

    private var state = MediaPreviewPresentationArbiterState()
    private var pendingPresentation: PendingPresentation?
    private var settlementScheduled = false

    private init() {}

    @discardableResult
    func submit(
        _ request: MediaPreviewPresentationRequest,
        start: @escaping StartAction
    ) -> Bool {
        let presentation = PendingPresentation(request: request, start: start)
        switch state.submit(request) {
        case .startNow:
            return startPresentation(presentation)
        case .queued:
            pendingPresentation = presentation
            return false
        case .ignoredActive:
            return false
        }
    }

    @discardableResult
    func presentationDidFinish(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        state.presentationDidFinish(request)
    }

    @discardableResult
    func dismissalWillBegin(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        state.dismissalWillBegin(request)
    }

    @discardableResult
    func dismissalDidFinish(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard state.dismissalDidFinish(request) else { return false }
        scheduleSettlement()
        return true
    }

    @discardableResult
    func presentationDidCancel(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard state.presentationDidCancel(request) else { return false }
        scheduleSettlement()
        return true
    }

    @discardableResult
    func dismissalDidCancel(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        state.dismissalDidCancel(request)
    }

    @discardableResult
    func cancelPending(
        _ request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard state.cancelPending(request) else { return false }
        if pendingPresentation?.request == request {
            pendingPresentation = nil
        }
        return true
    }

    private func startPresentation(
        _ presentation: PendingPresentation
    ) -> Bool {
        guard presentation.start() else {
            _ = state.presentationDidCancel(presentation.request)
            scheduleSettlement()
            return false
        }
        return true
    }

    private func scheduleSettlement() {
        guard settlementScheduled == false else { return }
        settlementScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.finishSettlement()
            }
        }
    }

    private func finishSettlement() {
        settlementScheduled = false
        guard let request = state.finishSettlement() else {
            pendingPresentation = nil
            return
        }
        guard let pendingPresentation,
              pendingPresentation.request == request else {
            _ = state.presentationDidCancel(request)
            scheduleSettlement()
            return
        }
        self.pendingPresentation = nil
        _ = startPresentation(pendingPresentation)
    }
}
