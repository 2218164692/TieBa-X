import SwiftUI

/// The collection kept on the account, which the on-device favorites list
/// deliberately does not mirror: one is a local bookmark, the other is what
/// Baidu itself stores for this user.
struct AccountThreadFavoritesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var blocklistStore = BlocklistStore.shared
    let account: Account?
    var openThreadInParent: ((ReaderSplitThreadRoute) -> Void)?

    @State private var favorites: [AccountThreadFavorite] = []
    @State private var nextPage = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var requestGeneration = 0
    @State private var loadTask: Task<AccountThreadFavoritesPage, Error>?
    @State private var activeRoute: ReaderSplitThreadRoute?

    var body: some View {
        Group {
            if account == nil {
                ReaderStateView.empty(
                    title: "未登录",
                    message: "登录后可以查看贴吧账号里收藏的帖子。"
                )
                .frame(maxWidth: .infinity)
                .padding(.top, TiebaPureTheme.Spacing.lg)
            } else if isLoading, didLoad == false {
                ReaderStateView.loading("正在加载贴吧收藏")
            } else if let errorMessage, favorites.isEmpty {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload() }
                    }
                }
            } else if visibleFavorites.isEmpty {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.empty(
                        title: favorites.isEmpty ? "暂无贴吧收藏" : "没有可显示的收藏",
                        message: favorites.isEmpty
                            ? "在贴吧客户端或网页版收藏帖子后，会显示在这里。"
                            : "已按你的屏蔽设置隐藏相关收藏。"
                    )
                }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TiebaPureTheme.ColorToken.readerGroupedBackground)
        .navigationTitle("贴吧收藏")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $activeRoute) { route in
            ThreadDetailView(
                account: account,
                threadID: route.threadID,
                forumID: route.forumID,
                initialPostID: route.initialPostID
            )
        }
        .task {
            guard didLoad == false, account != nil else { return }
            await reload()
        }
        .onChange(of: account?.sessionIdentity) { _ in
            loadTask?.cancel()
            requestGeneration += 1
            favorites = []
            nextPage = 1
            hasMore = true
            didLoad = false
            isLoading = false
            errorMessage = nil
            guard account != nil else { return }
            Task { await reload() }
        }
        .onDisappear {
            loadTask?.cancel()
            requestGeneration += 1
            isLoading = false
        }
        .accessibilityIdentifier("account-thread-favorites")
    }

    private var list: some View {
        List {
            ForEach(Array(visibleFavorites.enumerated()), id: \.element.id) { index, favorite in
                Button {
                    open(favorite)
                } label: {
                    AccountThreadFavoriteRow(favorite: favorite)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("account-thread-favorite-row-\(favorite.threadID)")
                .accessibilityHint("打开收藏的帖子")
                .onAppear {
                    guard PaginationPrefetchPolicy.shouldLoadMore(
                        currentIndex: index,
                        totalCount: visibleFavorites.count
                    ) else { return }
                    Task { await loadMore() }
                }
            }

            if isLoading, didLoad {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("正在加载更多收藏")
            } else if let errorMessage {
                InlineLoadErrorView(message: errorMessage) {
                    Task { await loadMore() }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await reload() }
        .accessibilityIdentifier("account-thread-favorites-list")
    }

    private var visibleFavorites: [AccountThreadFavorite] {
        favorites.filter { favorite in
            TiebaContentFilter.shouldKeep(
                forum: Forum(
                    id: favorite.forumID,
                    name: favorite.forumName,
                    displayName: favorite.forumName,
                    avatarURL: nil,
                    memberCount: 0,
                    threadCount: 0
                )
            )
        }
    }

    private func open(_ favorite: AccountThreadFavorite) {
        // Baidu stores the floor the thread was collected at, so the app opens
        // exactly where the collection points instead of at the first post.
        let route = ReaderSplitThreadRoute(
            threadID: favorite.threadID,
            forumID: favorite.forumID > 0 ? favorite.forumID : nil,
            initialPostID: favorite.markedPostID
        )
        if let openThreadInParent {
            openThreadInParent(route)
        } else {
            activeRoute = route
        }
    }

    private func reload() async {
        loadTask?.cancel()
        requestGeneration += 1
        isLoading = false
        nextPage = 1
        hasMore = true
        errorMessage = nil
        if favorites.isEmpty {
            didLoad = false
        }
        await loadMore(generation: requestGeneration)
    }

    private func loadMore() async {
        await loadMore(generation: requestGeneration)
    }

    private func loadMore(generation: Int) async {
        guard let account, isLoading == false, hasMore else { return }
        let requestedSession = account.sessionIdentity
        isLoading = true
        errorMessage = nil

        do {
            let requestedPage = nextPage
            let task = Task {
                try await environment.api.accountThreadFavorites(
                    account: account,
                    page: requestedPage
                )
            }
            loadTask = task
            let page = try await task.value
            guard generation == requestGeneration,
                  requestedSession == self.account?.sessionIdentity else { return }
            if requestedPage == 1 {
                favorites = page.favorites
            } else {
                let knownIDs = Set(favorites.map(\.threadID))
                favorites.append(
                    contentsOf: page.favorites.filter { knownIDs.contains($0.threadID) == false }
                )
            }
            hasMore = page.hasMore && page.favorites.isEmpty == false
            nextPage = requestedPage + 1
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            loadTask = nil
            isLoading = false
            return
        } catch {
            guard generation == requestGeneration,
                  requestedSession == self.account?.sessionIdentity else { return }
            errorMessage = ReaderErrorMessage.message(for: error)
        }
        guard generation == requestGeneration else { return }
        loadTask = nil
        isLoading = false
        didLoad = true
    }
}

private struct AccountThreadFavoriteRow: View {
    let favorite: AccountThreadFavorite

    var body: some View {
        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
            Text(favorite.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(metadata)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, TiebaPureTheme.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(favorite.title)，\(metadata)")
    }

    private var metadata: String {
        var parts: [String] = []
        if favorite.forumName.isEmpty == false {
            parts.append("\(favorite.forumName)吧")
        }
        if favorite.authorDisplayName.isEmpty == false {
            parts.append(favorite.authorDisplayName)
        }
        if favorite.replyCount > 0 {
            parts.append("\(favorite.replyCount)条回复")
        }
        if let lastReplyAt = favorite.lastReplyAt {
            parts.append(ReaderDateText.string(from: lastReplyAt))
        }
        return parts.joined(separator: " · ")
    }
}
