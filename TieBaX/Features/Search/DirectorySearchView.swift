import SwiftUI

/// TiebaLite exposes separate forum, thread and user search pages.  The
/// thread page remains in `SearchResultsView`; this view supplies the two
/// directory pages without coupling their response models to the thread list.
enum DirectorySearchKind: String, CaseIterable, Identifiable {
    case forums
    case users

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forums: return "贴吧"
        case .users: return "用户"
        }
    }
}

struct DirectorySearchView: View {
    @EnvironmentObject private var environment: AppEnvironment

    let account: Account?
    let keyword: String
    let kind: DirectorySearchKind
    let onOpenForum: (Forum) -> Void
    let onOpenUser: (UserSummary) -> Void

    @ObservedObject private var blocklistStore = BlocklistStore.shared
    @State private var forums: [SearchForumResult] = []
    @State private var users: [SearchUserResult] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var requestGeneration = 0
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading(kind == .forums ? "正在搜索贴吧" : "正在搜索用户")
            } else if let errorMessage, visibleCount == 0 {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload() }
                    }
                }
            } else if visibleCount == 0 {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.empty(
                        title: "没有结果",
                        message: kind == .forums ? "换个贴吧名称试试。" : "换个用户名试试。",
                        actionTitle: hasMore ? "继续加载" : nil,
                        action: hasMore ? { Task { await loadMore() } } : nil
                    )
                }
            } else {
                resultList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TieBaXTheme.ColorToken.readerGroupedBackground)
        .tieBaTask {
            guard didLoad == false else { return }
            await reload()
        }
        .onChange(of: keyword) { _ in
            Task { await reload() }
        }
        .onChange(of: blocklistStore.entries) { _ in
            forums.removeAll { TiebaContentFilter.shouldKeep(forum: $0.forum) == false }
            users.removeAll { TiebaContentFilter.shouldKeep(user: $0.user) == false }
        }
        .onDisappear {
            requestTask?.cancel()
            requestGeneration += 1
        }
        .accessibilityIdentifier("directory-search-\(kind.rawValue)")
    }

    @ViewBuilder
    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if kind == .forums {
                    ForEach(Array(visibleForums.enumerated()), id: \.element.id) { index, result in
                        SearchForumRow(result: result) {
                            onOpenForum(result.forum)
                        }
                        .onAppear { requestLoadMoreIfNeeded(index: index, count: visibleForums.count) }
                    }
                } else {
                    ForEach(Array(visibleUsers.enumerated()), id: \.element.id) { index, result in
                        SearchUserRow(result: result) {
                            onOpenUser(result.user)
                        }
                        .onAppear { requestLoadMoreIfNeeded(index: index, count: visibleUsers.count) }
                    }
                }

                if isLoading, didLoad {
                    ProgressView()
                        .padding(TieBaXTheme.Spacing.md)
                        .accessibilityLabel("正在加载更多结果")
                } else if let errorMessage {
                    InlineLoadErrorView(message: errorMessage) {
                        Task { await loadMore() }
                    }
                } else if hasMore, didLoad {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Label("加载更多", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .tieBaButtonStyle(.bordered)
                    .minTouchTarget()
                    .padding(TieBaXTheme.Spacing.md)
                } else {
                    Text("已显示全部结果")
                        .font(.footnote)
                        .tieBaForegroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(TieBaXTheme.Spacing.md)
                }
            }
            .readableWidth()
        }
        .shortPullRefresh(
            isEnabled: didLoad && isLoading == false,
            surface: .grouped,
            accessibilityIdentifier: "directory-search-refresh"
        ) {
            await reload()
        }
    }

    private var visibleForums: [SearchForumResult] {
        forums.filter { TiebaContentFilter.shouldKeep(forum: $0.forum) }
    }

    private var visibleUsers: [SearchUserResult] {
        users.filter { TiebaContentFilter.shouldKeep(user: $0.user) }
    }

    private var visibleCount: Int {
        kind == .forums ? visibleForums.count : visibleUsers.count
    }

    private func requestLoadMoreIfNeeded(index: Int, count: Int) {
        guard PaginationPrefetchPolicy.shouldLoadMore(currentIndex: index, totalCount: count) else { return }
        Task { await loadMore() }
    }

    private func reload() async {
        requestTask?.cancel()
        requestGeneration += 1
        page = 1
        hasMore = true
        errorMessage = nil
        await loadMore(generation: requestGeneration, replacing: true)
    }

    private func loadMore() async {
        await loadMore(generation: requestGeneration, replacing: false)
    }

    private func loadMore(generation: Int, replacing: Bool) async {
        guard isLoading == false, replacing || hasMore else { return }
        let requestedPage = replacing ? 1 : page
        let task = Task<DirectorySearchRequestResult, Error> {
            if kind == .forums {
                return .forumsPage(
                    try await environment.api.searchForums(keyword: keyword, page: requestedPage)
                )
            }
            return .usersPage(
                try await environment.api.searchUsers(keyword: keyword, page: requestedPage)
            )
        }
        requestTask = Task {
            do {
                let result = try await task.value
                guard generation == requestGeneration else { return }
                if case let .forumsPage(pageResult) = result {
                    forums = replacing ? pageResult.results : deduplicateForums(forums + pageResult.results)
                    page = max(pageResult.currentPage, requestedPage) + 1
                    hasMore = pageResult.hasMore
                } else if case let .usersPage(pageResult) = result {
                    users = replacing ? pageResult.results : deduplicateUsers(users + pageResult.results)
                    page = max(pageResult.currentPage, requestedPage) + 1
                    hasMore = pageResult.hasMore
                }
                errorMessage = nil
                didLoad = true
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration else { return }
                errorMessage = ReaderErrorMessage.message(for: error)
                didLoad = true
            }
            isLoading = false
        }
        isLoading = true
        await requestTask?.value
        requestTask = nil
    }

    private func deduplicateForums(_ values: [SearchForumResult]) -> [SearchForumResult] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private func deduplicateUsers(_ values: [SearchUserResult]) -> [SearchUserResult] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }
}

