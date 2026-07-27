import Foundation

enum TiebaForumName {
    static func normalized(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("吧") {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized.lowercased()
    }
}

// Feed and thread mapping consult the blocklist from async request code, so
// the active rules are a Sendable value swapped behind a lock instead of a
// read of the main-actor BlocklistStore. Keywords and forum names must be
// stored in canonical form, user names folded via TiebaUserName.normalized;
// BlocklistSnapshot(entries:) produces that shape.
struct BlocklistSnapshot: Equatable, Sendable {
    var keywords: Set<String>
    var userIDs: Set<Int64>
    var userNames: Set<String>
    var forumNames: Set<String>

    init(
        keywords: Set<String> = [],
        userIDs: Set<Int64> = [],
        userNames: Set<String> = [],
        forumNames: Set<String> = []
    ) {
        self.keywords = keywords
        self.userIDs = userIDs
        self.userNames = userNames
        self.forumNames = Set(
            forumNames
                .map(TiebaForumName.normalized)
                .filter { $0.isEmpty == false }
        )
    }

    var isEmpty: Bool {
        keywords.isEmpty && userIDs.isEmpty && userNames.isEmpty && forumNames.isEmpty
    }

    func containsKeyword(in text: String) -> Bool {
        guard keywords.isEmpty == false, text.isEmpty == false else { return false }
        let lowercased = text.lowercased()
        return keywords.contains { lowercased.contains($0) }
    }

    func blocksUser(id: Int64, names: [String]) -> Bool {
        if id > 0, userIDs.contains(id) { return true }
        guard userNames.isEmpty == false else { return false }
        return names.contains { name in
            guard name.isEmpty == false else { return false }
            return userNames.contains(TiebaUserName.normalized(name))
        }
    }

    func blocksForum(named name: String) -> Bool {
        guard forumNames.isEmpty == false else { return false }
        let normalized = TiebaForumName.normalized(name)
        guard normalized.isEmpty == false else { return false }
        return forumNames.contains(normalized)
    }
}

enum TiebaContentFilter {
    // Reads happen off the main actor during mapping; the store publishes on
    // the main actor. The lock keeps both sides safe, and the first read
    // hydrates from persisted entries so muting applies before any UI has
    // touched BlocklistStore.
    private static let blocklistLock = NSLock()
    private static var storedBlocklist: BlocklistSnapshot?

    static func updateBlocklist(_ snapshot: BlocklistSnapshot) {
        blocklistLock.lock()
        defer { blocklistLock.unlock() }
        storedBlocklist = snapshot
    }

    static var blocklist: BlocklistSnapshot {
        blocklistLock.lock()
        defer { blocklistLock.unlock() }
        if let storedBlocklist { return storedBlocklist }
        let hydrated = BlocklistSnapshot(entries: BlocklistPersistence.loadEntries())
        storedBlocklist = hydrated
        return hydrated
    }

    /// Server-page structural filtering. This intentionally excludes the
    /// user-managed blocklist so callers can retain the original page
    /// cardinality when deciding whether another page exists.
    static func shouldMap(thread: Tieba_ThreadInfo) -> Bool {
        if thread.hasAlaInfo { return false }
        if thread.hasTwzhiboInfo { return false }
        if thread.isDeleted != 0 { return false }
        return true
    }

    static func shouldKeep(thread: Tieba_ThreadInfo) -> Bool {
        guard shouldMap(thread: thread) else { return false }
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: thread.author.id > 0 ? thread.author.id : thread.authorID,
            names: [thread.author.nameShow, thread.author.name]
        ) { return false }
        if blocklist.blocksForum(named: thread.forumName) { return false }
        if blocklist.containsKeyword(in: thread.title) { return false }
        if thread.abstract.contains(where: { blocklist.containsKeyword(in: $0.text) }) {
            return false
        }
        return true
    }

    static func shouldKeep(thread: ThreadSummary) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: thread.author.id,
            names: [thread.author.displayName, thread.author.name]
        ) { return false }
        if let forumName = thread.forumName,
           blocklist.blocksForum(named: forumName) {
            return false
        }
        if blocklist.containsKeyword(in: thread.title) { return false }
        return blocklist.containsKeyword(in: thread.textPreview) == false
    }

    static func shouldKeep(searchResult: SearchResult) -> Bool {
        shouldKeep(thread: searchResult.threadSummary)
    }

    /// Applies the same local mute rules to reply/@ feeds without changing
    /// their server pagination metadata.
    static func shouldKeep(message: MessageItem) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: message.author.id,
            names: [message.author.displayName, message.author.name]
        ) {
            return false
        }
        if blocklist.containsKeyword(in: message.content)
            || blocklist.containsKeyword(in: message.threadTitle) {
            return false
        }
        if let forumName = message.forumName,
           blocklist.blocksForum(named: forumName) {
            return false
        }
        return true
    }

    static func shouldKeep(user: UserSummary) -> Bool {
        Self.blocklist.blocksUser(
            id: user.id,
            names: [user.displayName, user.name]
        ) == false
    }

    static func shouldKeep(forum: Forum) -> Bool {
        let blocklist = Self.blocklist
        return blocklist.blocksForum(named: forum.name) == false
            && blocklist.blocksForum(named: forum.displayName) == false
    }

    static func shouldKeep(post: Tieba_Post) -> Bool {
        if post.hasAdvertisement { return false }
        if post.isFold != 0 { return false }
        let blocklist = Self.blocklist
        if blocklist.isEmpty == false {
            // Blocklist rejects run before the continuity keep-rules below:
            // a floor kept only for its voice content or 楼中楼 still drops
            // when its author is blocked or its text matches a keyword.
            if blocklist.blocksUser(
                id: post.author.id > 0 ? post.author.id : post.authorID,
                names: [post.author.nameShow, post.author.name]
            ) { return false }
            if post.content.contains(where: { blocklist.containsKeyword(in: $0.text) }) {
                return false
            }
        }
        if post.content.contains(where: shouldKeep(content:)) { return true }
        // A floor whose content is entirely voice still owns its floor number
        // and 楼中楼; dropping it would break floor continuity and take
        // reachable text subposts with it. Ad-only floors and floors with no
        // content and no subposts stay dropped — they have nothing to show.
        return post.content.contains { $0.voiceMd5.isEmpty == false }
            || post.subPostNumber > 0
            || post.subPostList.subPostList.isEmpty == false
    }

    static func shouldKeep(post: Post) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: post.author.id,
            names: [post.author.displayName, post.author.name]
        ) { return false }
        return blocklist.containsKeyword(in: post.contentPreview) == false
    }

    static func shouldKeep(subpost: Tieba_SubPostList) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: subpost.author.id > 0 ? subpost.author.id : subpost.authorID,
            names: [subpost.author.nameShow, subpost.author.name]
        ) { return false }
        return subpost.content.contains { blocklist.containsKeyword(in: $0.text) } == false
    }

    static func shouldKeep(subpost: Subpost) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: subpost.author.id,
            names: [subpost.author.displayName, subpost.author.name]
        ) { return false }
        let text = subpost.blocks.compactMap(\.plainText).joined()
        return blocklist.containsKeyword(in: text) == false
    }

    static func shouldKeep(content: Tieba_PbContent) -> Bool {
        if content.type == 10 { return false }
        if content.voiceMd5.isEmpty == false { return false }
        return true
    }
}
