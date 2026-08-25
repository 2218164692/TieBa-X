import SwiftUI

struct CompatibleUnavailableView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text?

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        description: Text? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: description
            )
        } else {
            VStack(spacing: TieBaXTheme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(.largeTitle, design: .rounded, weight: .regular))
                    .tieBaForegroundStyle(.secondary)

                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let description {
                    description
                        .font(.subheadline)
                        .tieBaForegroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(TieBaXTheme.Spacing.lg)
        }
    }
}
