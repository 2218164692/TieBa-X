import SwiftUI

enum ReaderDateText {
    static func string(from date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let elapsed = max(now.timeIntervalSince(date), 0)
        if elapsed < 60 {
            return "刚刚"
        }
        if elapsed < 3_600 {
            return "\(Int(elapsed / 60))分钟前"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return formatted(date, pattern: "HH:mm", calendar: calendar)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(formatted(date, pattern: "HH:mm", calendar: calendar))"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return formatted(date, pattern: "MM-dd HH:mm", calendar: calendar)
        }
        return formatted(date, pattern: "yyyy-MM-dd", calendar: calendar)
    }

    static func threadMetadataString(
        from date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let elapsed = max(now.timeIntervalSince(date), 0)
        if elapsed < 3_600 || calendar.isDate(date, inSameDayAs: now) {
            return string(from: date, now: now, calendar: calendar)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(formatted(date, pattern: "HH:mm", calendar: calendar))"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return formatted(date, pattern: "MM-dd", calendar: calendar)
        }
        return formatted(date, pattern: "yyyy-MM-dd", calendar: calendar)
    }

    private static let formatterCacheLock = NSLock()
    private static var formatterCache: [String: DateFormatter] = [:]

    private static func formatted(_ date: Date, pattern: String, calendar: Calendar) -> String {
        // DateFormatter creation is expensive and runs per visible list row.
        // Cached instances are never mutated after insertion, and formatting
        // itself is thread-safe on iOS 7+, so only the cache needs the lock.
        let key = "\(pattern)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        formatterCacheLock.lock()
        let formatter: DateFormatter
        if let cached = formatterCache[key] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "zh_CN")
            created.calendar = calendar
            created.timeZone = calendar.timeZone
            created.dateFormat = pattern
            formatterCache[key] = created
            formatter = created
        }
        formatterCacheLock.unlock()
        return formatter.string(from: date)
    }
}

struct MetadataLine: View {
    let items: [String]
    let systemImage: String?

    init(_ items: [String], systemImage: String? = nil) {
        self.items = items.filter { $0.isEmpty == false }
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if items.isEmpty == false {
                HStack(spacing: TieBaXTheme.Spacing.xxs) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: TieBaXTheme.IconSize.inline))
                            .accessibilityHidden(true)
                    }

                    Text(items.joined(separator: " · "))
                        .font(.caption)
                        .lineLimit(2)
                        .tieBaForegroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct InteractionStatsView: View {
    var comments: Int?
    var likes: Int?
    var font: Font = .subheadline
    var isLiked = false
    var isLikeUpdating = false
    var onCommentsTap: (() -> Void)?
    var onLikesTap: (() -> Void)?
    var commentsAccessibilityIdentifier: String?
    var likesAccessibilityIdentifier: String?

    var body: some View {
        HStack(alignment: .center, spacing: TieBaXTheme.Spacing.md) {
            if let comments {
                stat(
                    systemImage: "bubble.right",
                    value: comments,
                    label: "评论",
                    action: onCommentsTap,
                    isSelected: false,
                    isUpdating: false,
                    accessibilityIdentifier: commentsAccessibilityIdentifier
                )
                    .frame(maxWidth: .infinity)
            }
            if let likes {
                stat(
                    systemImage: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                    value: likes,
                    label: "点赞",
                    action: onLikesTap,
                    isSelected: isLiked,
                    isUpdating: isLikeUpdating,
                    accessibilityIdentifier: likesAccessibilityIdentifier
                )
                    .frame(maxWidth: .infinity)
            }
        }
        .font(font)
        .tieBaForegroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(
            children: onCommentsTap != nil || onLikesTap != nil ? .contain : .combine
        )
    }

    @ViewBuilder
    private func stat(
        systemImage: String,
        value: Int,
        label: String,
        action: (() -> Void)?,
        isSelected: Bool,
        isUpdating: Bool,
        accessibilityIdentifier: String?
    ) -> some View {
        if let action {
            Button(action: action) {
                statLabel(
                    systemImage: systemImage,
                    value: value,
                    isSelected: isSelected
                )
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .accessibilityLabel(label == "点赞" && isSelected ? "取消点赞" : label)
            .accessibilityValue(
                label == "评论" ? "当前\(value)条评论" : "当前\(value)个赞"
            )
            .accessibilityHint(accessibilityHint(label: label, isUpdating: isUpdating))
            .accessibilityIdentifier(accessibilityIdentifier ?? "interaction-\(label)-button")
        } else {
            statLabel(systemImage: systemImage, value: value, isSelected: isSelected)
                .accessibilityLabel("\(label)\(value)")
                .accessibilityIdentifier(accessibilityIdentifier ?? "interaction-\(label)-count")
        }
    }

    private func statLabel(systemImage: String, value: Int, isSelected: Bool) -> some View {
        HStack(spacing: TieBaXTheme.Spacing.xxs) {
            Image(systemName: systemImage)
                .font(.system(size: TieBaXTheme.IconSize.inline))
                .accessibilityHidden(true)
            Text(CompactInteractionCountText.string(for: value))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .tieBaForegroundStyle(isSelected ? TieBaXTheme.ColorToken.primaryAccent : Color.secondary)
    }

    private func accessibilityHint(label: String, isUpdating: Bool) -> String {
        if isUpdating {
            return "正在提交"
        }
        return label == "评论" ? "进入帖子并定位到评论区" : "双击切换点赞状态"
    }
}

enum InteractionStatsLayout {
    enum Item {
        case comments
        case likes
    }

    static func xPosition(for item: Item, in width: CGFloat) -> CGFloat {
        switch item {
        case .comments:
            return width / 3
        case .likes:
            return width * 2 / 3
        }
    }
}

struct CompactLikeCountView: View {
    var count: Int

    var body: some View {
        HStack(spacing: TieBaXTheme.Spacing.xxs) {
            Image(systemName: "hand.thumbsup")
                .font(.system(size: TieBaXTheme.IconSize.inline, weight: .medium))
                .accessibilityHidden(true)
            Text(CompactInteractionCountText.string(for: count))
                .font(.subheadline)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .tieBaForegroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("点赞\(count)")
    }
}

enum CompactInteractionCountText {
    static func string(for rawValue: Int) -> String {
        let value = max(rawValue, 0)
        switch value {
        case 0..<1_000:
            return "\(value)"
        case 1_000..<10_000:
            return oneDecimal(Double(value) / 1_000) + "k"
        default:
            return oneDecimal(Double(value) / 10_000) + "w"
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
