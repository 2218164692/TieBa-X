import Foundation
import SwiftUI
import UIKit

enum ReaderFontSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:
            return "较小"
        case .standard:
            return "标准"
        case .large:
            return "较大"
        case .extraLarge:
            return "特大"
        }
    }

    var shortTitle: String {
        switch self {
        case .small:
            return "小"
        case .standard:
            return "标准"
        case .large:
            return "大"
        case .extraLarge:
            return "特大"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small:
            return 0.90
        case .standard:
            return 1
        case .large:
            return 1.12
        case .extraLarge:
            return 1.25
        }
    }
}

enum ReaderLineSpacing: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case relaxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "紧凑"
        case .standard:
            return "标准"
        case .relaxed:
            return "宽松"
        }
    }

    fileprivate var multiplier: CGFloat {
        switch self {
        case .compact:
            return 0.75
        case .standard:
            return 1
        case .relaxed:
            return 1.5
        }
    }
}

enum ReaderMediaLoadingPolicy: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case dataSaving
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动加载"
        case .dataSaving:
            return "节省流量"
        case .manual:
            return "手动加载"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "自动加载媒体，失败时尝试备用地址"
        case .dataSaving:
            return "自动加载预览，不额外请求备用原图"
        case .manual:
            return "仅在点击后加载媒体"
        }
    }
}

struct ReadingPreferences: Equatable, Sendable {
    var fontSize: ReaderFontSize
    var lineSpacing: ReaderLineSpacing
    var defaultReplySort: ThreadReplySort
    var mediaLoading: ReaderMediaLoadingPolicy

    static let `default` = ReadingPreferences(
        fontSize: .standard,
        lineSpacing: .standard,
        defaultReplySort: .hot,
        mediaLoading: .automatic
    )
}

enum ReaderTextContext: Equatable, Sendable {
    case body
    case subpost
}

enum ReaderTypographyPolicy {
    static func font(
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        fontSize: ReaderFontSize,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        let referenceTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let referenceFont = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: referenceTraits
        )
        let descriptor = referenceFont.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        let preferredFont = UIFont(
            descriptor: descriptor,
            size: referenceFont.pointSize * fontSize.scale
        )
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: preferredFont,
            compatibleWith: traitCollection
        )
    }

    static func lineSpacing(
        _ preference: ReaderLineSpacing,
        context: ReaderTextContext
    ) -> CGFloat {
        let standardSpacing: CGFloat = context == .subpost ? 2 : 4
        return standardSpacing * preference.multiplier
    }
}

struct ReaderMediaRequestPolicy: Equatable, Sendable {
    let loadsAutomatically: Bool
    let allowsFallback: Bool

    func allowsLoading(
        sourceIdentity: String,
        manualAuthorization: String?
    ) -> Bool {
        loadsAutomatically || manualAuthorization == sourceIdentity
    }

    func allowsFallback(
        sourceIdentity: String,
        explicitAuthorization: String?
    ) -> Bool {
        allowsFallback || explicitAuthorization == sourceIdentity
    }

    static func resolve(_ preference: ReaderMediaLoadingPolicy) -> ReaderMediaRequestPolicy {
        switch preference {
        case .automatic:
            return ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: true)
        case .dataSaving:
            return ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: false)
        case .manual:
            return ReaderMediaRequestPolicy(loadsAutomatically: false, allowsFallback: true)
        }
    }
}

struct ReaderImageRequestSources: Equatable, Sendable {
    let primaryURL: URL?
    let fallbackURL: URL?
}

enum ReaderImageRequestSourcePolicy {
    static func resolve(
        previewURL: URL?,
        originalURL: URL?,
        requestPolicy: ReaderMediaRequestPolicy,
        sourceIdentity: String,
        explicitOriginalAuthorization: String?
    ) -> ReaderImageRequestSources {
        if explicitOriginalAuthorization == sourceIdentity,
           let originalURL {
            return ReaderImageRequestSources(
                primaryURL: originalURL,
                fallbackURL: nil
            )
        }
        return ReaderImageRequestSources(
            primaryURL: previewURL ?? originalURL,
            fallbackURL: requestPolicy.allowsFallback ? originalURL : nil
        )
    }
}

enum ReaderMediaActivationPolicy {
    static func blocksWhileLoading(
        requestPolicy: ReaderMediaRequestPolicy
    ) -> Bool {
        requestPolicy.loadsAutomatically == false
    }
}

enum ThreadInitialReplySortPolicy {
    static func resolve(
        defaultReplySort: ThreadReplySort,
        initialPostID: UInt64?
    ) -> ThreadReplySort {
        // Server-side post-ID paging is deterministic only in floor order.
        // Search results and deep links therefore take precedence over the
        // user's default for newly opened threads.
        initialPostID == nil ? defaultReplySort : .ascending
    }
}

@MainActor
final class ReadingPreferencesStore: ObservableObject {
    struct StorageKeys: Equatable, Sendable {
        var fontSize: String
        var lineSpacing: String
        var defaultReplySort: String
        var mediaLoading: String

        static let live = StorageKeys(
            fontSize: "dev.infinityf4p.tiebapure.reader.font-size",
            lineSpacing: "dev.infinityf4p.tiebapure.reader.line-spacing",
            defaultReplySort: "dev.infinityf4p.tiebapure.reader.default-reply-sort",
            mediaLoading: "dev.infinityf4p.tiebapure.reader.media-loading"
        )
    }

    @Published private(set) var preferences: ReadingPreferences

    private let defaults: UserDefaults
    private let keys: StorageKeys

