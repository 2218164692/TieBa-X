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
                HStack(spacing: TiebaPureTheme.Spacing.xxs) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: TiebaPureTheme.IconSize.inline))
                            .accessibilityHidden(true)
                    }

                    Text(items.joined(separator: " · "))
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TiebaPureTheme.Spacing.md) {
            if let comments {
                stat(systemImage: "bubble.right", value: comments, label: "评论")
                    .frame(maxWidth: .infinity)
            }
            if let likes {
                stat(systemImage: "hand.thumbsup", value: likes, label: "点赞")
                    .frame(maxWidth: .infinity)
            }
        }
        .font(font)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private func stat(systemImage: String, value: Int, label: String) -> some View {
        HStack(spacing: TiebaPureTheme.Spacing.xxs) {
            Image(systemName: systemImage)
                .font(.system(size: TiebaPureTheme.IconSize.inline))
                .accessibilityHidden(true)
            Text(CompactInteractionCountText.string(for: value))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("\(label)\(value)")
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
        HStack(spacing: TiebaPureTheme.Spacing.xxs) {
            Image(systemName: "hand.thumbsup")
                .font(.system(size: TiebaPureTheme.IconSize.inline, weight: .medium))
                .accessibilityHidden(true)
            Text(CompactInteractionCountText.string(for: count))
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.secondary)
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
