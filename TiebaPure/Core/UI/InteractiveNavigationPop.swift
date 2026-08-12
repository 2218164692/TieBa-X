import SwiftUI
import UIKit

/// Documents the system navigation gesture used by each supported OS family.
///
/// iOS 26 adds `UINavigationController.interactiveContentPopGestureRecognizer`,
/// which recognizes an interactive pop across the navigation controller's
/// content. Earlier systems only provide the leading-edge
/// `interactivePopGestureRecognizer`.
enum NavigationBackGesturePolicy {
    enum Mode: Equatable {
        case content
        case edge
    }

    static func mode(systemMajorVersion: Int) -> Mode {
        systemMajorVersion >= 26 ? .content : .edge
    }

    static var currentMode: Mode {
        mode(systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

enum NativeEdgePopGestureActivationPolicy {
    static func shouldEnable(
        requestedEnabled: Bool,
        mode: NavigationBackGesturePolicy.Mode,
        isVisible: Bool,
        isAttachedToWindow: Bool,
        stackDepth: Int,
        hasActiveTransition: Bool
    ) -> Bool {
        requestedEnabled
            && mode == .edge
            && isVisible
            && isAttachedToWindow
            && stackDepth > 1
            && hasActiveTransition == false
    }
}

enum NavigationPopGestureControlHostingPolicy {
    static func requiresController(systemMajorVersion: Int, isEnabled: Bool) -> Bool {
        isEnabled == false || systemMajorVersion < 26
    }
}

private enum NavigationPopGestureDiagnostics {
    static let identifier = "navigation-pop-gesture-diagnostics"

    static var isEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("UITEST_NAVIGATION_POP_DIAGNOSTICS")
#else
        false
#endif
    }
}

extension View {
    /// Keeps navigation system-owned while allowing a short, explicit critical
    /// section (such as a dispatched destructive write) to suspend both native
    /// pop recognizers. Keep the modifier's outer identity stable while this
    /// flag changes: replacing the view that owns a system sheet interrupts its
    /// presentation transition. The original enabled state is restored
    /// afterwards.
    func fullScreenInteractiveNavigationPop(isEnabled: Bool = true) -> some View {
        let hostsController = NavigationPopGestureControlHostingPolicy.requiresController(
            systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            isEnabled: isEnabled
        )
        let exposesDiagnostics = NavigationPopGestureDiagnostics.isEnabled
        return background {
            if hostsController {
                NativeNavigationPopGestureControl(isEnabled: isEnabled)
                    .frame(
                        width: exposesDiagnostics ? 1 : 0,
                        height: exposesDiagnostics ? 1 : 0
                    )
                    .accessibilityHidden(exposesDiagnostics == false)
            }
        }
    }

    /// No longer captures page screenshots. Retained as a source-compatible
    /// no-op while callers are migrated away from the former snapshot driver.
    func interactiveNavigationPopRevealSource() -> some View {
        self
    }

    /// Native NavigationStack/UINavigationController pops update their route
    /// binding directly, so a second manual route mutation would risk popping
    /// two levels. The action is intentionally ignored.
    func interactiveNavigationPopStateSync(
        _ action: @escaping () -> Void
    ) -> some View {
        self
    }
}

private struct NativeNavigationPopGestureControl: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.setPopGesturesEnabled(isEnabled)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restorePopGesturesIfNeeded()
    }

    @MainActor
    final class Controller: UIViewController {
        private var requestedEnabled = true
        private var isVisible = false
        private var scheduledUpdateGeneration = 0
        private var transitionRetryGeneration: Int?
        private weak var controlledNavigationController: UINavigationController?
        private var previousEdgeGestureState: Bool?
        private var previousContentGestureState: Bool?

        override func viewDidLoad() {
            super.viewDidLoad()
            guard NavigationPopGestureDiagnostics.isEnabled else { return }
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = NavigationPopGestureDiagnostics.identifier
            view.accessibilityLabel = "导航返回手势状态"
            updateDiagnostics(using: nil)
        }

        func setPopGesturesEnabled(_ isEnabled: Bool) {
            requestedEnabled = isEnabled
            scheduledUpdateGeneration &+= 1
            applyRequestedState()
            scheduleRequestedStateUpdateIfNeeded()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            applyRequestedState()
            scheduleRequestedStateUpdateIfNeeded()
        }

        override func viewWillDisappear(_ animated: Bool) {
            isVisible = false
            scheduledUpdateGeneration &+= 1
            transitionRetryGeneration = nil
            restorePopGesturesIfNeeded()
            super.viewWillDisappear(animated)
        }

        func restorePopGesturesIfNeeded() {
            guard let navigationController = controlledNavigationController else { return }
            if let previousEdgeGestureState {
                navigationController.interactivePopGestureRecognizer?.isEnabled = previousEdgeGestureState
            }
            if #available(iOS 26.0, *), let previousContentGestureState {
                navigationController.interactiveContentPopGestureRecognizer?.isEnabled = previousContentGestureState
            }
            controlledNavigationController = nil
            previousEdgeGestureState = nil
            previousContentGestureState = nil
        }

