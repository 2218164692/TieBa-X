import Foundation
import SwiftUI

@MainActor
final class ContentSubmissionSettingsStore: ObservableObject {
    nonisolated static let liveKey = "dev.infinityf4p.tiebapure.content-submission.replies-enabled"

    @Published private(set) var repliesEnabled: Bool

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = ContentSubmissionSettingsStore.liveKey
    ) {
        self.defaults = defaults
        self.key = key
        repliesEnabled = defaults.bool(forKey: key)
    }

    func setRepliesEnabled(_ isEnabled: Bool) {
        guard repliesEnabled != isEnabled else { return }
        if isEnabled {
            defaults.set(true, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        repliesEnabled = isEnabled
    }

    func reset() {
        defaults.removeObject(forKey: key)
        repliesEnabled = false
    }

    func allowsSubmission(kind: ContentSubmissionKind) -> Bool {
        switch kind {
        case .newThread:
            return true
        case .threadReply, .postReply, .subpostReply:
            return repliesEnabled
        }
    }
}