    init(defaults: UserDefaults = .standard, keys: StorageKeys = .live) {
        self.defaults = defaults
        self.keys = keys

        let fontSize = Self.readStringValue(
            ReaderFontSize.self,
            defaultValue: ReadingPreferences.default.fontSize,
            defaults: defaults,
            key: keys.fontSize
        )
        let lineSpacing = Self.readStringValue(
            ReaderLineSpacing.self,
            defaultValue: ReadingPreferences.default.lineSpacing,
            defaults: defaults,
            key: keys.lineSpacing
        )
        let defaultReplySort = Self.readReplySort(defaults: defaults, key: keys.defaultReplySort)
        let mediaLoading = Self.readStringValue(
            ReaderMediaLoadingPolicy.self,
            defaultValue: ReadingPreferences.default.mediaLoading,
            defaults: defaults,
            key: keys.mediaLoading
        )
        preferences = ReadingPreferences(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            defaultReplySort: defaultReplySort,
            mediaLoading: mediaLoading
        )
    }

    func update(_ preferences: ReadingPreferences) {
        persist(preferences.fontSize, defaultValue: ReadingPreferences.default.fontSize, key: keys.fontSize)
        persist(preferences.lineSpacing, defaultValue: ReadingPreferences.default.lineSpacing, key: keys.lineSpacing)
        persist(preferences.defaultReplySort, defaultValue: ReadingPreferences.default.defaultReplySort, key: keys.defaultReplySort)
        persist(preferences.mediaLoading, defaultValue: ReadingPreferences.default.mediaLoading, key: keys.mediaLoading)
        self.preferences = preferences
    }

    func select(fontSize: ReaderFontSize) {
        guard preferences.fontSize != fontSize else { return }
        var updated = preferences
        updated.fontSize = fontSize
        persist(fontSize, defaultValue: ReadingPreferences.default.fontSize, key: keys.fontSize)
        preferences = updated
    }

    func select(lineSpacing: ReaderLineSpacing) {
        guard preferences.lineSpacing != lineSpacing else { return }
        var updated = preferences
        updated.lineSpacing = lineSpacing
        persist(lineSpacing, defaultValue: ReadingPreferences.default.lineSpacing, key: keys.lineSpacing)
        preferences = updated
    }

    func select(defaultReplySort: ThreadReplySort) {
        guard preferences.defaultReplySort != defaultReplySort else { return }
        var updated = preferences
        updated.defaultReplySort = defaultReplySort
        persist(
            defaultReplySort,
            defaultValue: ReadingPreferences.default.defaultReplySort,
            key: keys.defaultReplySort
        )
        preferences = updated
    }

    func select(mediaLoading: ReaderMediaLoadingPolicy) {
        guard preferences.mediaLoading != mediaLoading else { return }
        var updated = preferences
        updated.mediaLoading = mediaLoading
        persist(
            mediaLoading,
            defaultValue: ReadingPreferences.default.mediaLoading,
            key: keys.mediaLoading
        )
        preferences = updated
    }

    func reset() {
        defaults.removeObject(forKey: keys.fontSize)
        defaults.removeObject(forKey: keys.lineSpacing)
        defaults.removeObject(forKey: keys.defaultReplySort)
        defaults.removeObject(forKey: keys.mediaLoading)
        preferences = .default
    }

    static func live() -> ReadingPreferencesStore {
        let store = ReadingPreferencesStore()

#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_RESET_READING_PREFERENCES") {
            store.reset()
        }
        if arguments.contains("UITEST_READING_REPLY_SORT_DESCENDING") {
            store.select(defaultReplySort: .descending)
        }
        if arguments.contains("UITEST_READING_MEDIA_MANUAL") {
            store.select(mediaLoading: .manual)
        } else if arguments.contains("UITEST_READING_MEDIA_DATA_SAVING") {
            store.select(mediaLoading: .dataSaving)
        }
#endif

        return store
    }

    private static func readStringValue<Value: RawRepresentable>(
        _ type: Value.Type,
        defaultValue: Value,
        defaults: UserDefaults,
        key: String
    ) -> Value where Value.RawValue == String {
        guard let storedObject = defaults.object(forKey: key) else { return defaultValue }
        guard let rawValue = storedObject as? String,
              let value = Value(rawValue: rawValue) else {
            defaults.removeObject(forKey: key)
            return defaultValue
        }
        return value
    }

    private static func readReplySort(defaults: UserDefaults, key: String) -> ThreadReplySort {
        guard let storedObject = defaults.object(forKey: key) else {
            return ReadingPreferences.default.defaultReplySort
        }
        guard let number = storedObject as? NSNumber,
              let value = ThreadReplySort(rawValue: number.intValue) else {
            defaults.removeObject(forKey: key)
            return ReadingPreferences.default.defaultReplySort
        }
        return value
    }

    private func persist<Value: RawRepresentable & Equatable>(
        _ value: Value,
        defaultValue: Value,
        key: String
    ) where Value.RawValue == String {
        if value == defaultValue {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value.rawValue, forKey: key)
        }
    }

    private func persist(
        _ value: ThreadReplySort,
        defaultValue: ThreadReplySort,
        key: String
    ) {
        if value == defaultValue {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value.rawValue, forKey: key)
        }
    }
}

private struct ReadingPreferencesEnvironmentKey: EnvironmentKey {
    static let defaultValue = ReadingPreferences.default
}

extension EnvironmentValues {
    var readingPreferences: ReadingPreferences {
        get { self[ReadingPreferencesEnvironmentKey.self] }
        set { self[ReadingPreferencesEnvironmentKey.self] = newValue }
    }
}
