import SwiftUI

struct CapsuleLabel: View {
    let text: String
    let systemImage: String?
    let isSelected: Bool

    init(_ text: String, systemImage: String? = nil, isSelected: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(spacing: TieBaXTheme.Spacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .tieBaForegroundStyle(isSelected ? Color.white : TieBaXTheme.ColorToken.primaryAccent)
        .padding(.horizontal, TieBaXTheme.Spacing.xs)
        .padding(.vertical, TieBaXTheme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: TieBaXTheme.Radius.chip, style: .continuous)
                .fill(isSelected ? TieBaXTheme.ColorToken.primaryAccent : TieBaXTheme.ColorToken.readerSecondarySurface)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
