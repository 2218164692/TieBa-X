import Combine
import Foundation

struct UserFollowChange: Equatable, Sendable {
    var accountID: String
    var user: UserSummary
    var isFollowed: Bool
}

struct ForumFollowChange: Equatable, Sendable {
    var accountID: String
    var forum: Forum
    var isFollowed: Bool
}

struct UserMutationActivityChange: Equatable, Sendable {
    var accountID: String
    var user: UserSummary
    var isPending: Bool
}

struct ForumMutationActivityChange: Equatable, Sendable {
    var accountID: String
    var forum: Forum
    var isPending: Bool
}

@MainActor
final class SocialRelationshipState {
    let userFollowDidChange = PassthroughSubject<UserFollowChange, Never>()
    let forumFollowDidChange = PassthroughSubject<ForumFollowChange, Never>()
    let userMutationActivityDidChange = PassthroughSubject<UserMutationActivityChange, Never>()
    let forumMutationActivityDidChange = PassthroughSubject<ForumMutationActivityChange, Never>()

    private var userStates: [String: [String: Bool]] = [:]
    private var forumStates: [String: [String: Bool]] = [:]
    private var userOverrides: [String: [String: UserFollowChange]] = [:]
    private var forumOverrides: [String: [String: ForumFollowChange]] = [:]
    private var pendingUsers: [String: Set<String>] = [:]
    private var pendingForums: [String: Set<String>] = [:]

    func userFollowState(accountID: String, user: UserSummary) -> Bool? {
        guard let states = userStates[accountID] else { return nil }
        return Self.userKeys(user).lazy.compactMap { states[$0] }.first
    }

    func forumFollowState(accountID: String, forum: Forum) -> Bool? {
        guard let states = forumStates[accountID] else { return nil }
        return Self.forumKeys(forum).lazy.compactMap { states[$0] }.first
    }

    func userFollowOverride(accountID: String, user: UserSummary) -> Bool? {
        guard let overrides = userOverrides[accountID] else { return nil }
        return Self.userKeys(user).lazy.compactMap { overrides[$0]?.isFollowed }.first
    }

    func forumFollowOverride(accountID: String, forum: Forum) -> Bool? {
        guard let overrides = forumOverrides[accountID] else { return nil }
        return Self.forumKeys(forum).lazy.compactMap { overrides[$0]?.isFollowed }.first
    }

    func seedUserFollow(accountID: String, user: UserSummary, isFollowed: Bool) {
        guard userFollowOverride(accountID: accountID, user: user) == nil else { return }
        writeUserState(accountID: accountID, user: user, isFollowed: isFollowed)
    }

    func seedForumFollow(accountID: String, forum: Forum, isFollowed: Bool) {
        guard forumFollowOverride(accountID: accountID, forum: forum) == nil else { return }
        writeForumState(accountID: accountID, forum: forum, isFollowed: isFollowed)
    }

    func recordUserFollow(accountID: String, user: UserSummary, isFollowed: Bool) {
        let previous = userFollowState(accountID: accountID, user: user)
        let change = UserFollowChange(accountID: accountID, user: user, isFollowed: isFollowed)
        writeUserState(accountID: accountID, user: user, isFollowed: isFollowed)
        for key in Self.userKeys(user) {
            userOverrides[accountID, default: [:]][key] = change
        }
        guard previous != isFollowed else { return }
        userFollowDidChange.send(change)
    }

    func recordForumFollow(accountID: String, forum: Forum, isFollowed: Bool) {
        let previous = forumFollowState(accountID: accountID, forum: forum)
        let change = ForumFollowChange(accountID: accountID, forum: forum, isFollowed: isFollowed)
        writeForumState(accountID: accountID, forum: forum, isFollowed: isFollowed)
        for key in Self.forumKeys(forum) {
            forumOverrides[accountID, default: [:]][key] = change
        }
        guard previous != isFollowed else { return }
        forumFollowDidChange.send(change)
    }

