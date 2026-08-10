import SwiftUI
import UIKit
import ObjectiveC

enum LegacyScrollTelemetryPhase: Equatable, Sendable {
    case direct
    case decelerating
    case programmatic
    case idle
}

struct LegacyScrollTelemetrySnapshot: Equatable, Sendable {
    var phase: LegacyScrollTelemetryPhase
    var contentOffset: CGPoint
    var adjustedContentInset: UIEdgeInsets
    var viewportSize: CGSize
    var contentSize: CGSize

    var signedDistanceFromTop: CGFloat {
        contentOffset.y + adjustedContentInset.top
    }

    var distanceFromTop: CGFloat {
        max(signedDistanceFromTop, 0)
    }

    var pullDistance: CGFloat {
        max(-signedDistanceFromTop, 0)
    }

    /// The unobscured viewport expressed in the scroll view's content coordinates.
    var visibleContentRect: CGRect {
        CGRect(
            x: contentOffset.x + adjustedContentInset.left,
            y: contentOffset.y + adjustedContentInset.top,
            width: max(
                viewportSize.width
                    - adjustedContentInset.left
                    - adjustedContentInset.right,
                0
            ),
            height: max(
                viewportSize.height
                    - adjustedContentInset.top
                    - adjustedContentInset.bottom,
                0
            )
        )
    }
}

struct LegacyScrollTelemetryMotionSample: Equatable, Sendable {
    var timestamp: TimeInterval
    var contentOffset: CGPoint
    var isDirectInteraction: Bool
    var isDecelerating: Bool
}

struct LegacyScrollTelemetryMotionState: Equatable, Sendable {
    static let defaultIdleSettleInterval: TimeInterval = 0.08
    static let offsetTolerance: CGFloat = 0.1

    private(set) var phase: LegacyScrollTelemetryPhase = .idle
    private var previousOffset: CGPoint?
    private var lastMotionTimestamp: TimeInterval?

    @discardableResult
    mutating func update(
        _ sample: LegacyScrollTelemetryMotionSample,
        idleSettleInterval: TimeInterval = Self.defaultIdleSettleInterval
    ) -> LegacyScrollTelemetryPhase {
        guard let previousOffset else {
            self.previousOffset = sample.contentOffset
            if sample.isDirectInteraction {
                phase = .direct
                lastMotionTimestamp = sample.timestamp
            } else if sample.isDecelerating {
                phase = .decelerating
                lastMotionTimestamp = sample.timestamp
            }
            return phase
        }

        let offsetChanged = abs(sample.contentOffset.x - previousOffset.x) > Self.offsetTolerance
            || abs(sample.contentOffset.y - previousOffset.y) > Self.offsetTolerance
        self.previousOffset = sample.contentOffset

        if sample.isDirectInteraction {
            phase = .direct
            lastMotionTimestamp = sample.timestamp
        } else if sample.isDecelerating {
            phase = .decelerating
            lastMotionTimestamp = sample.timestamp
        } else if offsetChanged {
            phase = .programmatic
            lastMotionTimestamp = sample.timestamp
        } else if phase != .idle,
                  let lastMotionTimestamp,
                  sample.timestamp - lastMotionTimestamp >= idleSettleInterval {
            phase = .idle
            self.lastMotionTimestamp = nil
        }

        return phase
    }

    /// UIKit may still report `isDragging == true` while it dispatches the
    /// recognizer's terminal target action. A terminal event is authoritative:
    /// it must leave `.direct` immediately so a same-frame snapshot cannot
    /// start the gesture again after subscribers process the pan event.
    @discardableResult
    mutating func finishDirectInteraction(
        _ sample: LegacyScrollTelemetryMotionSample
    ) -> LegacyScrollTelemetryPhase {
        previousOffset = sample.contentOffset
        lastMotionTimestamp = sample.timestamp
        phase = sample.isDecelerating ? .decelerating : .programmatic
        return phase
    }
}

struct LegacyScrollPanEvent: Equatable, Sendable {
    var state: UIGestureRecognizer.State
    var translation: CGSize
}

