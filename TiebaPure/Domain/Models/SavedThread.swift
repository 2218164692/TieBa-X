import Foundation

struct SavedThreadPost: Identifiable, Equatable, Codable, Sendable {
    var post: Post
    var subposts: [Subpost]

    var id: UInt64 { post.id }

    var displayPost: Post {
        var value = post
        value.subpostCount = subposts.count
        value.previewSubposts = Array(subposts.prefix(3))
        return value
    }
}

struct SavedThreadSnapshot: Identifiable, Equatable, Codable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var thread: ThreadSummary
    var forum: Forum
    var posts: [SavedThreadPost]
    var savedAt: Date

    var id: Int64 { thread.id }
    var mainPost: SavedThreadPost? { posts.first { $0.post.floor == 1 } }
    var replyCount: Int { posts.reduce(0) { $0 + ($1.post.floor == 1 ? 0 : 1) } }
    var subpostCount: Int { posts.reduce(0) { $0 + $1.subposts.count } }

    func validated() throws -> SavedThreadSnapshot {
        guard formatVersion == Self.currentFormatVersion else {
            throw SavedThreadError.unsupportedFormat
        }
        guard thread.id > 0,
              forum.id > 0,
              let mainPost,
              mainPost.post.id > 0,
              mainPost.post.threadID == thread.id,
              posts.allSatisfy({ $0.post.id > 0 && $0.post.threadID == thread.id }) else {
            throw SavedThreadError.incompleteThread
        }
        let postIDs = posts.map(\.post.id)
        guard Set(postIDs).count == postIDs.count else {
            throw SavedThreadError.inconsistentPagination
        }
        return self
    }
}

enum SavedThreadError: LocalizedError, Equatable {
    case persistenceUnavailable
    case incompleteThread
    case inconsistentPagination
    case tooManyPages
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            return "本机保存空间暂不可用。"
        case .incompleteThread:
            return "没有拿到完整主楼，未写入本地保存。"
        case .inconsistentPagination:
            return "帖子分页在保存期间发生变化，请稍后重试。"
        case .tooManyPages:
            return "帖子页数超出本机保存上限。"
        case .unsupportedFormat:
            return "本地保存的数据版本无法读取。"
        }
    }
}

enum SavedThreadPolicy {
    static let maximumSavedThreads = 100
    static let maximumThreadPages = 10_000
    static let maximumSubpostPages = 10_000
    static let subpostPageSize = 10
    static let maximumStorageByteCount = 128 * 1_024 * 1_024
}

@MainActor
final class SavedThreadStore: ObservableObject {
    static let shared = SavedThreadStore()

    @Published private(set) var entries: [SavedThreadSnapshot] = []
    @Published private(set) var persistenceError: String?

    private var file: SecureCodableFile<[SavedThreadSnapshot]>?

    init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        do {
            let location = try SecurePersistenceLocation.applicationSupport(
                fileManager: fileManager,
                baseDirectoryURL: baseDirectoryURL
            )
            let file = try SecureCodableFile<[SavedThreadSnapshot]>(
                directoryURL: location.directoryURL,
                fileName: "saved-threads.json",
                fileManager: fileManager,
                maximumByteCount: SavedThreadPolicy.maximumStorageByteCount
            )
            self.file = file
            entries = try Self.normalized(file.load() ?? [])
        } catch {
            file = nil
            persistenceError = error.localizedDescription
        }
    }

    func contains(threadID: Int64) -> Bool {
        entries.contains { $0.id == threadID }
    }

    func snapshot(threadID: Int64) -> SavedThreadSnapshot? {
        entries.first { $0.id == threadID }
    }

    func save(_ snapshot: SavedThreadSnapshot) throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        let validated = try snapshot.validated()
        entries = try file.update(default: []) { values in
            values.removeAll { $0.id == validated.id }
            values.insert(validated, at: 0)
            values = Array(try Self.normalized(values).prefix(SavedThreadPolicy.maximumSavedThreads))
        }
        persistenceError = nil
    }

    func remove(threadID: Int64) throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        entries = try file.update(default: []) { values in
            values.removeAll { $0.id == threadID }
            values = try Self.normalized(values)
        }
        persistenceError = nil
    }

    func clear() throws {
        guard let file else { throw SavedThreadError.persistenceUnavailable }
        try file.replace([])
        entries = []
        persistenceError = nil
    }

    private static func normalized(_ values: [SavedThreadSnapshot]) throws -> [SavedThreadSnapshot] {
        var knownIDs = Set<Int64>()
        return try values
            .map { try $0.validated() }
            .sorted { $0.savedAt > $1.savedAt }
            .filter { knownIDs.insert($0.id).inserted }
    }
}