    func seedFollowedForums(accountID: String, forums: [Forum]) {
        for forum in forums {
            seedForumFollow(accountID: accountID, forum: forum, isFollowed: true)
        }
    }

    func reconciledFollowedForums(accountID: String, loaded: [Forum]) -> [Forum] {
        var result = loaded
        for change in uniqueForumOverrides(accountID: accountID) {
            if change.isFollowed {
                if let index = result.firstIndex(where: { Self.sameForum($0, change.forum) }) {
                    result[index] = change.forum
                } else {
                    result.insert(change.forum, at: 0)
                }
            } else {
                result.removeAll { Self.sameForum($0, change.forum) }
            }
        }
        return deduplicatedForums(result)
    }

    func reconciledFollowingUsers(accountID: String, loaded: [UserSummary]) -> [UserSummary] {
        var result = loaded
        for change in uniqueUserOverrides(accountID: accountID) {
            if change.isFollowed {
                if let index = result.firstIndex(where: { Self.sameUser($0, change.user) }) {
                    result[index] = change.user
                } else {
                    result.insert(change.user, at: 0)
                }
            } else {
                result.removeAll { Self.sameUser($0, change.user) }
            }
        }
        return deduplicatedUsers(result)
    }

    func reconciledFollowers(
        accountID: String,
        viewedUser: UserSummary,
        currentUser: UserSummary?,
        loaded: [UserSummary]
    ) -> [UserSummary] {
        guard let currentUser,
              let followed = userFollowOverride(accountID: accountID, user: viewedUser) else {
            return deduplicatedUsers(loaded)
        }
        var result = loaded
        if followed {
            if let index = result.firstIndex(where: { Self.sameUser($0, currentUser) }) {
                result[index] = currentUser
            } else {
                result.insert(currentUser, at: 0)
            }
        } else {
            result.removeAll { Self.sameUser($0, currentUser) }
        }
        return deduplicatedUsers(result)
    }

    func isUserMutationPending(accountID: String, user: UserSummary) -> Bool {
        pendingUsers[accountID]?.contains(Self.userOperationKey(user)) == true
    }

    func isForumMutationPending(accountID: String, forum: Forum) -> Bool {
        pendingForums[accountID]?.contains(Self.forumOperationKey(forum)) == true
    }

    func beginUserMutation(accountID: String, user: UserSummary) {
        let key = Self.userOperationKey(user)
        guard pendingUsers[accountID, default: []].insert(key).inserted else { return }
        userMutationActivityDidChange.send(UserMutationActivityChange(
            accountID: accountID,
            user: user,
            isPending: true
        ))
    }

    func endUserMutation(accountID: String, user: UserSummary) {
        let key = Self.userOperationKey(user)
        guard pendingUsers[accountID]?.remove(key) != nil else { return }
        userMutationActivityDidChange.send(UserMutationActivityChange(
            accountID: accountID,
            user: user,
            isPending: false
        ))
    }

    func beginForumMutation(accountID: String, forum: Forum) {
        let key = Self.forumOperationKey(forum)
        guard pendingForums[accountID, default: []].insert(key).inserted else { return }
        forumMutationActivityDidChange.send(ForumMutationActivityChange(
            accountID: accountID,
            forum: forum,
            isPending: true
        ))
    }

    func endForumMutation(accountID: String, forum: Forum) {
        let key = Self.forumOperationKey(forum)
        guard pendingForums[accountID]?.remove(key) != nil else { return }
        forumMutationActivityDidChange.send(ForumMutationActivityChange(
            accountID: accountID,
            forum: forum,
            isPending: false
        ))
    }

    func reset(accountID: String) {
        userStates.removeValue(forKey: accountID)
        forumStates.removeValue(forKey: accountID)
        userOverrides.removeValue(forKey: accountID)
        forumOverrides.removeValue(forKey: accountID)
        pendingUsers.removeValue(forKey: accountID)
        pendingForums.removeValue(forKey: accountID)
    }