private enum DirectorySearchRequestResult {
    case forumsPage(SearchForumsPage)
    case usersPage(SearchUsersPage)
}

private struct SearchForumRow: View {
    let result: SearchForumResult
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ReaderCard {
                HStack(spacing: TieBaXTheme.Spacing.sm) {
                    AvatarView(url: result.forum.avatarURL, title: result.forum.displayName)
                    VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xxs) {
                        Text(result.forum.displayName)
                            .font(.body.weight(.semibold))
                            .tieBaForegroundStyle(.primary)
                        if result.introduction.isEmpty == false {
                            Text(result.introduction)
                                .font(.subheadline)
                                .tieBaForegroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(forumMetadata)
                            .font(.footnote)
                            .tieBaForegroundStyle(.secondary)
                    }
                    Spacer(minLength: TieBaXTheme.Spacing.sm)
                    Image(systemName: "chevron.right")
                        .tieBaForegroundStyle(.secondary)
                }
                .minTouchTarget()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("进入\(result.forum.displayName)")
    }

    private var forumMetadata: String {
        var values: [String] = []
        if result.forum.memberCount > 0 { values.append("关注 \(result.forum.memberCount)") }
        if result.forum.threadCount > 0 { values.append("帖子 \(result.forum.threadCount)") }
        if result.isFollowed { values.append("已关注") }
        return values.isEmpty ? "贴吧" : values.joined(separator: " · ")
    }
}

private struct SearchUserRow: View {
    let result: SearchUserResult
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ReaderCard {
                HStack(spacing: TieBaXTheme.Spacing.sm) {
                    AvatarView(url: result.user.portraitURL, title: result.user.displayNameResolved)
                    VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xxs) {
                        Text(result.user.displayNameResolved)
                            .font(.body.weight(.semibold))
                            .tieBaForegroundStyle(.primary)
                        if result.introduction.isEmpty == false {
                            Text(result.introduction)
                                .font(.subheadline)
                                .tieBaForegroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(userMetadata)
                            .font(.footnote)
                            .tieBaForegroundStyle(.secondary)
                    }
                    Spacer(minLength: TieBaXTheme.Spacing.sm)
                    Image(systemName: "chevron.right")
                        .tieBaForegroundStyle(.secondary)
                }
                .minTouchTarget()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看\(result.user.displayNameResolved)的用户主页")
    }

    private var userMetadata: String {
        var values: [String] = []
        if result.followerCount > 0 { values.append("粉丝 \(result.followerCount)") }
        if result.isFollowed { values.append("已关注") }
        return values.isEmpty ? "用户" : values.joined(separator: " · ")
    }
}
