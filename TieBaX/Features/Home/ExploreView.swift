import SwiftUI

/// TiebaLite's Explore page is a set of independent feeds rather than a
/// second copy of the home page. The native recommendation feed, followed
/// forum directory, and native hot-topic search are available here.
struct ExploreView: View {
    let account: Account?

    private enum Section: String, CaseIterable, Identifiable {
        case recommended
        case followed
        case hot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recommended: return "推荐"
            case .followed: return "关注"
            case .hot: return "热门"
            }
        }
    }

    @State private var section: Section = .recommended

    var body: some View {
        VStack(spacing: 0) {
            Picker("发现内容", selection: $section) {
                ForEach(Section.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .frame(minHeight: 44)
            .padding(.horizontal, TieBaXTheme.Spacing.md)
            .padding(.vertical, TieBaXTheme.Spacing.xs)
            .accessibilityIdentifier("explore-section-picker")

            Group {
                switch section {
                case .recommended:
                    HomeView(account: account, navigationTitle: "推荐")
                case .followed:
                    followedContent
                case .hot:
                    TieBaNavigationStack {
                        HotThreadsView(account: account)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TieBaXTheme.ColorToken.readerGroupedBackground)
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var followedContent: some View {
        if let account {
            TieBaNavigationStack {
                ForumListView(account: account)
            }
        } else {
            ReaderStateView(
                kind: .empty,
                title: "登录后查看关注内容",
                message: "登录后可以查看关注的贴吧，并快速进入对应的帖子列表。",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .accessibilityIdentifier("explore-followed-login-prompt")
        }
    }
}

private struct HotThreadsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let account: Account?

    @State private var topics: [HotTopicSummary] = []
    @State private var tabs: [HotThreadTab] = []
    @State private var threads: [ThreadSummary] = []
    @State private var currentTabCode = "all"
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var selectedThread: ThreadSummary?
    @State private var selectedTopic: HotTopicSummary?

    var body: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading("正在加载热门帖子")
            } else if let errorMessage, threads.isEmpty {
                ReaderStateScrollView(refresh: { await reload(tabCode: currentTabCode, replace: true) }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload(tabCode: currentTabCode, replace: true) }
                    }
                }
            } else if threads.isEmpty {
                ReaderStateScrollView(refresh: { await reload(tabCode: currentTabCode, replace: true) }) {
                    ReaderStateView.empty(
                        title: "暂无热门帖子",
                        message: "官方 hotThreadList 暂时没有返回帖子，请稍后重试。",
                        actionTitle: "重新加载",
                        action: { Task { await reload(tabCode: currentTabCode, replace: true) } }
                    )
                }
            } else {
                feed
            }
        }
        .navigationTitle("热门")
        .navigationBarTitleDisplayMode(.inline)
        .tieBaTask {
            guard didLoad == false else { return }
            await reload(tabCode: "all", replace: true)
        }
        .tieBaNavigationDestination(isPresented: selectedThreadIsActive) {
            if let selectedThread {
                ThreadDetailView(
                    account: account,
                    threadID: selectedThread.id,
                    forumID: selectedThread.forumID,
                    mainPostFallback: ThreadMainPostFallback(thread: selectedThread)
                )
                .interactiveNavigationPopStateSync {
                    self.selectedThread = nil
                }
            }
        }
        .tieBaNavigationDestination(isPresented: selectedTopicIsActive) {
            if let selectedTopic {
                SearchResultsView(
                    account: account,
                    scope: .global,
                    initialKeyword: selectedTopic.name
                )
                .interactiveNavigationPopStateSync {
                    self.selectedTopic = nil
                }
            }
        }
        .accessibilityIdentifier("explore-hot-threads")
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if topics.isEmpty == false {
                    topicStrip
                }
                if tabs.isEmpty == false {
                    tabStrip
                }
                ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                    ForumThreadRow(
                        thread: thread,
                        showsForumInfo: true,
                        presentation: .list,
                        onOpenThread: { selectedThread = thread },
                        onOpenComments: { selectedThread = thread },
                        threadOpenAccessibilityIdentifier: "hot-thread-open-\(thread.id)",
                        commentsAccessibilityIdentifier: "hot-thread-comments-\(thread.id)"
                    )
                    .accessibilityIdentifier("hot-thread-row-\(thread.id)")
                    if index < threads.count - 1 {
                        Divider()
                    }
                }
            }
            .readableWidth()
        }
        .shortPullRefresh(
            isEnabled: didLoad && isLoading == false,
            surface: .grouped,
            accessibilityIdentifier: "explore-hot-threads-refresh"
        ) {
            await reload(tabCode: currentTabCode, replace: true)
        }
    }

    private var topicStrip: some View {
        VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xs) {
            HStack(spacing: TieBaXTheme.Spacing.sm) {
                Image(systemName: "flame.fill")
                    .tieBaForegroundStyle(TieBaXTheme.ColorToken.primaryAccent)
                Text("热门话题")
                    .font(.headline)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TieBaXTheme.Spacing.xs) {
                    ForEach(topics) { topic in
                        Button {
                            selectedTopic = topic
                        } label: {
                            Text(topic.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, TieBaXTheme.Spacing.sm)
                                .padding(.vertical, TieBaXTheme.Spacing.xs)
                                .background(TieBaXTheme.ColorToken.readerSecondarySurface)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看热门话题\(topic.name)")
                    }
                }
            }
        }
        .padding(.horizontal, TieBaXTheme.Spacing.md)
        .padding(.vertical, TieBaXTheme.Spacing.sm)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TieBaXTheme.Spacing.xs) {
                ForEach(tabs) { tab in
                    Button {
                        select(tab: tab)
                    } label: {
                        Text(tab.title)
                            .font(.subheadline.weight(currentTabCode == tab.code ? .semibold : .regular))
                            .foregroundColor(currentTabCode == tab.code ? .white : .primary)
                            .padding(.horizontal, TieBaXTheme.Spacing.md)
                            .padding(.vertical, TieBaXTheme.Spacing.xs)
                            .background(currentTabCode == tab.code ? TieBaXTheme.ColorToken.primaryAccent : TieBaXTheme.ColorToken.readerSecondarySurface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("热门分类\(tab.title)")
                    .accessibilityIdentifier("hot-thread-tab-\(tab.code)")
                }
            }
            .padding(.horizontal, TieBaXTheme.Spacing.md)
            .padding(.bottom, TieBaXTheme.Spacing.xs)
        }
    }

    private func select(tab: HotThreadTab) {
        guard tab.code != currentTabCode else { return }
        currentTabCode = tab.code
        Task { await reload(tabCode: tab.code, replace: true) }
    }

    private func reload(tabCode: String, replace: Bool) async {
        guard isLoading == false else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let requestedCode = tabCode.trimmingCharacters(in: .whitespacesAndNewlines)
            var page: HotThreadFeedPage?
            var firstError: Error?
            let candidateCodes = [requestedCode] + HotThreadTabPolicy.fallbackCodes(
                requestedCode: requestedCode,
                tabs: tabs
            )
            // Retry the stable TiebaLite V11 tab codes even when the initial
            // request throws. The old code only retried after a successful
            // empty response, so a transient decode/network error left the
            // screen in the same empty state forever.
            for candidateCode in candidateCodes {
                guard Task.isCancelled == false else { throw CancellationError() }
                do {
                    let candidate = try await environment.api.hotThreads(
                        account: account,
                        tabCode: candidateCode
                    )
                    if let existing = page {
                        page = HotThreadFeedPage(
                            topics: candidate.topics.isEmpty ? existing.topics : candidate.topics,
                            tabs: candidate.tabs.isEmpty ? existing.tabs : candidate.tabs,
                            threads: candidate.threads
                        )
                    } else {
                        page = candidate
                    }
                    if candidate.threads.isEmpty == false { break }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            guard let loadedPage = page else {
                throw firstError ?? TiebaAPIError.emptyResponse
            }
            let resolvedPage = loadedPage
            if resolvedPage.tabs.isEmpty == false {
                tabs = resolvedPage.tabs
                if replace {
                    currentTabCode = HotThreadTabPolicy.preferredCode(
                        requestedCode: requestedCode,
                        tabs: resolvedPage.tabs
                    )
                }
            }
            if resolvedPage.topics.isEmpty == false {
                topics = resolvedPage.topics
            }
            // A refresh can briefly receive an empty page while the server
            // shard is switching hot-feed data. Keep the last known feed in
            // that case; replacing it with an empty array is what made the
            // page get stuck on “暂无热门帖子” after a pull-to-refresh.
            if resolvedPage.threads.isEmpty == false || threads.isEmpty {
                threads = resolvedPage.threads
            }
            didLoad = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = ReaderErrorMessage.message(for: error)
            didLoad = true
        }
    }

    private var selectedThreadIsActive: Binding<Bool> {
        Binding(
            get: { selectedThread != nil },
            set: { isActive in
                if isActive == false {
                    selectedThread = nil
                }
            }
        )
    }

    private var selectedTopicIsActive: Binding<Bool> {
        Binding(
            get: { selectedTopic != nil },
            set: { isActive in
                if isActive == false {
                    selectedTopic = nil
                }
            }
        )
    }
}