    static func sameUser(_ lhs: UserSummary, _ rhs: UserSummary) -> Bool {
        if lhs.id > 0, rhs.id > 0 { return lhs.id == rhs.id }
        let lhsPortrait = normalized(lhs.portrait)
        let rhsPortrait = normalized(rhs.portrait)
        if lhsPortrait.isEmpty == false, rhsPortrait.isEmpty == false {
            return lhsPortrait == rhsPortrait
        }
        guard lhs.id <= 0, rhs.id <= 0,
              lhsPortrait.isEmpty, rhsPortrait.isEmpty else { return false }
        return fallbackUserNameKey(lhs) == fallbackUserNameKey(rhs)
    }

    static func sameForum(_ lhs: Forum, _ rhs: Forum) -> Bool {
        if lhs.id > 0, rhs.id > 0 { return lhs.id == rhs.id }
        let lhsName = normalized(lhs.name)
        let rhsName = normalized(rhs.name)
        return lhsName.isEmpty == false && lhsName == rhsName
    }

    static func userOperationKey(_ user: UserSummary) -> String {
        userKeys(user).first ?? "unknown-user"
    }

    static func forumOperationKey(_ forum: Forum) -> String {
        forumKeys(forum).first ?? "unknown-forum"
    }

    private func writeUserState(accountID: String, user: UserSummary, isFollowed: Bool) {
        for key in Self.userKeys(user) {
            userStates[accountID, default: [:]][key] = isFollowed
        }
    }

    private func writeForumState(accountID: String, forum: Forum, isFollowed: Bool) {
        for key in Self.forumKeys(forum) {
            forumStates[accountID, default: [:]][key] = isFollowed
        }
    }

    private func uniqueUserOverrides(accountID: String) -> [UserFollowChange] {
        var seen = Set<String>()
        return (userOverrides[accountID] ?? [:]).values.filter {
            seen.insert(Self.userOperationKey($0.user)).inserted
        }
    }

    private func uniqueForumOverrides(accountID: String) -> [ForumFollowChange] {
        var seen = Set<String>()
        return (forumOverrides[accountID] ?? [:]).values.filter {
            seen.insert(Self.forumOperationKey($0.forum)).inserted
        }
    }

    private func deduplicatedUsers(_ users: [UserSummary]) -> [UserSummary] {
        var result: [UserSummary] = []
        for user in users where result.contains(where: { Self.sameUser($0, user) }) == false {
            result.append(user)
        }
        return result
    }

    private func deduplicatedForums(_ forums: [Forum]) -> [Forum] {
        var result: [Forum] = []
        for forum in forums where result.contains(where: { Self.sameForum($0, forum) }) == false {
            result.append(forum)
        }
        return result
    }

    private static func userKeys(_ user: UserSummary) -> [String] {
        var keys: [String] = []
        if user.id > 0 { keys.append("id:\(user.id)") }
        let portrait = normalized(user.portrait)
        if portrait.isEmpty == false { keys.append("portrait:\(portrait)") }
        if keys.isEmpty {
            let name = fallbackUserNameKey(user)
            if name.isEmpty == false { keys.append("name:\(name)") }
        }
        return keys.isEmpty ? ["unknown-user"] : keys
    }

    private static func forumKeys(_ forum: Forum) -> [String] {
        var keys: [String] = []
        if forum.id > 0 { keys.append("id:\(forum.id)") }
        let name = normalized(forum.name)
        if name.isEmpty == false { keys.append("name:\(name)") }
        return keys.isEmpty ? ["unknown-forum"] : keys
    }

    private static func fallbackUserNameKey(_ user: UserSummary) -> String {
        let name = normalized(user.name)
        let displayName = normalized(user.displayName)
        guard name.isEmpty == false || displayName.isEmpty == false else { return "" }
        return "\(name)|\(displayName)"
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