        private func applyRequestedState() {
            guard requestedEnabled == false else {
                restorePopGesturesIfNeeded()
                enableNativeEdgePopIfNeeded()
                return
            }
            guard let navigationController else { return }
            if controlledNavigationController !== navigationController {
                restorePopGesturesIfNeeded()
                controlledNavigationController = navigationController
                previousEdgeGestureState = navigationController
                    .interactivePopGestureRecognizer?.isEnabled
                if #available(iOS 26.0, *) {
                    previousContentGestureState = navigationController
                        .interactiveContentPopGestureRecognizer?.isEnabled
                }
            }
            navigationController.interactivePopGestureRecognizer?.isEnabled = false
            if #available(iOS 26.0, *) {
                navigationController.interactiveContentPopGestureRecognizer?.isEnabled = false
            }
            updateDiagnostics(using: navigationController)
        }

        private func enableNativeEdgePopIfNeeded() {
            guard let navigationController else {
                updateDiagnostics(using: nil)
                return
            }
            guard requestedEnabled,
                  isVisible,
                  viewIfLoaded?.window != nil,
                  NavigationBackGesturePolicy.currentMode == .edge,
                  navigationController.viewControllers.count > 1 else {
                updateDiagnostics(using: navigationController)
                return
            }
            if let transitionCoordinator = navigationController.transitionCoordinator {
                updateDiagnostics(using: navigationController)
                scheduleEdgeActivationAfterTransition(
                    transitionCoordinator,
                    navigationController: navigationController
                )
                return
            }
            guard NativeEdgePopGestureActivationPolicy.shouldEnable(
                requestedEnabled: requestedEnabled,
                mode: NavigationBackGesturePolicy.currentMode,
                isVisible: isVisible,
                isAttachedToWindow: viewIfLoaded?.window != nil,
                stackDepth: navigationController.viewControllers.count,
                hasActiveTransition: false
            ) else {
                return
            }
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
            updateDiagnostics(using: navigationController)
        }

        private func updateDiagnostics(using navigationController: UINavigationController?) {
#if DEBUG
            guard NavigationPopGestureDiagnostics.isEnabled else { return }
            let edgeGesture = navigationController?.interactivePopGestureRecognizer
            let delegateAllowsBegin = edgeGesture.flatMap { gesture in
                gesture.delegate?.gestureRecognizerShouldBegin?(gesture)
            }
            view.accessibilityValue = [
                "enabled=\(edgeGesture?.isEnabled ?? false)",
                "shouldBegin=\(delegateAllowsBegin ?? false)",
                "depth=\(navigationController?.viewControllers.count ?? 0)",
                "visible=\(isVisible)",
                "attached=\(viewIfLoaded?.window != nil)"
            ].joined(separator: ",")
#endif
        }

        private func scheduleEdgeActivationAfterTransition(
            _ transitionCoordinator: UIViewControllerTransitionCoordinator,
            navigationController: UINavigationController
        ) {
            let generation = scheduledUpdateGeneration
            guard transitionRetryGeneration != generation else { return }
            transitionRetryGeneration = generation
            let accepted = transitionCoordinator.animate(alongsideTransition: nil) { [weak self, weak navigationController] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.transitionRetryGeneration == generation {
                        self.transitionRetryGeneration = nil
                    }
                    guard let navigationController,
                          self.requestedEnabled,
                          self.isVisible,
                          self.scheduledUpdateGeneration == generation,
                          self.viewIfLoaded?.window != nil,
                          self.navigationController === navigationController else {
                        return
                    }
                    guard NativeEdgePopGestureActivationPolicy.shouldEnable(
                        requestedEnabled: true,
                        mode: NavigationBackGesturePolicy.currentMode,
                        isVisible: self.isVisible,
                        isAttachedToWindow: self.viewIfLoaded?.window != nil,
                        stackDepth: navigationController.viewControllers.count,
                        hasActiveTransition: navigationController.transitionCoordinator != nil
                    ) else {
                        return
                    }
                    navigationController.interactivePopGestureRecognizer?.isEnabled = true
                    self.updateDiagnostics(using: navigationController)
                }
            }
            if accepted == false {
                transitionRetryGeneration = nil
            }
        }

        private func scheduleRequestedStateUpdateIfNeeded() {
            guard requestedEnabled, isVisible else { return }
            let generation = scheduledUpdateGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.requestedEnabled,
                      self.isVisible,
                      self.scheduledUpdateGeneration == generation,
                      self.viewIfLoaded?.window != nil else {
                    return
                }
                self.applyRequestedState()
            }
        }
    }
}

/// Progress-driven pull-to-refresh indicator. While dragging, a ring fills
/// and rotates with the pull distance and pops to the accent color once the
/// release threshold is reached; while refreshing it becomes a spinner. Both
/// states sit on a floating material disc so the indicator reads as its own
/// layer instead of blending into content.
struct InlineRefreshActivityIndicator: View {
    var progress: CGFloat = 1
    var isRefreshing: Bool = true
    let accessibilityIdentifier: String

    private var clampedProgress: CGFloat { min(max(progress, 0), 1) }
    private var isReadyToRelease: Bool { clampedProgress >= 1 }

    var body: some View {
        ZStack {
            if isRefreshing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(Color(uiColor: .secondaryLabel))
                    .transition(.opacity)
            } else {
                Circle()
                    .trim(from: 0, to: 0.9 * clampedProgress)
                    .stroke(
                        isReadyToRelease
                            ? Color.accentColor
                            : Color(uiColor: .tertiaryLabel),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-90 + Double(clampedProgress) * 240))
                    .opacity(0.35 + 0.65 * clampedProgress)
            }
        }
        .frame(width: 36, height: 36)
        .background(
            Circle()
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.1), radius: 6, y: 2)
        )
        .scaleEffect(isRefreshing ? 1 : 0.6 + 0.4 * clampedProgress)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isReadyToRelease)
        .accessibilityLabel(isRefreshing ? "正在刷新" : "下拉刷新")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// One light tap the moment the pull crosses the release threshold, mirroring
/// the system refresh control's confirmation.
@MainActor
enum PullRefreshHaptics {
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    static func triggerReady() {
        generator.impactOccurred(intensity: 0.8)
    }
}
