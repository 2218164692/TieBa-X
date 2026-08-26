import Foundation

/// Normalizes the user-facing forum label without changing the server raw
/// forum name. A raw name may already contain the Chinese suffix (for example
/// "网吧"), so only append it when it is missing.
enum ForumNamePolicy {
    static func displayName(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        return trimmed.hasSuffix("吧") ? trimmed : "\(trimmed)吧"
    }
}

struct Forum: Identifiable, Equatable, Codable, Sendable {
    var id: Int64
    var name: String
    var displayName: String
    var avatarURL: URL?
    var memberCount: Int
    var threadCount: Int
}
