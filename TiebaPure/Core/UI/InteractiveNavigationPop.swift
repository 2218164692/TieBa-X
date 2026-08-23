import SwiftUI
import UIKit

enum NavigationPopGestureControlHostingPolicy {
    static func requiresController(isEnabled: Bool) -> Bool {
        // A normal NavigationStack must keep complete ownership of its native
        // recognizers. Hosting a controller merely to force-enable the edge
        // recognizer raced SwiftUI's push transition on iOS 16-18, especially
        // when two navigation stacks were visible in an iPad split view.
        return isEnabled == false
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
            applyRequestedState()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyRequestedState()
        }

        override func viewWillDisappear(_ animated: Bool) {
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
                updateDiagnostics(using: navigationController)
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
                "visible=\(viewIfLoaded?.window != nil)",
                "attached=\(viewIfLoaded?.window != nil)"
            ].joined(separator: ",")
#endif
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