enum LegacyScrollTelemetryPanPolicy {
    static func event(
        state: UIGestureRecognizer.State,
        translation: CGSize
    ) -> LegacyScrollPanEvent? {
        switch state {
        case .began, .changed, .ended, .cancelled, .failed:
            LegacyScrollPanEvent(state: state, translation: translation)
        case .possible:
            nil
        @unknown default:
            LegacyScrollPanEvent(state: state, translation: translation)
        }
    }
}

/// Maintains deterministic subscriber order and reports the two lifecycle
/// transitions that install or remove the shared UIKit observers.
struct LegacyScrollTelemetrySubscriberRegistry<Identifier: Hashable> {
    private(set) var identifiers: [Identifier] = []

    var isEmpty: Bool { identifiers.isEmpty }

    @discardableResult
    mutating func insert(_ identifier: Identifier) -> Bool {
        guard identifiers.contains(identifier) == false else { return false }
        let shouldActivate = identifiers.isEmpty
        identifiers.append(identifier)
        return shouldActivate
    }

    @discardableResult
    mutating func remove(_ identifier: Identifier) -> Bool {
        guard let index = identifiers.firstIndex(of: identifier) else { return false }
        identifiers.remove(at: index)
        return identifiers.isEmpty
    }
}

extension View {
    /// Observes the platform scroll view used by this SwiftUI hierarchy on
    /// iOS 16 and 17. The observer does not replace `UIScrollView.delegate` or
    /// install another pan recognizer, preserving native gesture arbitration.
    func legacyScrollTelemetry(
        onPanChange: ((LegacyScrollPanEvent) -> Void)? = nil,
        _ onChange: @escaping (LegacyScrollTelemetrySnapshot) -> Void
    ) -> some View {
        background {
            LegacyScrollTelemetryObserver(
                onChange: onChange,
                onPanChange: onPanChange
            )
        }
    }
}

