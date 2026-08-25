import SwiftUI

struct ReaderCard<Content: View>: View {
    private let showsDivider: Bool
    private let cornerRadius: CGFloat
    private let contentTopPadding: CGFloat
    private let contentBottomPadding: CGFloat
    private let action: (() -> Void)?
    private let content: Content

    init(
        showsDivider: Bool = true,
        cornerRadius: CGFloat = 0,
        contentTopPadding: CGFloat = TieBaXTheme.Spacing.sm,
        contentBottomPadding: CGFloat = TieBaXTheme.Spacing.sm,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.showsDivider = showsDivider
        self.cornerRadius = cornerRadius
        self.contentTopPadding = contentTopPadding
        self.contentBottomPadding = contentBottomPadding
        self.action = action
        self.content = content()
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TieBaXTheme.Spacing.md)
                .padding(.top, contentTopPadding)
                .padding(.bottom, contentBottomPadding)
                .contentShape(Rectangle())

            if showsDivider {
                Divider()
                    .padding(.leading, TieBaXTheme.Spacing.md)
            }
        }
        .tieBaBackground(
            Color(uiColor: .systemBackground),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