struct SavedThreadCaptureService {
    let api: any TiebaAPIService

    func capture(
        account: Account?,
        threadID: Int64,
        forumID: Int64? = nil,
        savedAt: Date = Date()
    ) async throws -> SavedThreadSnapshot {
        try Task.checkCancellation()
        var firstPage = try await loadThreadPage(
            account: account,
            threadID: threadID,
            page: 1,
            forumID: forumID
        )
        if ThreadPageMainPostPolicy.mainPost(in: firstPage) == nil {
            firstPage = try await loadThreadPage(
                account: account,
                threadID: threadID,
                page: 1,
                forumID: forumID
            )
        }
        guard firstPage.thread.id == threadID,
              firstPage.totalPage > 0,
              firstPage.totalPage <= SavedThreadPolicy.maximumThreadPages,
              let mainPost = ThreadPageMainPostPolicy.mainPost(in: firstPage),
              mainPost.id > 0,
              firstPage.forum.id > 0 else {
            throw SavedThreadError.incompleteThread
        }

        var orderedPosts = [mainPost]
        var knownPostIDs = Set([mainPost.id])
        appendUnique(firstPage.posts, to: &orderedPosts, knownIDs: &knownPostIDs)

        if firstPage.totalPage > 1 {
            for pageNumber in 2...firstPage.totalPage {
                try Task.checkCancellation()
                let page = try await loadThreadPage(
                    account: account,
                    threadID: threadID,
                    page: pageNumber,
                    forumID: firstPage.forum.id
                )
                guard page.thread.id == threadID,
                      page.currentPage == pageNumber,
                      page.totalPage == firstPage.totalPage else {
                    throw SavedThreadError.inconsistentPagination
                }
                appendUnique(page.posts, to: &orderedPosts, knownIDs: &knownPostIDs)
            }
        }

        orderedPosts.sort {
            if $0.floor == $1.floor { return $0.id < $1.id }
            return $0.floor < $1.floor
        }
        guard orderedPosts.first?.id == mainPost.id else {
            throw SavedThreadError.incompleteThread
        }

        var savedPosts: [SavedThreadPost] = []
        savedPosts.reserveCapacity(orderedPosts.count)
        for post in orderedPosts {
            try Task.checkCancellation()
            let subposts = try await loadAllSubposts(
                account: account,
                threadID: threadID,
                forumID: firstPage.forum.id,
                post: post
            )
            savedPosts.append(SavedThreadPost(post: post, subposts: subposts))
        }

        return try SavedThreadSnapshot(
            thread: firstPage.thread,
            forum: firstPage.forum,
            posts: savedPosts,
            savedAt: savedAt
        ).validated()
    }

    private func loadThreadPage(
        account: Account?,
        threadID: Int64,
        page: Int,
        forumID: Int64?
    ) async throws -> ThreadPage {
        try await api.threadPage(
            account: account,
            threadID: threadID,
            page: page,
            forumID: forumID,
            postID: nil,
            seeLz: false,
            sortType: .ascending
        )
    }

    private func loadAllSubposts(
        account: Account?,
        threadID: Int64,
        forumID: Int64,
        post: Post
    ) async throws -> [Subpost] {
        guard post.subpostCount > 0 || post.previewSubposts.isEmpty == false else { return [] }
        var result: [Subpost] = []
        var knownIDs = Set<UInt64>()

        for page in 1...SavedThreadPolicy.maximumSubpostPages {
            try Task.checkCancellation()
            let loaded = try await api.subposts(
                account: account,
                threadID: threadID,
                postID: post.id,
                forumID: forumID,
                page: page,
                subpostID: 0
            )
            let previousCount = result.count
            appendUnique(loaded, to: &result, knownIDs: &knownIDs)
            if loaded.count < SavedThreadPolicy.subpostPageSize {
                guard result.count >= max(post.subpostCount, post.previewSubposts.count) else {
                    throw SavedThreadError.incompleteThread
                }
                return result.sorted {
                    if $0.floor == $1.floor { return $0.id < $1.id }
                    return $0.floor < $1.floor
                }
            }
            guard result.count > previousCount else {
                throw SavedThreadError.inconsistentPagination
            }
        }
        throw SavedThreadError.tooManyPages
    }

    private func appendUnique<Element: Identifiable>(
        _ values: [Element],
        to result: inout [Element],
        knownIDs: inout Set<Element.ID>
    ) where Element.ID: Hashable {
        for value in values where knownIDs.insert(value.id).inserted {
            result.append(value)
        }
    }
}