private struct LegacyScrollTelemetryObserver: UIViewRepresentable {
    let onChange: (LegacyScrollTelemetrySnapshot) -> Void
    let onPanChange: ((LegacyScrollPanEvent) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onPanChange: onPanChange)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        view.onHierarchyChange = { [weak coordinator = context.coordinator] attachment in
            coordinator?.scheduleAttachment(from: attachment)
        }
        context.coordinator.scheduleAttachment(from: view)
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.update(
            onChange: onChange,
            onPanChange: onPanChange,
            from: uiView
        )
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        uiView.onHierarchyChange = nil
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        var onHierarchyChange: ((AttachmentView) -> Void)?
        private(set) var hierarchyGeneration: UInt = 0

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            hierarchyGeneration &+= 1
            onHierarchyChange?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hierarchyGeneration &+= 1
            onHierarchyChange?(self)
        }
    }

    final class LifecycleSentinel: UIView {
        var onWindowChange: ((LifecycleSentinel) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(self)
        }
    }

    final class Coordinator: NSObject {
        private var onChange: (LegacyScrollTelemetrySnapshot) -> Void
        private var onPanChange: ((LegacyScrollPanEvent) -> Void)?
        private weak var attachmentView: AttachmentView?
        private weak var scrollView: UIScrollView?
        private var hub: LegacyScrollTelemetryHub?
        private var subscriptionID: UUID?
        private var lifecycleSentinel: LifecycleSentinel?
        private var pendingAttachment: DispatchWorkItem?
        private var attachmentRequestID: UInt = 0
        private var attachedHierarchyGeneration: UInt?

        init(
            onChange: @escaping (LegacyScrollTelemetrySnapshot) -> Void,
            onPanChange: ((LegacyScrollPanEvent) -> Void)?
        ) {
            self.onChange = onChange
            self.onPanChange = onPanChange
        }

        func update(
            onChange: @escaping (LegacyScrollTelemetrySnapshot) -> Void,
            onPanChange: ((LegacyScrollPanEvent) -> Void)?,
            from attachment: AttachmentView
        ) {
            self.onChange = onChange
            self.onPanChange = onPanChange
            attachmentView = attachment
            guard hasUsableAttachment(for: attachment) == false else { return }
            scheduleAttachment(from: attachment)
        }

        func scheduleAttachment(from attachment: AttachmentView) {
            attachmentView = attachment
            attachmentRequestID &+= 1
            let requestID = attachmentRequestID
            let hierarchyGeneration = attachment.hierarchyGeneration
            pendingAttachment?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak attachment] in
                guard let self, let attachment,
                      self.attachmentRequestID == requestID,
                      attachment.hierarchyGeneration == hierarchyGeneration else { return }
                self.pendingAttachment = nil
                self.attach(
                    to: Self.enclosingScrollView(startingAt: attachment),
                    hierarchyGeneration: hierarchyGeneration
                )
            }
            pendingAttachment = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        func detach() {
            attachmentRequestID &+= 1
            pendingAttachment?.cancel()
            pendingAttachment = nil
            unsubscribeFromHub()
            lifecycleSentinel?.onWindowChange = nil
            lifecycleSentinel?.removeFromSuperview()
            lifecycleSentinel = nil
            scrollView = nil
            attachmentView = nil
            attachedHierarchyGeneration = nil
        }

        private func hasUsableAttachment(for attachment: AttachmentView) -> Bool {
            guard let scrollView,
                  hub?.scrollView === scrollView,
                  subscriptionID != nil,
                  lifecycleSentinel?.superview === scrollView,
                  attachedHierarchyGeneration == attachment.hierarchyGeneration,
                  let window = attachment.window,
                  scrollView.window === window else {
                return false
            }
            return true
        }

        private func attach(
            to newScrollView: UIScrollView?,
            hierarchyGeneration: UInt
        ) {
            guard let newScrollView else {
                detachPreservingAttachment()
                return
            }

            if scrollView === newScrollView,
               hub?.scrollView === newScrollView,
               subscriptionID != nil {
                attachedHierarchyGeneration = hierarchyGeneration
                installLifecycleSentinelIfNeeded(on: newScrollView)
                return
            }

            detachPreservingAttachment()
            scrollView = newScrollView
            attachedHierarchyGeneration = hierarchyGeneration
            let newHub = LegacyScrollTelemetryHub.shared(for: newScrollView)
            hub = newHub
            subscriptionID = newHub.subscribe(
                onSnapshot: { [weak self] snapshot in
                    self?.onChange(snapshot)
                },
                onPan: { [weak self] event in
                    self?.onPanChange?(event)
                }
            )
            installLifecycleSentinelIfNeeded(on: newScrollView)
        }

        private func detachPreservingAttachment() {
            unsubscribeFromHub()
            lifecycleSentinel?.onWindowChange = nil
            lifecycleSentinel?.removeFromSuperview()
            lifecycleSentinel = nil
            scrollView = nil
            attachedHierarchyGeneration = nil
        }

        private func unsubscribeFromHub() {
            if let subscriptionID {
                hub?.unsubscribe(subscriptionID)
            }
            subscriptionID = nil
            hub = nil
        }

        private func installLifecycleSentinelIfNeeded(on scrollView: UIScrollView) {
            if lifecycleSentinel?.superview === scrollView { return }
            lifecycleSentinel?.onWindowChange = nil
            lifecycleSentinel?.removeFromSuperview()
            let sentinel = LifecycleSentinel(frame: .zero)
            sentinel.isUserInteractionEnabled = false
            sentinel.isAccessibilityElement = false
            sentinel.backgroundColor = .clear
            sentinel.onWindowChange = { [weak self, weak sentinel] changedSentinel in
                guard changedSentinel === sentinel,
                      changedSentinel.window == nil,
                      let self,
                      let attachment = self.attachmentView else { return }
                self.scheduleAttachment(from: attachment)
            }
            lifecycleSentinel = sentinel
            scrollView.addSubview(sentinel)
        }

        private static func enclosingScrollView(startingAt attachment: UIView) -> UIScrollView? {
            var current = attachment.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    return scrollView
                }
                current = candidate.superview
            }

            guard let window = attachment.window else { return nil }
            let attachmentFrame = attachment.convert(attachment.bounds, to: window)
            guard attachmentFrame.isEmpty == false else { return nil }

            current = attachment.superview
            while let ancestor = current {
                let candidates = descendantScrollViews(of: ancestor)
                    .filter { $0.window === window && $0.isHidden == false }
                if let bestMatch = candidates.max(by: {
                    overlapScore(
                        scrollView: $0,
                        attachmentFrame: attachmentFrame,
                        window: window
                    ) < overlapScore(
                        scrollView: $1,
                        attachmentFrame: attachmentFrame,
                        window: window
                    )
                }), overlapScore(
                    scrollView: bestMatch,
                    attachmentFrame: attachmentFrame,
                    window: window
                ) > 0.5 {
                    return bestMatch
                }
                current = ancestor.superview
            }
            return nil
        }

        private static func descendantScrollViews(of root: UIView) -> [UIScrollView] {
            var result: [UIScrollView] = []
            var pending = root.subviews
            while let candidate = pending.popLast() {
                if let scrollView = candidate as? UIScrollView {
                    result.append(scrollView)
                }
                pending.append(contentsOf: candidate.subviews)
            }
            return result
        }

        private static func overlapScore(
            scrollView: UIScrollView,
            attachmentFrame: CGRect,
            window: UIWindow
        ) -> CGFloat {
            let scrollFrame = scrollView.convert(scrollView.bounds, to: window)
            let intersection = attachmentFrame.intersection(scrollFrame)
            guard intersection.isNull == false, intersection.isEmpty == false else { return 0 }
            let attachmentArea = max(attachmentFrame.width * attachmentFrame.height, 1)
            let overlapRatio = intersection.width * intersection.height / attachmentArea
            let widthSimilarity = min(scrollFrame.width, attachmentFrame.width)
                / max(scrollFrame.width, attachmentFrame.width, 1)
            let heightSimilarity = min(scrollFrame.height, attachmentFrame.height)
                / max(scrollFrame.height, attachmentFrame.height, 1)
            return overlapRatio * widthSimilarity * heightSimilarity
        }
    }
}

