import AVKit
import SafariServices
import UIKit

enum VideoPreviewPlaybackPolicy {
    static func shouldPlay(
        presentationFinished: Bool,
        dismissalStarted: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        presentationFinished && dismissalStarted == false && applicationIsActive
    }

    static func keepsPosterVisible(
        firstFrameReady: Bool,
        dismissalStarted: Bool
    ) -> Bool {
        _ = dismissalStarted
        return firstFrameReady == false
    }
}

enum VideoPreviewLoadingIndicatorPolicy {
    static func shouldAnimate(
        isPreparing: Bool,
        firstFrameReady: Bool,
        hasFailure: Bool,
        dismissalStarted: Bool
    ) -> Bool {
        isPreparing
            && firstFrameReady == false
            && hasFailure == false
            && dismissalStarted == false
    }
}

enum VideoPreviewDismissAxis: Equatable {
    case horizontalRight
    case vertical
}

enum VideoPreviewDismissGesturePolicy {
    private static let horizontalDominance: CGFloat = 1.15

    static func axis(velocity: CGPoint) -> VideoPreviewDismissAxis? {
        let horizontalSpeed = abs(velocity.x)
        let verticalSpeed = abs(velocity.y)
        guard horizontalSpeed > 0 || verticalSpeed > 0 else { return nil }

        if horizontalSpeed > verticalSpeed * horizontalDominance {
            return velocity.x > 0 ? .horizontalRight : nil
        }
        return .vertical
    }

    static func adjustedTranslation(
        _ translation: CGPoint,
        for axis: VideoPreviewDismissAxis
    ) -> CGPoint {
        switch axis {
        case .horizontalRight:
            return CGPoint(x: max(translation.x, 0), y: translation.y)
        case .vertical:
            return translation
        }
    }

    static func shouldDismiss(
        translation: CGPoint,
        velocity: CGPoint,
        axis: VideoPreviewDismissAxis,
        viewportSize: CGSize
    ) -> Bool {
        switch axis {
        case .horizontalRight:
            let distanceThreshold = min(max(viewportSize.width * 0.24, 88), 160)
            return translation.x >= distanceThreshold
                || (translation.x >= 44 && velocity.x >= 900)
        case .vertical:
            let distanceThreshold = min(max(viewportSize.height * 0.18, 120), 180)
            return abs(translation.y) >= distanceThreshold
                || (abs(translation.y) >= 60 && abs(velocity.y) >= 1_000)
        }
    }

    static func backgroundOpacity(
        translation: CGPoint,
        viewportSize: CGSize
    ) -> CGFloat {
        let diagonal = hypot(translation.x, translation.y)
        let reference = max(min(viewportSize.width, viewportSize.height) * 0.65, 1)
        return max(0.28, 1 - min(diagonal / reference, 1) * 0.72)
    }
}

@MainActor
enum VideoPreviewGestureTouchPolicy {
    static func allowsDismissGesture(startingAt view: UIView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current is UISlider || current.accessibilityTraits.contains(.adjustable) {
                return false
            }
            candidate = current.superview
        }
        return true
    }
}

struct VideoPreviewDismissalLifecycleState {
    enum Phase: Equatable {
        case active
        case dismissing
        case finished
    }

    private(set) var phase: Phase = .active

    var dismissalStarted: Bool {
        phase != .active
    }

    mutating func begin() -> Bool {
        guard phase == .active else { return false }
        phase = .dismissing
        return true
    }

    mutating func finish() -> Bool {
        guard phase == .dismissing else { return false }
        phase = .finished
        return true
    }

    mutating func cancel() -> Bool {
        guard phase == .dismissing else { return false }
        phase = .active
        return true
    }
}

enum VideoPreviewDetachmentPolicy {
    static func shouldFinishDismissal(
        hasPresentingController: Bool,
        isInWindow: Bool
    ) -> Bool {
        hasPresentingController == false && isInWindow == false
    }
}

struct VideoPreviewSession: Identifiable {
    let id = UUID()
    let video: VideoContent
    let sourceFrame: CGRect?
    let sourceImage: UIImage?
    let sourceAnchor: ImagePreviewSourceAnchor?
    let sourceToken: ImagePreviewSourceToken?
    let sourceIdentity: String?

