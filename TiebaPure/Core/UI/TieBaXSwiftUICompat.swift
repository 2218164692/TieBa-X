import SwiftUI
import UIKit

enum TieBaButtonStyleKind {
    case bordered
    case borderedProminent
}

enum TieBaControlSizeKind {
    case small
    case regular
    case large
}

/// Keeps the compatibility API free from SwiftUI's iOS 15-only `Visibility`
/// type. Call sites can continue to express the same intent on iOS 14.
enum TieBaDialogTitleVisibility {
    case automatic
    case visible
    case hidden
}

/// iOS 14 equivalent of the later `DynamicTypeSize` value. The app reads the
/// pre-existing size category environment and only maps back to SwiftUI's
/// newer type inside an availability-checked branch.
enum TieBaDynamicTypeSize: Int, CaseIterable, Comparable, Sendable {
    case xSmall
    case small
    case medium
    case large
    case xLarge
    case xxLarge
    case xxxLarge
    case accessibility1
    case accessibility2
    case accessibility3
    case accessibility4
    case accessibility5

    init(_ category: ContentSizeCategory) {
        switch category {
        case .extraSmall: self = .xSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .extraLarge: self = .xLarge
        case .extraExtraLarge: self = .xxLarge
        case .extraExtraExtraLarge: self = .xxxLarge
        case .accessibilityMedium: self = .accessibility1
        case .accessibilityLarge: self = .accessibility2
        case .accessibilityExtraLarge: self = .accessibility3
        case .accessibilityExtraExtraLarge: self = .accessibility4
        case .accessibilityExtraExtraExtraLarge: self = .accessibility5
        @unknown default: self = .large
        }
    }

    var isAccessibilitySize: Bool {
        rawValue >= Self.accessibility1.rawValue
    }