private enum LegacyScrollTelemetryHubAssociation {
    nonisolated(unsafe) static var key: UInt8 = 0
}

private final class LegacyScrollTelemetryHub: NSObject {
    struct Subscriber {
        let onSnapshot: (LegacyScrollTelemetrySnapshot) -> Void
        let onPan: (LegacyScrollPanEvent) -> Void
    }

    private(set) weak var scrollView: UIScrollView?
    private var subscribers: [UUID: Subscriber] = [:]
    private var subscriberRegistry = LegacyScrollTelemetrySubscriberRegistry<UUID>()
    private var observations: [NSKeyValueObservation] = []
    private var displayLink: CADisplayLink?
    private var motionState = LegacyScrollTelemetryMotionState()
    private var lastSnapshot: LegacyScrollTelemetrySnapshot?
    private var isActive = false

    static func shared(for scrollView: UIScrollView) -> LegacyScrollTelemetryHub {
        if let hub = objc_getAssociatedObject(
            scrollView,
            &LegacyScrollTelemetryHubAssociation.key
        ) as? LegacyScrollTelemetryHub {
            return hub
        }

        let hub = LegacyScrollTelemetryHub(scrollView: scrollView)
        objc_setAssociatedObject(
            scrollView,
            &LegacyScrollTelemetryHubAssociation.key,
            hub,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return hub
    }

    private init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()
    }

    deinit {
        deactivate()
    }

    func subscribe(
        onSnapshot: @escaping (LegacyScrollTelemetrySnapshot) -> Void,
        onPan: @escaping (LegacyScrollPanEvent) -> Void
    ) -> UUID {
        let identifier = UUID()
        subscribers[identifier] = Subscriber(onSnapshot: onSnapshot, onPan: onPan)
        let shouldActivate = subscriberRegistry.insert(identifier)
        if shouldActivate {
            activate()
        } else {
            emitCurrentSnapshot(to: identifier)
        }
        return identifier
    }

    func unsubscribe(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
        if subscriberRegistry.remove(identifier) {
            deactivate()
        }
    }