    @MainActor
    init(
        video: VideoContent,
        sourceFrame: CGRect? = nil,
        sourceImage: UIImage? = nil,
        sourceAnchor: ImagePreviewSourceAnchor? = nil,
        sourceIdentity: String? = nil
    ) {
        self.video = video
        self.sourceFrame = ImagePreviewTransitionGeometry.validSourceFrame(sourceFrame)
        self.sourceImage = sourceImage
        self.sourceAnchor = sourceAnchor
        sourceToken = sourceAnchor?.transitionToken
        self.sourceIdentity = sourceIdentity ?? sourceAnchor?.sourceIdentity
    }
}

@MainActor
final class VideoPreviewCoordinator {
    static let shared = VideoPreviewCoordinator()

    private let arbiter = MediaPreviewPresentationArbiter.shared
    private var activeController: VideoPreviewController?
    private var activeSafariDriver: MediaPreviewSafariDriver?

    private init() {}

    @discardableResult
    func present(_ session: VideoPreviewSession) -> Bool {
        if let videoURL = TiebaVideoSourcePolicy.videoURL(session.video.videoURL) {
            let request = MediaPreviewPresentationRequest(
                id: session.id,
                kind: .video,
                sourceKey: session.sourceIdentity ?? videoURL.absoluteString
            )
            return arbiter.submit(request) { [weak self] in
                self?.startVideo(
                    session,
                    videoURL: videoURL,
                    request: request
                ) ?? false
            }
        }

        guard let webURL = TiebaVideoSourcePolicy.webpageURL(session.video.webURL) else {
            return false
        }
        let request = MediaPreviewPresentationRequest(
            id: session.id,
            kind: .safari,
            sourceKey: webURL.absoluteString
        )
        return arbiter.submit(request) { [weak self] in
            self?.startSafari(webURL: webURL, request: request) ?? false
        }
    }

    private func startVideo(
        _ session: VideoPreviewSession,
        videoURL: URL,
        request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard let presenter = ImagePreviewCoordinator.topPresenter() else {
            return false
        }
        let controller = VideoPreviewController(
            session: session,
            videoURL: videoURL,
            onDismissalBegan: { [weak self] sessionID in
                self?.beginDismissal(sessionID: sessionID, request: request)
            },
            onDismissalFinished: { [weak self] sessionID in
                self?.finishVideoDismissal(sessionID: sessionID, request: request)
            },
            onPresentationCancelled: { [weak self] sessionID in
                self?.cancelVideoPresentation(sessionID: sessionID, request: request)
            },
            onDismissalCancelled: { [weak self] sessionID in
                self?.cancelDismissal(sessionID: sessionID, request: request)
            }
        )
        controller.modalPresentationStyle = .overFullScreen
        controller.modalPresentationCapturesStatusBarAppearance = true
        controller.isModalInPresentation = true
        controller.transitioningDelegate = controller
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        activeController = controller

        presenter.present(
            controller,
            animated: ImagePreviewTransitionMotionPolicy.animationsEnabled
        ) { [weak self, weak controller] in
            guard let self,
                  self.arbiter.presentationDidFinish(request) else {
                return
            }
            controller?.finishPresentationIfNeeded()
        }
        MediaPreviewPresentationAttachmentVerifier.verify(
            controller: controller,
            presenter: presenter
        ) { [weak controller] in
            controller?.heroPresentationDidCancel()
        }
        return true
    }

    private func startSafari(
        webURL: URL,
        request: MediaPreviewPresentationRequest
    ) -> Bool {
        guard let presenter = ImagePreviewCoordinator.topPresenter() else {
            return false
        }
        let controller = SFSafariViewController(url: webURL)
        let driver = MediaPreviewSafariDriver(
            request: request,
            controller: controller,
            onDismissalBegan: { [weak self] request in
                _ = self?.arbiter.dismissalWillBegin(request)
            },
            onDismissalFinished: { [weak self] request in
                self?.finishSafariDismissal(request)
            },
            onDismissalCancelled: { [weak self] request in
                _ = self?.arbiter.dismissalDidCancel(request)
            }
        )
        controller.delegate = driver
        activeSafariDriver = driver
        presenter.present(controller, animated: true) { [weak self, weak driver] in
            guard let self, let driver else { return }
            driver.installPresentationDelegate()
            _ = self.arbiter.presentationDidFinish(request)
        }
        MediaPreviewPresentationAttachmentVerifier.verify(
            controller: controller,
            presenter: presenter
        ) { [weak self] in
            self?.cancelSafariPresentation(request)
        }
        return true
    }

