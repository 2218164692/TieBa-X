import Foundation
import SwiftUI

@MainActor
final class ContentSubmissionSettingsStore: ObservableObject {
    nonisolated static let liveKey = "com.tiebax.content-submission.replies-enabled"
    nonisolated static let newThreadsLiveKey = "com.tiebax.content-submission.new-threads-enabled"
    nonisolated static let likesLiveKey = "com.tiebax.content-submission.likes-enabled"

    @Published private(set) var repliesEnabled: Bool
    @Published private(set) var newThreadsEnabled: Bool
    @Published private(set) var likesEnabled: Bool

    private let defaults: UserDefaults
    private let repliesKey: String
    private let newThreadsKey: String
    private let likesKey: String

    init(
        defaults: UserDefaults = .standard,
        key: String = ContentSubmissionSettingsStore.liveKey,
        newThreadsKey: String = ContentSubmissionSettingsStore.newThreadsLiveKey,
        likesKey: String = ContentSubmissionSettingsStore.likesLiveKey
    ) {
        self.defaults = defaults
        repliesKey = key
        self.newThreadsKey = newThreadsKey
        self.likesKey = likesKey
        repliesEnabled = defaults.bool(forKey: key)
        newThreadsEnabled = Self.readDefaultOnSetting(defaults: defaults, key: newThreadsKey)
        likesEnabled = Self.readDefaultOnSetting(defaults: defaults, key: likesKey)
    }

    func setRepliesEnabled(_ isEnabled: Bool) {
        guard repliesEnabled != isEnabled else { return }
        if isEnabled {
            defaults.set(true, forKey: repliesKey)
        } else {
            defaults.removeObject(forKey: repliesKey)
        }
        repliesEnabled = isEnabled
    }

    func setNewThreadsEnabled(_ isEnabled: Bool) {
        guard newThreadsEnabled != isEnabled else { return }
        persistDefaultOnSetting(isEnabled, key: newThreadsKey)
        newThreadsEnabled = isEnabled
    }

    func setLikesEnabled(_ isEnabled: Bool) {
        guard likesEnabled != isEnabled else { return }
        persistDefaultOnSetting(isEnabled, key: likesKey)
        likesEnabled = isEnabled
    }

    func reset() {
        defaults.removeObject(forKey: repliesKey)
        defaults.removeObject(forKey: newThreadsKey)
        defaults.removeObject(forKey: likesKey)
        repliesEnabled = false
        newThreadsEnabled = true
        likesEnabled = true
    }

    func allowsSubmission(kind: ContentSubmissionKind) -> Bool {
        switch kind {
        case .newThread:
            return newThreadsEnabled
        case .threadReply, .postReply, .subpostReply:
            return repliesEnabled
        }
    }

    private static func readDefaultOnSetting(defaults: UserDefaults, key: String) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    private func persistDefaultOnSetting(_ isEnabled: Bool, key: String) {
        if isEnabled {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(false, forKey: key)
        }
    }
}