    private func activate() {
        guard isActive == false, let scrollView else { return }
        isActive = true
        motionState = LegacyScrollTelemetryMotionState()
        lastSnapshot = nil
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        observations = [
            scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.handleGeometryChange(isMotion: true)
            },
            scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                self?.handleGeometryChange(isMotion: false)
            },
            scrollView.observe(\.contentInset, options: [.new]) { [weak self] _, _ in
                self?.handleGeometryChange(isMotion: false)
            },
            scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.handleGeometryChange(isMotion: false)
            }
        ]
        sampleMotion(at: CACurrentMediaTime())
        if motionState.phase != .idle, motionState.phase != .direct {
            ensureDisplayLink()
        }
        emitSnapshotIfNeeded()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        displayLink?.invalidate()
        displayLink = nil
        observations.removeAll()
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
        motionState = LegacyScrollTelemetryMotionState()
        lastSnapshot = nil
    }

    private func handleGeometryChange(isMotion: Bool) {
        guard isActive, scrollView != nil else { return }
        if isMotion {
            sampleMotion(at: CACurrentMediaTime())
            if motionState.phase != .idle, motionState.phase != .direct {
                ensureDisplayLink()
            }
        }
        emitSnapshotIfNeeded()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.translation(in: recognizer.view)
        guard let event = LegacyScrollTelemetryPanPolicy.event(
            state: recognizer.state,
            translation: CGSize(width: point.x, height: point.y)
        ) else { return }

        let isTerminal = event.state == .ended
            || event.state == .cancelled
            || event.state == .failed
        if isTerminal {
            finishDirectInteraction(at: CACurrentMediaTime())
            ensureDisplayLink()
        } else {
            sampleMotion(at: CACurrentMediaTime())
        }

        // Pan first, snapshot second: a subscriber can reset/classify the
        // current gesture before consuming the geometry and phase from the same
        // recognizer event. This ordering replaces the previous two-target race.
        emitPan(event)
        emitSnapshotIfNeeded()
    }

    private func ensureDisplayLink() {
        guard isActive, displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func displayLinkTick(_ displayLink: CADisplayLink) {
        guard isActive, scrollView != nil else {
            deactivate()
            return
        }
        sampleMotion(at: displayLink.timestamp)
        emitSnapshotIfNeeded()
        if motionState.phase == .idle {
            displayLink.invalidate()
            self.displayLink = nil
        }
    }

    private func sampleMotion(at timestamp: TimeInterval) {
        guard let scrollView else { return }
        let recognizerState = scrollView.panGestureRecognizer.state
        let isDirectInteraction = scrollView.isTracking
            || scrollView.isDragging
            || recognizerState == .began
            || recognizerState == .changed
        motionState.update(
            LegacyScrollTelemetryMotionSample(
                timestamp: timestamp,
                contentOffset: scrollView.contentOffset,
                isDirectInteraction: isDirectInteraction,
                isDecelerating: scrollView.isDecelerating
            )
        )
    }

    private func finishDirectInteraction(at timestamp: TimeInterval) {
        guard let scrollView else { return }
        motionState.finishDirectInteraction(
            LegacyScrollTelemetryMotionSample(
                timestamp: timestamp,
                contentOffset: scrollView.contentOffset,
                isDirectInteraction: false,
                isDecelerating: scrollView.isDecelerating
            )
        )
    }

    private func emitSnapshotIfNeeded() {
        guard let scrollView else { return }
        let snapshot = LegacyScrollTelemetrySnapshot(
            phase: motionState.phase,
            contentOffset: scrollView.contentOffset,
            adjustedContentInset: scrollView.adjustedContentInset,
            viewportSize: scrollView.bounds.size,
            contentSize: scrollView.contentSize
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        let callbacks = subscriberRegistry.identifiers.compactMap {
            subscribers[$0]?.onSnapshot
        }
        callbacks.forEach { $0(snapshot) }
    }

    private func emitCurrentSnapshot(to identifier: UUID) {
        guard let scrollView, let callback = subscribers[identifier]?.onSnapshot else { return }
        callback(
            LegacyScrollTelemetrySnapshot(
                phase: motionState.phase,
                contentOffset: scrollView.contentOffset,
                adjustedContentInset: scrollView.adjustedContentInset,
                viewportSize: scrollView.bounds.size,
                contentSize: scrollView.contentSize
            )
        )
    }

    private func emitPan(_ event: LegacyScrollPanEvent) {
        let callbacks = subscriberRegistry.identifiers.compactMap {
            subscribers[$0]?.onPan
        }
        callbacks.forEach { $0(event) }
    }
}