    private func beginDismissal(
        sessionID: UUID,
        request: MediaPreviewPresentationRequest
    ) {
        guard sessionID == request.id else { return }
        _ = arbiter.dismissalWillBegin(request)
    }

    private func finishVideoDismissal(
        sessionID: UUID,
        request: MediaPreviewPresentationRequest
    ) {
        guard sessionID == request.id else { return }
        if activeController?.session.id == sessionID {
            activeController = nil
        }
        _ = arbiter.dismissalDidFinish(request)
    }

    private func cancelVideoPresentation(
        sessionID: UUID,
        request: MediaPreviewPresentationRequest
    ) {
        guard sessionID == request.id,
              arbiter.presentationDidCancel(request) else {
            return
        }
        if activeController?.session.id == sessionID {
            activeController = nil
        }
    }

    private func cancelDismissal(
        sessionID: UUID,
        request: MediaPreviewPresentationRequest
    ) {
        guard sessionID == request.id else { return }
        _ = arbiter.dismissalDidCancel(request)
    }

    private func finishSafariDismissal(
        _ request: MediaPreviewPresentationRequest
    ) {
        if activeSafariDriver?.request == request {
            activeSafariDriver = nil
        }
        _ = arbiter.dismissalDidFinish(request)
    }

    private func cancelSafariPresentation(
        _ request: MediaPreviewPresentationRequest
    ) {
        guard arbiter.presentationDidCancel(request) else { return }
        if activeSafariDriver?.request == request {
            activeSafariDriver = nil
        }
    }
}

@MainActor
private final class MediaPreviewSafariDriver: NSObject,
    @preconcurrency SFSafariViewControllerDelegate,
    UIAdaptivePresentationControllerDelegate {
    let request: MediaPreviewPresentationRequest

    private weak var controller: SFSafariViewController?
    private let onDismissalBegan: (MediaPreviewPresentationRequest) -> Void
    private let onDismissalFinished: (MediaPreviewPresentationRequest) -> Void
    private let onDismissalCancelled: (MediaPreviewPresentationRequest) -> Void
    private var dismissalInteractionGate: MediaPreviewDismissalInteractionGate?
    private var didBeginDismissal = false
    private var didFinishDismissal = false

    init(
        request: MediaPreviewPresentationRequest,
        controller: SFSafariViewController,
        onDismissalBegan: @escaping (MediaPreviewPresentationRequest) -> Void,
        onDismissalFinished: @escaping (MediaPreviewPresentationRequest) -> Void,
        onDismissalCancelled: @escaping (MediaPreviewPresentationRequest) -> Void
    ) {
        self.request = request
        self.controller = controller
        self.onDismissalBegan = onDismissalBegan
        self.onDismissalFinished = onDismissalFinished
        self.onDismissalCancelled = onDismissalCancelled
        super.init()
    }

    func installPresentationDelegate() {
        controller?.presentationController?.delegate = self
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        beginDismissalIfNeeded()
        controller.dismiss(animated: true) { [weak self] in
            self?.finishDismissalIfNeeded()
        }
    }

    func presentationControllerWillDismiss(
        _ presentationController: UIPresentationController
    ) {
        beginDismissalIfNeeded()
        presentationController.presentedViewController.transitionCoordinator?
            .notifyWhenInteractionChanges { [weak self] context in
                guard context.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.cancelDismissalIfNeeded()
                }
            }
    }

    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        finishDismissalIfNeeded()
    }

    private func beginDismissalIfNeeded() {
        guard didBeginDismissal == false else { return }
        didBeginDismissal = true
        onDismissalBegan(request)
        if let window = controller?.view.window {
            dismissalInteractionGate = MediaPreviewDismissalInteractionGate(
                onTapAtWindowPoint: { point, window in
                    ImagePreviewSourceRegistry.shared.activateSource(
                        at: point,
                        in: window
                    )
                }
            )
            .installed(in: window)
        }
    }

    private func finishDismissalIfNeeded() {
        guard didFinishDismissal == false else { return }
        didFinishDismissal = true
        guard let dismissalInteractionGate else {
            onDismissalFinished(request)
            return
        }
        self.dismissalInteractionGate = nil
        dismissalInteractionGate.transitionDidComplete { [request, onDismissalFinished] in
            onDismissalFinished(request)
        }
    }

    private func cancelDismissalIfNeeded() {
        guard didBeginDismissal, didFinishDismissal == false else { return }
        didBeginDismissal = false
        dismissalInteractionGate?.cancel()
        dismissalInteractionGate = nil
        onDismissalCancelled(request)
    }
}

