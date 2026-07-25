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

extension View {
    /// Compatibility shim for call sites that previously installed a custom
    /// full-screen gesture. Navigation is now entirely system-owned: iOS 26
    /// supplies content-area pop while iOS 18–25 supply leading-edge pop.
    func fullScreenInteractiveNavigationPop(isEnabled: Bool = true) -> some View {
        self
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

/// Matches the original compact, grey radial activity indicator used by the
/// project before the labelled capsule refresh treatment was introduced.
struct InlineRefreshActivityIndicator: View {
    let accessibilityIdentifier: String

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .tint(Color(uiColor: .secondaryLabel))
            .frame(width: 44, height: 36)
            .accessibilityLabel("正在刷新")
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
