import AVKit
import SafariServices
import UIKit

enum VideoPreviewPlaybackPolicy {
    static func shouldPlay(
        presentationFinished: Bool,
        dismissalStarted: Bool
    ) -> Bool {
        presentationFinished && dismissalStarted == false
    }

    static func keepsPosterVisible(
        firstFrameReady: Bool,
        dismissalStarted: Bool
    ) -> Bool {
        _ = dismissalStarted
        return firstFrameReady == false
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
    MediaPreviewHeroTransitionParticipant {
    let session: VideoPreviewSession

    private let videoURL: URL
    private let player = AVPlayer()
    private let playerController = AVPlayerViewController()
    private let posterView = UIImageView()
    private let failureView = UIView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
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
    private var posterAnimator: UIViewPropertyAnimator?
    private var dismissalInteractionGate: MediaPreviewDismissalInteractionGate?
    private var didCancelPresentation = false
    private var didFinishPresentation = false
    private var didBeginDismissal = false
    private var didFinishDismissal = false
    private var didReleasePlayer = false
    private var firstFrameReady = false

    init(
        session: VideoPreviewSession,
        videoURL: URL,
        onDismissalBegan: @escaping (UUID) -> Void,
        onDismissalFinished: @escaping (UUID) -> Void,
        onPresentationCancelled: @escaping (UUID) -> Void,
        onDismissalCancelled: @escaping (UUID) -> Void
    ) {
        self.session = session
        self.videoURL = videoURL
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

        playerController.player = player
        playerController.showsPlaybackControls = true
        playerController.videoGravity = .resizeAspect
        playerController.view.accessibilityIdentifier = "full-screen-video-player"
        addChild(playerController)
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)

        configureContentOverlay()
        configureCloseButton()
        installPlayerItem()
        observePlayback()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerController.view.frame = view.bounds
        closeButton.frame = CGRect(
            x: view.bounds.maxX - view.safeAreaInsets.right - 60,
            y: view.safeAreaInsets.top + 16,
            width: 44,
            height: 44
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
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
        _ = containerView
        guard firstFrameReady == false,
              let image = session.sourceImage ?? sourceView.image else {
            return nil
        }
        return MediaPreviewHeroDismissalContent(
            image: image,
            frame: ImagePreviewTransitionGeometry.aspectFitFrame(
                imageSize: image.size,
                in: dismissedView.frame
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
        guard didBeginDismissal == false else { return }
        didBeginDismissal = true
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
        guard didFinishDismissal == false else { return }
        didFinishDismissal = true
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
        didBeginDismissal = false
        didFinishDismissal = false
        dismissalInteractionGate?.cancel()
        dismissalInteractionGate = nil
        playerController.showsPlaybackControls = true
        updatePosterVisibility(animated: false)
        updatePlaybackState()
        onDismissalCancelled(session.id)
    }

    @objc
    private func close() {
        guard presentingViewController != nil,
              isBeingDismissed == false else {
            return
        }
        beginDismissalIfNeeded()
        dismiss(animated: ImagePreviewTransitionMotionPolicy.animationsEnabled) { [weak self] in
            self?.finishDismissalIfNeeded()
        }
    }

    @objc
    private func retryPlayback() {
        guard didReleasePlayer == false,
              didBeginDismissal == false else {
            return
        }
        failureView.isHidden = true
        installPlayerItem()
        updatePlaybackState()
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

    private func configureCloseButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "xmark")
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        configuration.cornerStyle = .capsule
        closeButton.configuration = configuration
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭视频"
        view.addSubview(closeButton)
    }

    private func installPlayerItem() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }

        let item = AVPlayerItem(url: videoURL)
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
        ) { _, change in
            guard change.newValue == .playing else { return }
            DispatchQueue.main.async {
                VoicePlaybackCoordinator.shared.handleVideoPlaybackWillStart()
            }
        }
        voicePlaybackObserver = NotificationCenter.default.addObserver(
            forName: .tiebaVoicePlaybackWillStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player.pause()
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player.pause()
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

    private func showPlaybackFailure() {
        guard didReleasePlayer == false else { return }
        player.pause()
        failureView.isHidden = false
    }

    private func receiveFirstFrameReady() {
        guard didReleasePlayer == false else { return }
        firstFrameReady = true
        failureView.isHidden = true
        updatePosterVisibility(animated: didFinishPresentation)
    }

    private func updatePlaybackState() {
        guard VideoPreviewPlaybackPolicy.shouldPlay(
            presentationFinished: didFinishPresentation,
            dismissalStarted: didBeginDismissal
        ), didReleasePlayer == false else {
            player.pause()
            return
        }
        VoicePlaybackCoordinator.shared.handleVideoPlaybackWillStart()
        player.play()
    }

    private func updatePosterVisibility(animated: Bool) {
        let keepsPoster = VideoPreviewPlaybackPolicy.keepsPosterVisible(
            firstFrameReady: firstFrameReady,
            dismissalStarted: didBeginDismissal
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

    private func prepareForDismissal() {
        posterAnimator?.stopAnimation(true)
        posterAnimator = nil
        player.pause()
        playerController.showsPlaybackControls = false
        updatePosterVisibility(animated: false)
    }

    private func releasePlayer() {
        guard didReleasePlayer == false else { return }
        didReleasePlayer = true
        posterAnimator?.stopAnimation(true)
        posterAnimator = nil
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerController.player = nil
    }
}