@MainActor
private final class VideoPreviewController: UIViewController,
    UIAdaptivePresentationControllerDelegate,
    UIViewControllerTransitioningDelegate,
    UIGestureRecognizerDelegate,
    MediaPreviewHeroTransitionParticipant {
    let session: VideoPreviewSession

    private let videoURL: URL
    private let player = AVPlayer()
    private let playerController = AVPlayerViewController()
    private let audioSessionLifecycle: VideoAudioSessionLifecycle
    private let posterView = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let failureView = UIView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let onDismissalBegan: (UUID) -> Void
    private let onDismissalFinished: (UUID) -> Void
    private let onPresentationCancelled: (UUID) -> Void
    private let onDismissalCancelled: (UUID) -> Void

    private var readyObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var failedToPlayObserver: NSObjectProtocol?
    private var voicePlaybackObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var posterAnimator: UIViewPropertyAnimator?
    private var gestureRestoreAnimator: UIViewPropertyAnimator?
    private var dismissalInteractionGate: MediaPreviewDismissalInteractionGate?
    private var videoPreparationTask: Task<Void, Never>?
    private var videoPreparationID: UUID?
    private var videoFileLease: TiebaVideoFileLease?
    private var didCancelPresentation = false
    private var didFinishPresentation = false
    private var dismissalLifecycle = VideoPreviewDismissalLifecycleState()
    private var didReleasePlayer = false
    private var firstFrameReady = false
    private var isPreparingVideo = false
    private var hasPlaybackFailure = false
    private lazy var dismissPanGestureRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleDismissPan(_:))
    )
    private var activeDismissAxis: VideoPreviewDismissAxis?

    init(
        session: VideoPreviewSession,
        videoURL: URL,
        onDismissalBegan: @escaping (UUID) -> Void,
        onDismissalFinished: @escaping (UUID) -> Void,
        onPresentationCancelled: @escaping (UUID) -> Void,
        onDismissalCancelled: @escaping (UUID) -> Void,
        audioSessionLifecycle: VideoAudioSessionLifecycle? = nil
    ) {
        self.session = session
        self.videoURL = videoURL
        self.audioSessionLifecycle = audioSessionLifecycle ?? VideoAudioSessionLifecycle()
        self.onDismissalBegan = onDismissalBegan
        self.onDismissalFinished = onDismissalFinished
        self.onPresentationCancelled = onPresentationCancelled
        self.onDismissalCancelled = onDismissalCancelled
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = false

        playerController.player = player
        playerController.showsPlaybackControls = true
        playerController.videoGravity = .resizeAspect
        playerController.view.accessibilityIdentifier = "full-screen-video-player"
        addChild(playerController)
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)

        configureContentOverlay()
        configureDismissGesture()
        observePlayback()
        startVideoPreparation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerController.view.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
        finishPresentationIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else {
            return
        }
        beginDismissalIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.finishDetachedDismissalIfNeeded()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        .fade
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        MediaPreviewHeroAnimator(operation: .presentation, participant: self)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        MediaPreviewHeroAnimator(operation: .dismissal, participant: self)
    }

    func presentationControllerWillDismiss(
        _ presentationController: UIPresentationController
    ) {
        beginDismissalIfNeeded()
    }

    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        finishDismissalIfNeeded()
    }

    var mediaPreviewHeroSourceIdentity: String? {
        session.sourceIdentity
    }

    func mediaPreviewStableSourceView(
        in sourceViewController: UIViewController
    ) -> ImagePreviewSourceView? {
        guard let sourceView = ImagePreviewSourceResolver.view(
            exactAnchor: session.sourceAnchor,
            token: session.sourceToken,
            sourceIdentity: session.sourceIdentity
        ) as? ImagePreviewSourceView,
        let sourceWindow = sourceView.window else {
            return nil
        }
        sourceViewController.loadViewIfNeeded()
        let container = sourceViewController.view!
        guard container.window === sourceWindow,
              sourceView.isDescendant(of: container),
              ImagePreviewTransitionGeometry.fullyVisibleFrame(
                of: sourceView,
                in: sourceWindow
              ) != nil else {
            return nil
        }
        return sourceView
    }

    func mediaPreviewHeroDismissalContent(
        sourceView: ImagePreviewSourceView,
        dismissedView: UIView,
        containerView: UIView
    ) -> MediaPreviewHeroDismissalContent? {
        guard firstFrameReady == false,
              let image = session.sourceImage ?? sourceView.image else {
            return nil
        }
        let posterBounds = posterView.convert(posterView.bounds, to: containerView)
        return MediaPreviewHeroDismissalContent(
            image: image,
            frame: ImagePreviewTransitionGeometry.aspectFitFrame(
                imageSize: image.size,
                in: ImagePreviewTransitionGeometry.validSourceFrame(posterBounds)
                    ?? dismissedView.frame
            )
        )
    }

    func mediaPreviewHeroTransitionDidCancel(
        _ operation: MediaPreviewHeroOperation
    ) {
        switch operation {
        case .presentation:
            heroPresentationDidCancel()
        case .dismissal:
            heroDismissalDidCancel()
        }
    }

    func finishPresentationIfNeeded() {
        guard didFinishPresentation == false else { return }
        didFinishPresentation = true
        updatePlaybackState()
    }

    func beginDismissalIfNeeded() {
        guard dismissalLifecycle.begin() else { return }
        prepareForDismissal()
        onDismissalBegan(session.id)
        if let window = view.window {
            dismissalInteractionGate = MediaPreviewDismissalInteractionGate(
                onTapAtWindowPoint: { point, window in
                    ImagePreviewSourceRegistry.shared.activateSource(
                        at: point,
                        in: window
                    )
                }
            )
            .installed(in: window)
        }
    }

    func finishDismissalIfNeeded() {
        guard dismissalLifecycle.finish() else { return }
        releasePlayer()
        let finish = onDismissalFinished
        let sessionID = session.id
        guard let dismissalInteractionGate else {
            finish(sessionID)
            return
        }
        self.dismissalInteractionGate = nil
        dismissalInteractionGate.transitionDidComplete {
            finish(sessionID)
        }
    }

    func heroPresentationDidCancel() {
        guard didCancelPresentation == false else { return }
        didCancelPresentation = true
        releasePlayer()
        onPresentationCancelled(session.id)
    }

    func heroDismissalDidCancel() {
        guard dismissalLifecycle.cancel() else { return }
        dismissalInteractionGate?.cancel()
        dismissalInteractionGate = nil
        restoreVideoAfterCancelledDismissal(animated: false)
        playerController.showsPlaybackControls = true
        updatePosterVisibility(animated: false)
        startVideoPreparation()
        onDismissalCancelled(session.id)
    }

    @discardableResult
    private func requestDismissal() -> Bool {
        guard presentingViewController != nil,
              isBeingDismissed == false,
              dismissalLifecycle.phase == .active else {
            return false
        }
        beginDismissalIfNeeded()
        dismiss(animated: ImagePreviewTransitionMotionPolicy.animationsEnabled) { [weak self] in
            self?.finishDismissalIfNeeded()
        }
        return true
    }

    @objc
    private func retryPlayback() {
        guard didReleasePlayer == false,
              dismissalLifecycle.phase == .active else {
            return
        }
        failureView.isHidden = true
        startVideoPreparation()
    }

    private func configureContentOverlay() {
        let overlay = playerController.contentOverlayView ?? playerController.view!

        posterView.image = session.sourceImage
        posterView.contentMode = .scaleAspectFit
        posterView.backgroundColor = .black
        posterView.isUserInteractionEnabled = false
        posterView.accessibilityElementsHidden = true
        posterView.alpha = session.sourceImage == nil ? 0 : 1
        posterView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(posterView)

        failureView.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        failureView.layer.cornerRadius = 8
        failureView.isHidden = true
        failureView.accessibilityIdentifier = "video-playback-failure"
        failureView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(failureView)

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.isAccessibilityElement = true
        loadingIndicator.accessibilityIdentifier = "video-loading-indicator"
        loadingIndicator.accessibilityLabel = "正在加载视频"
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(loadingIndicator)

        failureLabel.text = "视频加载失败\n请检查网络后重试"
        failureLabel.font = .preferredFont(forTextStyle: .body)
        failureLabel.textColor = .white
        failureLabel.textAlignment = .center
        failureLabel.numberOfLines = 0
        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureView.addSubview(failureLabel)

        var retryConfiguration = UIButton.Configuration.filled()
        retryConfiguration.title = "重试"
        retryConfiguration.baseForegroundColor = .white
        retryConfiguration.baseBackgroundColor = .systemBlue
        retryConfiguration.cornerStyle = .medium
        retryButton.configuration = retryConfiguration
        retryButton.addTarget(self, action: #selector(retryPlayback), for: .touchUpInside)
        retryButton.accessibilityLabel = "重试播放视频"
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        failureView.addSubview(retryButton)

        NSLayoutConstraint.activate([
            posterView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            posterView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            posterView.topAnchor.constraint(equalTo: overlay.topAnchor),
            posterView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            failureView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            failureView.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            failureView.leadingAnchor.constraint(
                greaterThanOrEqualTo: overlay.leadingAnchor,
                constant: 24
            ),
            failureView.trailingAnchor.constraint(
                lessThanOrEqualTo: overlay.trailingAnchor,
                constant: -24
            ),
            failureLabel.leadingAnchor.constraint(equalTo: failureView.leadingAnchor, constant: 20),
            failureLabel.trailingAnchor.constraint(equalTo: failureView.trailingAnchor, constant: -20),
            failureLabel.topAnchor.constraint(equalTo: failureView.topAnchor, constant: 18),
            retryButton.topAnchor.constraint(equalTo: failureLabel.bottomAnchor, constant: 14),
            retryButton.centerXAnchor.constraint(equalTo: failureView.centerXAnchor),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryButton.bottomAnchor.constraint(equalTo: failureView.bottomAnchor, constant: -18)
        ])
    }

    private func configureDismissGesture() {
        dismissPanGestureRecognizer.maximumNumberOfTouches = 1
        dismissPanGestureRecognizer.cancelsTouchesInView = false
        dismissPanGestureRecognizer.delegate = self
        view.addGestureRecognizer(dismissPanGestureRecognizer)
    }

    private func startVideoPreparation() {
        cancelVideoPreparation(removePreparedFile: true, clearsPlayerItem: true)
        failureLabel.text = "视频加载失败\n请检查网络后重试"
        failureView.isHidden = true
        firstFrameReady = false
        isPreparingVideo = true
        hasPlaybackFailure = false
        updateLoadingIndicator()
        updatePosterVisibility(animated: false)

        let preparationID = UUID()
        videoPreparationID = preparationID
        videoPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let lease = try await TiebaVideoDownloadClient.shared.download(from: videoURL)
                try Task.checkCancellation()
                guard didReleasePlayer == false,
                      dismissalLifecycle.phase == .active,
                      videoPreparationID == preparationID else {
                    lease.release()
                    return
                }
                videoPreparationTask = nil
                videoPreparationID = nil
                videoFileLease = lease
                installPlayerItem(fileURL: lease.fileURL)
                updatePlaybackState()
            } catch is CancellationError {
                guard videoPreparationID == preparationID else { return }
                videoPreparationTask = nil
                videoPreparationID = nil
            } catch {
                guard Task.isCancelled == false,
                      didReleasePlayer == false,
                      dismissalLifecycle.phase == .active,
                      videoPreparationID == preparationID else {
                    return
                }
                videoPreparationTask = nil
                videoPreparationID = nil
                showPlaybackFailure()
            }
        }
    }

    private func installPlayerItem(fileURL: URL) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }

        let item = AVPlayerItem(url: fileURL)
        player.replaceCurrentItem(with: item)
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item,
                      self.player.currentItem === item else {
                    return
                }
                self.handlePlayerItemStatus(item.status)
            }
        }
        failedToPlayObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item,
                      self.player.currentItem === item else {
                    return
                }
                self.showPlaybackFailure()
            }
        }
    }

    private func observePlayback() {
        readyObservation = playerController.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            guard controller.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                self?.receiveFirstFrameReady()
            }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] player, change in
            guard let status = change.newValue else { return }
            DispatchQueue.main.async {
                guard player.timeControlStatus == status else { return }
                self?.handleTimeControlStatus(status)
            }
        }
        voicePlaybackObserver = NotificationCenter.default.addObserver(
            forName: .tiebaVoicePlaybackWillStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.pause()
                _ = self.audioSessionLifecycle.relinquishForExternalPlayback()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.pause()
                self.audioSessionLifecycle.deactivate()
            }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let rawReason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                    as? NSNumber)?.uintValue,
                    let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                    VideoAudioSessionPlaybackPolicy.shouldPauseForRouteChange(reason) else {
                    return
                }
                guard let self else { return }
                self.player.pause()
                self.audioSessionLifecycle.deactivate()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                    as? NSNumber)?.uintValue,
                    AVAudioSession.InterruptionType(rawValue: rawType) == .began else {
                    return
                }
                guard let self else { return }
                self.player.pause()
                self.audioSessionLifecycle.deactivate()
            }
        }
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        guard didReleasePlayer == false else { return }
        if VideoAudioSessionPlaybackPolicy.requiresActiveSession(for: status) {
            _ = activateAudioSessionIfNeeded()
        }
    }

    private func handlePlayerItemStatus(_ status: AVPlayerItem.Status) {
        guard didReleasePlayer == false else { return }
        switch status {
        case .readyToPlay:
            failureView.isHidden = true
            if playerController.isReadyForDisplay {
                receiveFirstFrameReady()
            }
        case .failed:
            showPlaybackFailure()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func showPlaybackFailure(message: String? = nil) {
        guard didReleasePlayer == false else { return }
        player.pause()
        audioSessionLifecycle.deactivate()
        isPreparingVideo = false
        hasPlaybackFailure = true
        updateLoadingIndicator()
        if let message {
            failureLabel.text = message
        }
        failureView.isHidden = false
    }

    private func receiveFirstFrameReady() {
        guard didReleasePlayer == false else { return }
        firstFrameReady = true
        isPreparingVideo = false
        hasPlaybackFailure = false
        updateLoadingIndicator()
        failureView.isHidden = true
        updatePosterVisibility(animated: didFinishPresentation)
    }

    private func updatePlaybackState() {
        guard VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: didFinishPresentation,
            dismissalStarted: dismissalLifecycle.dismissalStarted,
            applicationIsActive: UIApplication.shared.applicationState == .active
        ), didReleasePlayer == false,
           player.currentItem != nil else {
            player.pause()
            audioSessionLifecycle.deactivate()
            return
        }
        guard activateAudioSessionIfNeeded() else { return }
        player.play()
    }

    @discardableResult
    private func activateAudioSessionIfNeeded() -> Bool {
        guard didReleasePlayer == false,
              dismissalLifecycle.dismissalStarted == false,
              UIApplication.shared.applicationState == .active,
              player.currentItem != nil else {
            player.pause()
            audioSessionLifecycle.deactivate()
            return false
        }
        guard audioSessionLifecycle.hasActiveLease == false else { return true }
        guard VoicePlaybackCoordinator.shared.handleVideoPlaybackWillStart() else {
            showPlaybackFailure(message: "无法切换视频声音\n请稍后重试")
            return false
        }
        do {
            try audioSessionLifecycle.activate()
            return true
        } catch {
            showPlaybackFailure(message: "无法启用视频声音\n请稍后重试")
            return false
        }
    }

    private func updatePosterVisibility(animated: Bool) {
        let keepsPoster = VideoPreviewPlaybackPolicy.keepsPosterVisible(
            firstFrameReady: firstFrameReady,
            dismissalStarted: dismissalLifecycle.dismissalStarted
        )
        let targetAlpha: CGFloat = keepsPoster && posterView.image != nil ? 1 : 0
        guard posterView.alpha != targetAlpha else { return }

        posterAnimator?.stopAnimation(true)
        guard animated, UIAccessibility.isReduceMotionEnabled == false else {
            posterView.alpha = targetAlpha
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.16, curve: .easeInOut) {
            self.posterView.alpha = targetAlpha
        }
        posterAnimator = animator
        animator.startAnimation()
    }

    private func updateLoadingIndicator() {
        if VideoPreviewLoadingIndicatorPolicy.shouldAnimate(
            isPreparing: isPreparingVideo,
            firstFrameReady: firstFrameReady,
            hasFailure: hasPlaybackFailure,
            dismissalStarted: dismissalLifecycle.dismissalStarted
        ) {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
    }

    private func prepareForDismissal() {
        gestureRestoreAnimator?.stopAnimation(true)
        gestureRestoreAnimator = nil
        posterAnimator?.stopAnimation(true)
        posterAnimator = nil
        isPreparingVideo = false
        updateLoadingIndicator()
        cancelVideoPreparation(removePreparedFile: true, clearsPlayerItem: false)
        player.pause()
        audioSessionLifecycle.deactivate()
        playerController.showsPlaybackControls = false
        updatePosterVisibility(animated: false)
    }

    private func finishDetachedDismissalIfNeeded() {
        guard VideoPreviewDetachmentPolicy.shouldFinishDismissal(
            hasPresentingController: presentingViewController != nil,
            isInWindow: viewIfLoaded?.window != nil
        ) else {
            return
        }
        beginDismissalIfNeeded()
        finishDismissalIfNeeded()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPanGestureRecognizer,
              didFinishPresentation,
              dismissalLifecycle.phase == .active,
              didReleasePlayer == false else {
            return false
        }
        activeDismissAxis = VideoPreviewDismissGesturePolicy.axis(
            velocity: dismissPanGestureRecognizer.velocity(in: view)
        )
        return activeDismissAxis != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === dismissPanGestureRecognizer else { return true }
        return VideoPreviewGestureTouchPolicy.allowsDismissGesture(startingAt: touch.view)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === dismissPanGestureRecognizer
            || otherGestureRecognizer === dismissPanGestureRecognizer
    }

    @objc
    private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        guard let axis = activeDismissAxis else { return }
        let translation = VideoPreviewDismissGesturePolicy.adjustedTranslation(
            recognizer.translation(in: view),
            for: axis
        )
        switch recognizer.state {
        case .began:
            gestureRestoreAnimator?.stopAnimation(true)
            gestureRestoreAnimator = nil
            playerController.showsPlaybackControls = false
        case .changed:
            playerController.view.transform = CGAffineTransform(
                translationX: translation.x,
                y: translation.y
            )
            let opacity = VideoPreviewDismissGesturePolicy.backgroundOpacity(
                translation: translation,
                viewportSize: view.bounds.size
            )
            view.backgroundColor = UIColor.black.withAlphaComponent(opacity)
        case .ended:
            let shouldDismiss = VideoPreviewDismissGesturePolicy.shouldDismiss(
                translation: translation,
                velocity: recognizer.velocity(in: view),
                axis: axis,
                viewportSize: view.bounds.size
            )
            activeDismissAxis = nil
            if shouldDismiss, requestDismissal() {
                return
            }
            restoreVideoAfterCancelledDismissal(animated: true)
        case .cancelled, .failed:
            activeDismissAxis = nil
            restoreVideoAfterCancelledDismissal(animated: true)
        default:
            break
        }
    }

    private func restoreVideoAfterCancelledDismissal(animated: Bool) {
        gestureRestoreAnimator?.stopAnimation(true)
        gestureRestoreAnimator = nil
        let changes = {
            self.playerController.view.transform = .identity
            self.view.backgroundColor = .black
        }
        guard animated, UIAccessibility.isReduceMotionEnabled == false else {
            changes()
            playerController.showsPlaybackControls = true
            return
        }
        let animator = UIViewPropertyAnimator(
            duration: 0.28,
            dampingRatio: 0.84,
            animations: changes
        )
        gestureRestoreAnimator = animator
        animator.addCompletion { [weak self] _ in
            self?.playerController.showsPlaybackControls = true
            self?.gestureRestoreAnimator = nil
        }
        animator.startAnimation()
    }

    private func releasePlayer() {
        guard didReleasePlayer == false else { return }
        didReleasePlayer = true
        gestureRestoreAnimator?.stopAnimation(true)
        gestureRestoreAnimator = nil
        posterAnimator?.stopAnimation(true)
        posterAnimator = nil
        isPreparingVideo = false
        updateLoadingIndicator()
        cancelVideoPreparation(removePreparedFile: true, clearsPlayerItem: false)
        readyObservation?.invalidate()
        readyObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }
        if let voicePlaybackObserver {
            NotificationCenter.default.removeObserver(voicePlaybackObserver)
            self.voicePlaybackObserver = nil
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        player.pause()
        audioSessionLifecycle.deactivate()
        player.replaceCurrentItem(with: nil)
        playerController.player = nil
    }

    private func cancelVideoPreparation(
        removePreparedFile: Bool,
        clearsPlayerItem: Bool
    ) {
        videoPreparationTask?.cancel()
        videoPreparationTask = nil
        videoPreparationID = nil
        if clearsPlayerItem {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        if removePreparedFile {
            videoFileLease?.release()
            videoFileLease = nil
        }
    }
}