    @available(iOS 15.0, *)
    var nativeValue: DynamicTypeSize {
        switch self {
        case .xSmall: return .xSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .xLarge
        case .xxLarge: return .xxLarge
        case .xxxLarge: return .xxxLarge
        case .accessibility1: return .accessibility1
        case .accessibility2: return .accessibility2
        case .accessibility3: return .accessibility3
        case .accessibility4: return .accessibility4
        case .accessibility5: return .accessibility5
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TieBaViewThatFits<Compact: View, Fallback: View>: View {
    private let axis: Axis.Set
    private let compact: () -> Compact
    private let fallback: () -> Fallback

    init(
        in axis: Axis.Set,
        @ViewBuilder compact: @escaping () -> Compact,
        @ViewBuilder fallback: @escaping () -> Fallback
    ) {
        self.axis = axis
        self.compact = compact
        self.fallback = fallback
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: axis) {
                compact()
                fallback()
            }
        } else {
            // iOS 14 has no measurement-based ViewThatFits. Feature views
            // provide an explicit stacked fallback so both alternatives are
            // never rendered at once on the minimum OS.
            fallback()
        }
    }
}

extension View {
    /// `background(alignment:content:)` was added after the minimum OS.
    /// Keeping the closure-based call behind this wrapper lets feature views
    /// use the same layout on iOS 14 without importing a newer overload.
    @ViewBuilder
    func tieBaBackground<Background: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: @escaping () -> Background
    ) -> some View {
        if #available(iOS 15.0, *) {
            background(alignment: alignment, content: content)
        } else {
            background(content())
        }
    }

    @ViewBuilder
    func tieBaBackground<S: Shape>(_ color: Color, in shape: S) -> some View {
        if #available(iOS 15.0, *) {
            background(color, in: shape)
        } else {
            background(color)
                .clipShape(shape)
        }
    }

    /// iOS 14 has the non-alignment `overlay(_:)` overload only.
    @ViewBuilder
    func tieBaOverlay<Overlay: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: @escaping () -> Overlay
    ) -> some View {
        if #available(iOS 15.0, *) {
            overlay(alignment: alignment, content: content)
        } else {
            overlay(content())
        }
    }

    @ViewBuilder
    func tieBaForegroundStyle(_ style: Color) -> some View {
        if #available(iOS 15.0, *) {
            foregroundStyle(style)
        } else {
            foregroundColor(style)
        }
    }

    @ViewBuilder
    func tieBaForegroundStyle(
        _ primary: Color,
        _ secondary: Color
    ) -> some View {
        if #available(iOS 15.0, *) {
            foregroundStyle(primary, secondary)
        } else {
            foregroundColor(primary)
        }
    }

    @ViewBuilder
    func tieBaControlSize(_ size: TieBaControlSizeKind) -> some View {
        if #available(iOS 15.0, *) {
            switch size {
            case .small:
                controlSize(.small)
            case .regular:
                controlSize(.regular)
            case .large:
                controlSize(.large)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaTask(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> some View {
        if #available(iOS 15.0, *) {
            task(priority: priority, operation: operation)
        } else {
            onAppear {
                Task(priority: priority, operation: operation)
            }
        }
    }

    @ViewBuilder
    func tieBaTask<ID: Equatable>(
        id: ID,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> some View {
        if #available(iOS 15.0, *) {
            task(id: id, priority: priority, operation: operation)
        } else {
            onAppear {
                Task(priority: priority, operation: operation)
            }
        }
    }

    @ViewBuilder
    func tieBaSearchable(
        text: Binding<String>,
        prompt: String? = nil
    ) -> some View {
        if #available(iOS 15.0, *) {
            if let prompt {
                searchable(text: text, prompt: Text(prompt))
            } else {
                searchable(text: text)
            }
        } else {
            VStack(spacing: 0) {
                TieBaInlineSearchField(
                    text: text,
                    prompt: prompt ?? "搜索"
                )
                self
            }
        }
    }

    @ViewBuilder
    func tieBaRefreshable(
        action: @escaping @Sendable () async -> Void
    ) -> some View {
        if #available(iOS 15.0, *) {
            refreshable(action: action)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaSafeAreaInset<Inset: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Inset
    ) -> some View {
        if #available(iOS 15.0, *) {
            safeAreaInset(
                edge: edge,
                alignment: alignment,
                spacing: spacing,
                content: content
            )
        } else {
            tieBaOverlay(alignment: tieBaOverlayAlignment(for: edge)) {
                content()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    func tieBaScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaTextInputAutocapitalizationNever() -> some View {
        if #available(iOS 15.0, *) {
            textInputAutocapitalization(.never)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaAutocorrectionDisabled() -> some View {
        if #available(iOS 15.0, *) {
            autocorrectionDisabled()
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaTextSelectionEnabled() -> some View {
        if #available(iOS 15.0, *) {
            textSelection(.enabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaTextSelectionDisabled() -> some View {
        if #available(iOS 15.0, *) {
            textSelection(.disabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaSymbolPalette() -> some View {
        if #available(iOS 15.0, *) {
            symbolRenderingMode(.palette)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaInteractiveDismissDisabled(_ isDisabled: Bool = true) -> some View {
        if #available(iOS 15.0, *) {
            interactiveDismissDisabled(isDisabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaDynamicTypeSize(_ range: ClosedRange<TieBaDynamicTypeSize>) -> some View {
        if #available(iOS 15.0, *) {
            dynamicTypeSize(range.lowerBound.nativeValue...range.upperBound.nativeValue)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaScrollIndicatorsHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollIndicators(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaScrollBounceAlways() -> some View {
        if #available(iOS 16.0, *) {
            scrollBounceBehavior(.always, axes: .vertical)
        } else {
            self
        }
    }

    /// `confirmationDialog` is a modern presentation API. On iOS 14 the
    /// same action content is rendered in a small sheet; buttons retain their
    /// original closures and roles, so destructive operations remain usable.
    @ViewBuilder
    func tieBaConfirmationDialog<Actions: View, Message: View>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: TieBaDialogTitleVisibility = .automatic,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: @escaping () -> Message
    ) -> some View {
        tieBaConfirmationDialogImpl(
            titleKey,
            isPresented: isPresented,
            titleVisibility: titleVisibility,
            actions: actions,
            message: message
        )
    }

    @ViewBuilder
    func tieBaConfirmationDialog<Actions: View, Message: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        titleVisibility: TieBaDialogTitleVisibility = .automatic,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: @escaping () -> Message
    ) -> some View {
        tieBaConfirmationDialogImpl(
            LocalizedStringKey(verbatim: title),
            isPresented: isPresented,
            titleVisibility: titleVisibility,
            actions: actions,
            message: message
        )
    }

    @ViewBuilder
    private func tieBaConfirmationDialogImpl<Actions: View, Message: View>(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: TieBaDialogTitleVisibility,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: @escaping () -> Message
    ) -> some View {
        if #available(iOS 15.0, *) {
            confirmationDialog(
                title,
                isPresented: isPresented,
                titleVisibility: tieBaNativeDialogTitleVisibility(titleVisibility),
                actions: actions,
                message: message
            )
        } else {
            sheet(isPresented: isPresented) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.headline)
                    message()
                        .font(.subheadline)
                        .tieBaForegroundStyle(.secondary)
                    actions()
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
        }
    }

    @available(iOS 15.0, *)
    private func tieBaNativeDialogTitleVisibility(
        _ visibility: TieBaDialogTitleVisibility
    ) -> Visibility {
        switch visibility {
        case .automatic: return .automatic
        case .visible: return .visible
        case .hidden: return .hidden
        }
    }

    /// Swipe actions are unavailable on iOS 14. The row remains actionable
    /// through its existing navigation/context controls on that OS.
    @ViewBuilder
    func tieBaSwipeActions<Actions: View>(
        edge: HorizontalEdge = .trailing,
        allowsFullSwipe: Bool = true,
        @ViewBuilder content: @escaping () -> Actions
    ) -> some View {
        if #available(iOS 15.0, *) {
            swipeActions(
                edge: edge,
                allowsFullSwipe: allowsFullSwipe,
                content: content
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func tieBaTint(_ color: Color) -> some View {
        if #available(iOS 15.0, *) {
            tint(color)
        } else {
            foregroundColor(color)
        }
    }

    @ViewBuilder
    func tieBaButtonStyle(_ style: TieBaButtonStyleKind) -> some View {
        if #available(iOS 15.0, *) {
            switch style {
            case .bordered:
                buttonStyle(.bordered)
            case .borderedProminent:
                buttonStyle(.borderedProminent)
            }
        } else {
            buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func tieBaListRowSeparatorHidden() -> some View {
        if #available(iOS 15.0, *) {
            listRowSeparator(.hidden)
        } else {
            self
        }
    }

    /// State-scoped animation was added in SwiftUI 3 (iOS 15). The iOS 14
    /// fallback keeps the visual transition with the older view-wide API.
    @ViewBuilder
    func tieBaAnimation<Value: Equatable>(
        _ animation: Animation?,
        value: Value
    ) -> some View {
        if #available(iOS 15.0, *) {
            self.animation(animation, value: value)
        } else {
            self.animation(animation)
        }
    }

    private func tieBaOverlayAlignment(for edge: VerticalEdge) -> Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        default: return .center
        }
    }
}

/// The iOS 14 fallback for screens that otherwise rely on the system search
/// field. It deliberately stays a normal view, so filtering remains available
/// without depending on the unavailable `searchable` modifier.
private struct TieBaInlineSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .frame(minHeight: 36)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier("tieba-inline-search-field")

            if text.isEmpty == false {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// iOS 14 equivalent of `LabeledContent`. The native control is only
/// referenced in the iOS 16 branch; the fallback keeps settings/about forms
/// readable without relying on a newer SwiftUI type.
struct TieBaFormLabeledContent<Content: View>: View {
    private let title: String
    private let content: () -> Content

    init(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent(title) {
                content()
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                content()
            }
        }
    }
}

struct TieBaFormLabeledValue: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent(title, value: value)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                Text(value)
                    .tieBaForegroundStyle(.secondary)
            }
        }
    }
}

/// UIKit's activity controller is available on iOS 14 and keeps sharing a
/// first-class capability without forcing the app to use ShareLink (iOS 16).
struct TieBaShareLink<Label: View>: View {
    let item: URL
    private let label: () -> Label
    @State private var isPresented = false

    init(item: URL, @ViewBuilder label: @escaping () -> Label) {
        self.item = item
        self.label = label
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                ShareLink(item: item, label: label)
            } else {
                Button {
                    isPresented = true
                } label: {
                    label()
                }
                .sheet(isPresented: $isPresented) {
                    TieBaActivityView(items: [item])
                }
            }
        }
    }
}

private struct TieBaActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
