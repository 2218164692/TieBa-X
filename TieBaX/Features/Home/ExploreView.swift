import Foundation
import SwiftUI

/// TiebaLite's Explore page is a set of independent feeds rather than a
/// second copy of the home page. The native recommendation feed, followed
/// forum directory, and ranked hot feed are available here.
struct ExploreView: View {
    let account: Account?

    private enum Section: String, CaseIterable, Identifiable {
        case followed
        case recommended
        case hot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recommended: return "推荐"
            case .followed: return "关注"
            case .hot: return "热榜"
            }
        }
    }

    @State private var section: Section = .recommended

    var body: some View {
        VStack(spacing: 0) {
            Picker("动态内容", selection: $section) {
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
        .navigationTitle("动态")
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
    @State private var showAllTopics = false
    @State private var activeRequestID: UUID?

    var body: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading("正在加载热榜")
            } else if let errorMessage, threads.isEmpty, topics.isEmpty, tabs.isEmpty {
                HotStateScrollView(refresh: { await reload(tabCode: currentTabCode, replace: true) }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload(tabCode: currentTabCode, replace: true) }
                    }
                }
            } else if threads.isEmpty && topics.isEmpty && tabs.isEmpty {
                HotStateScrollView(refresh: { await reload(tabCode: currentTabCode, replace: true) }) {
                    ReaderStateView.empty(
                        title: "暂无热榜帖子",
                        message: "官方 hotThreadList 暂时没有返回帖子，请稍后重试。",
                        actionTitle: "重新加载",
                        action: { Task { await reload(tabCode: currentTabCode, replace: true) } }
                    )
                }
            } else {
                feed
            }
        }
        .navigationTitle("热榜")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await reload(tabCode: currentTabCode, replace: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新热榜")
                .accessibilityIdentifier("explore-hot-threads-refresh")
            }
        }
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
                HotTopicDetailView(account: account, topic: selectedTopic)
                .interactiveNavigationPopStateSync {
                    self.selectedTopic = nil
                }
            }
        }
        .tieBaNavigationDestination(isPresented: allTopicsIsActive) {
            HotTopicDirectoryView(account: account, initialTopics: topics)
                .interactiveNavigationPopStateSync {
                    showAllTopics = false
                }
        }
        .accessibilityIdentifier("explore-hot-threads")
        .onDisappear {
            // Ignore a response that completes after this destination has been
            // removed (for example while opening a topic or thread). The task
            // itself is owned by the view hierarchy, so invalidating the token
            // is the safe iOS 14-compatible cancellation boundary.
            activeRequestID = nil
        }
    }

    private var feed: some View {
        ScrollView {
            // Keep row identity independent from the server's thread ID. The
            // official response may contain the same ID more than once, while
            // LazyVStack keeps the complete feed memory-safe on iOS 14.
            LazyVStack(spacing: 0) {
                if topics.isEmpty == false {
                    topicBoard
                }
                if tabs.isEmpty == false {
                    tabStrip
                }
                if threads.isEmpty {
                    ReaderStateView.empty(
                        title: "暂无热榜帖子",
                        message: errorMessage ?? "官方 hotThreadList 暂时没有返回帖子，请稍后重试。",
                        actionTitle: "重新加载",
                        action: { Task { await reload(tabCode: currentTabCode, replace: true) } }
                    )
                    .padding(.vertical, TieBaXTheme.Spacing.lg)
                } else {
                    ForEach(indexedThreads) { entry in
                        let index = entry.index
                        let thread = entry.thread
                        HStack(alignment: .top, spacing: TieBaXTheme.Spacing.xs) {
                            ForumThreadRow(
                                thread: thread,
                                showsForumInfo: true,
                                presentation: .list,
                                onOpenThread: { selectedThread = thread },
                                onOpenComments: { selectedThread = thread },
                                threadOpenAccessibilityIdentifier: "hot-thread-open-\(thread.id)",
                                commentsAccessibilityIdentifier: "hot-thread-comments-\(thread.id)"
                            )
                            .frame(maxWidth: .infinity)
                            HotThreadRankView(rank: index + 1, hotNum: thread.hotNum)
                                .frame(width: 64)
                        }
                        .padding(.horizontal, TieBaXTheme.Spacing.md)
                        .padding(.vertical, TieBaXTheme.Spacing.xs)
                        .accessibilityIdentifier("hot-thread-row-\(thread.id)-\(index)")
                        if index < indexedThreads.count - 1 {
                            Divider()
                                .padding(.horizontal, TieBaXTheme.Spacing.md)
                        }
                    }
                }
                Color.clear
                    .frame(height: TieBaXTheme.Spacing.lg)
                    .accessibilityHidden(true)
            }
            .readableWidth()
        }
        // Switching a ranking category must release the previous rows and
        // reset the scroll coordinator. Reusing the old tree at the previous
        // bottom offset is what made rapid up/down gestures unstable.
        .id("hot-thread-feed-\(currentTabCode)")
        .tieBaRefreshable {
            await reload(tabCode: currentTabCode, replace: true)
        }
    }

    private var indexedThreads: [HotThreadEntry] {
        threads.enumerated().map { index, thread in
            HotThreadEntry(index: index, thread: thread)
        }
    }
    private var topicBoard: some View {
        let rowStarts = Array(stride(from: 0, to: topics.count, by: 2))
        return VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xs) {
            HStack(spacing: TieBaXTheme.Spacing.sm) {
                Image(systemName: "flame.fill")
                    .tieBaForegroundStyle(TieBaXTheme.ColorToken.primaryAccent)
                Text("话题榜")
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: TieBaXTheme.Spacing.xxs) {
                ForEach(rowStarts, id: \.self) { start in
                    HStack(alignment: .center, spacing: TieBaXTheme.Spacing.md) {
                        topicRow(index: start, topic: topics[start])
                        if start + 1 < topics.count {
                            topicRow(index: start + 1, topic: topics[start + 1])
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .accessibilityHidden(true)
                        }
                    }
                }
                Button {
                    showAllTopics = true
                } label: {
                    HStack(spacing: TieBaXTheme.Spacing.xs) {
                        Text("更多话题")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .tieBaForegroundStyle(TieBaXTheme.ColorToken.primaryAccent)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多热门话题")
                .accessibilityIdentifier("hot-topic-more")
            }

            Divider()
                .padding(.top, TieBaXTheme.Spacing.sm)
        }
        .padding(.horizontal, TieBaXTheme.Spacing.md)
        .padding(.top, TieBaXTheme.Spacing.sm)
        .padding(.bottom, TieBaXTheme.Spacing.xs)
    }
    private func topicRow(index: Int, topic: HotTopicSummary) -> some View {
        Button {
            selectedTopic = topic
        } label: {
            HStack(spacing: TieBaXTheme.Spacing.xs) {
                Text("\(index + 1)")
                    .font(.headline.monospacedDigit())
                    .tieBaForegroundStyle(rankColor(index + 1))
                    .frame(minWidth: 22, alignment: .leading)
                Text(topic.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let badgeTitle = topic.badgeTitle {
                    Text(badgeTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, TieBaXTheme.Spacing.xxs)
                        .padding(.vertical, 2)
                        .background(topic.tag == 2 ? Color.red : Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: TieBaXTheme.Radius.chip))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("热门话题第\(index + 1)名，\(topic.name)")
        .accessibilityIdentifier("hot-topic-\(topic.id)")
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        default: return .secondary
        }
    }
    private var tabStrip: some View {
        let rowStarts = Array(stride(from: 0, to: tabs.count, by: 5))
        return VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xs) {
            VStack(spacing: TieBaXTheme.Spacing.xs) {
                ForEach(rowStarts, id: \.self) { start in
                    tabRow(start: start)
                }
            }
            Text("(按内容热度排序，每小时更新一次)")
                .font(.caption)
                .tieBaForegroundStyle(.secondary)
        }
        .padding(.horizontal, TieBaXTheme.Spacing.md)
        .padding(.vertical, TieBaXTheme.Spacing.xs)
        .background(TieBaXTheme.ColorToken.readerGroupedBackground)
    }

    private func tabRow(start: Int) -> some View {
        let end = min(start + 5, tabs.count)
        return HStack(spacing: TieBaXTheme.Spacing.sm) {
            ForEach(Array(tabs[start..<end])) { tab in
                tabButton(tab)
            }
            if end - start < 5 {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .accessibilityHidden(true)
            }
        }
    }

    private func tabButton(_ tab: HotThreadTab) -> some View {
        Button {
            select(tab: tab)
        } label: {
            Text(tab.title)
                .font(.subheadline.weight(currentTabCode == tab.code ? .semibold : .regular))
                .foregroundColor(currentTabCode == tab.code ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    currentTabCode == tab.code
                        ? TieBaXTheme.ColorToken.primaryAccent
                        : TieBaXTheme.ColorToken.readerSecondarySurface
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("热门分类\(tab.title)")
        .accessibilityIdentifier("hot-thread-tab-\(tab.code)")
    }
    private func select(tab: HotThreadTab) {
        guard tab.code != currentTabCode else { return }
        currentTabCode = tab.code
        // Do not leave the previous category visible while its response is in
        // flight. Apart from being misleading, keeping those rows alive while
        // the ranking tree is replaced increases the chance of stale row
        // state being reused by SwiftUI's scroll coordinator.
        threads = []
        errorMessage = nil
        Task { await reload(tabCode: tab.code, replace: true) }
    }

    private func reload(tabCode: String, replace: Bool) async {
        // A tab tap, toolbar refresh, and native pull-to-refresh can overlap.
        // Give each request a token so an older response cannot replace the
        // newly selected category or clear its loading state while scrolling.
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        errorMessage = nil
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }
        do {
            guard Task.isCancelled == false else { throw CancellationError() }
            let requestedCode = tabCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = requestedCode.isEmpty ? "all" : String(requestedCode.prefix(32))
            // TiebaLite calls hotThreadList once for the selected tab. Do not
            // substitute another category when a category legitimately has no
            // results; doing so made the selected tab show the wrong list.
            let page = try await environment.api.hotThreads(account: account, tabCode: code)
            guard Task.isCancelled == false, activeRequestID == requestID else { return }
            if page.tabs.isEmpty {
                // Category responses commonly omit tab metadata. Preserve the
                // initial list, while still exposing 总榜 if the first page
                // itself had no metadata.
                if tabs.isEmpty {
                    tabs = [HotThreadTabPolicy.totalTab]
                }
            } else {
                let normalizedTabs = HotThreadTabPolicy.normalizedTabs(page.tabs)
                let serverHasCategory = page.tabs.contains { $0.code != "all" }
                if tabs.isEmpty || tabs.count <= 1 || serverHasCategory {
                    tabs = normalizedTabs
                }
            }
            if page.topics.isEmpty == false {
                topics = page.topics
            }
            if replace || threads.isEmpty {
                threads = page.threads
            }
            currentTabCode = code
            didLoad = true
        } catch is CancellationError {
            return
        } catch {
            guard activeRequestID == requestID else { return }
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

    private var allTopicsIsActive: Binding<Bool> {
        Binding(
            get: { showAllTopics },
            set: { isActive in
                if isActive == false {
                    showAllTopics = false
                }
            }
        )
    }
}
private struct HotThreadEntry: Identifiable {
    let index: Int
    let thread: ThreadSummary

    var id: String {
        "\(thread.id)-\(index)"
    }
}
private struct HotThreadRankView: View {
    let rank: Int
    let hotNum: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: TieBaXTheme.Spacing.xxs) {
            Text("\(rank)")
                .font(.headline.weight(.bold))
                .tieBaForegroundStyle(rankColor)
            if let hotNum, hotNum > 0 {
                Text("热度 \(HotThreadNumberFormatter.compact(hotNum))")
                    .font(.caption2)
                    .multilineTextAlignment(.trailing)
                    .tieBaForegroundStyle(rankColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, TieBaXTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hotNum.map { "第\(rank)名，热度 \(HotThreadNumberFormatter.compact($0))" } ?? "第\(rank)名")
    }

    private var rankColor: Color {
        switch rank {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        default: return .secondary
        }
    }
}

private enum HotThreadNumberFormatter {
    static func compact(_ value: Int) -> String {
        let number = Double(max(value, 0))
        if number >= 100_000_000 {
            return formatted(number / 100_000_000, suffix: "亿")
        }
        if number >= 10_000 {
            return formatted(number / 10_000, suffix: "万")
        }
        if number >= 1_000 {
            return formatted(number / 1_000, suffix: "千")
        }
        return String(Int(number))
    }

    private static func formatted(_ value: Double, suffix: String) -> String {
        let rounded = value.rounded(.down)
        if rounded >= 100 || value.rounded() == value {
            return "\(Int(value.rounded()))\(suffix)"
        }
        return String(format: "%.1f\(suffix)", value)
    }
}

private struct HotTopicDirectoryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let account: Account?
    let initialTopics: [HotTopicSummary]

    @State private var topics: [HotTopicSummary]
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var selectedTopic: HotTopicSummary?

    init(account: Account?, initialTopics: [HotTopicSummary]) {
        self.account = account
        self.initialTopics = initialTopics
        _topics = State(initialValue: initialTopics)
    }

    var body: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading("正在加载热门话题")
            } else if topics.isEmpty, let errorMessage {
                HotStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload() }
                    }
                }
            } else if topics.isEmpty {
                HotStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.empty(
                        title: "暂无热门话题",
                        message: "官方话题目录暂时没有返回内容，请稍后重试。",
                        actionTitle: "重新加载",
                        action: { Task { await reload() } }
                    )
                }
            } else {
                List {
                    ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                        Button {
                            selectedTopic = topic
                        } label: {
                            HStack(spacing: TieBaXTheme.Spacing.sm) {
                                if let imageURL = topic.imageURL {
                                    AvatarView(url: imageURL, title: topic.name, size: TieBaXTheme.AvatarSize.medium)
                                }
                                VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xxs) {
                                    Text(topic.name)
                                        .font(.body.weight(.medium))
                                    if topic.description.isEmpty == false {
                                        Text(topic.description)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .tieBaForegroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .tieBaForegroundStyle(.secondary)
                            }
                            .frame(minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看热门话题\(topic.name)")
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("热门话题")
        .navigationBarTitleDisplayMode(.inline)
        .tieBaTask {
            guard didLoad == false else { return }
            await reload()
        }
        .tieBaNavigationDestination(isPresented: selectedTopicIsActive) {
            if let selectedTopic {
                HotTopicDetailView(account: account, topic: selectedTopic)
                    .interactiveNavigationPopStateSync {
                        self.selectedTopic = nil
                    }
            }
        }
        .accessibilityIdentifier("hot-topic-directory")
    }

    private func reload() async {
        guard isLoading == false else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await environment.api.hotTopics()
            if loaded.isEmpty == false {
                var seen = Set<String>()
                topics = (initialTopics + loaded).filter { seen.insert($0.id).inserted }
            }
            didLoad = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = ReaderErrorMessage.message(for: error)
            didLoad = true
        }
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

/// The detail destination for a hot topic. It intentionally uses the public
/// topicDetail feed rather than SearchResultsView so topic ranking semantics,
/// media and pagination are preserved.
private struct HotTopicDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let account: Account?
    let topic: HotTopicSummary

    @State private var resolvedTopic: HotTopicSummary
    @State private var threads: [ThreadSummary] = []
    @State private var currentPage = 1
    @State private var lastID = ""
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var selectedThread: ThreadSummary?
    @State private var activeRequestID: UUID?

    init(account: Account?, topic: HotTopicSummary) {
        self.account = account
        self.topic = topic
        _resolvedTopic = State(initialValue: topic)
    }

    var body: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading("正在加载话题")
            } else if let errorMessage, threads.isEmpty {
                HotStateScrollView(refresh: { await reload(replace: true) }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload(replace: true) }
                    }
                }
            } else {
                content
            }
        }
        .navigationTitle(resolvedTopic.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await reload(replace: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新话题")
                .accessibilityIdentifier("hot-topic-detail-refresh")
            }
        }
        .tieBaTask {
            guard didLoad == false else { return }
            await reload(replace: true)
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
        .accessibilityIdentifier("hot-topic-detail")
        .onDisappear {
            activeRequestID = nil
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                topicHeader
                if threads.isEmpty {
                    ReaderStateView.empty(
                        title: "暂无相关帖子",
                        message: "该话题暂时没有返回关联帖子。",
                        actionTitle: "重新加载",
                        action: { Task { await reload(replace: true) } }
                    )
                    .padding(.vertical, TieBaXTheme.Spacing.lg)
                } else {
                    ForEach(indexedThreads) { entry in
                        let index = entry.index
                        let thread = entry.thread
                        ForumThreadRow(
                            thread: thread,
                            showsForumInfo: true,
                            presentation: .list,
                            onOpenThread: { selectedThread = thread },
                            onOpenComments: { selectedThread = thread },
                            threadOpenAccessibilityIdentifier: "hot-topic-thread-open-\(thread.id)-\(index)",
                            commentsAccessibilityIdentifier: "hot-topic-thread-comments-\(thread.id)-\(index)"
                        )
                        .padding(.horizontal, TieBaXTheme.Spacing.md)
                        .padding(.vertical, TieBaXTheme.Spacing.xs)
                        if index < indexedThreads.count - 1 {
                            Divider()
                                .padding(.horizontal, TieBaXTheme.Spacing.md)
                        }
                    }
                    if hasMore {
                        Button {
                            Task { await loadNextPage() }
                        } label: {
                            HStack {
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                } else {
                                    Text("加载更多")
                                        .font(.subheadline.weight(.medium))
                                }
                                Spacer()
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                        .accessibilityIdentifier("hot-topic-detail-load-more")
                    } else {
                        Text("已显示全部相关帖子")
                            .font(.caption)
                            .tieBaForegroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, TieBaXTheme.Spacing.md)
                    }
                }
                Color.clear
                    .frame(height: TieBaXTheme.Spacing.lg)
                    .accessibilityHidden(true)
            }
            .readableWidth()
        }
        .id("hot-topic-detail-\(resolvedTopic.id)")
        .tieBaRefreshable {
            await reload(replace: true)
        }
    }

    private var indexedThreads: [HotThreadEntry] {
        threads.enumerated().map { index, thread in
            HotThreadEntry(index: index, thread: thread)
        }
    }
    private var topicHeader: some View {
        HStack(alignment: .top, spacing: TieBaXTheme.Spacing.sm) {
            if let imageURL = resolvedTopic.imageURL {
                AvatarView(
                    url: imageURL,
                    title: resolvedTopic.name,
                    size: TieBaXTheme.AvatarSize.large
                )
            }
            VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xxs) {
                Text(resolvedTopic.name)
                    .font(.title3.weight(.semibold))
                if resolvedTopic.discussCount > 0 {
                    Text("讨论 \(resolvedTopic.discussCount)")
                        .font(.caption)
                        .tieBaForegroundStyle(.secondary)
                }
                if resolvedTopic.description.isEmpty == false {
                    Text(resolvedTopic.description)
                        .font(.subheadline)
                        .tieBaForegroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TieBaXTheme.Spacing.md)
        .padding(.vertical, TieBaXTheme.Spacing.md)
        .background(TieBaXTheme.ColorToken.readerSecondarySurface)
    }

    private func reload(replace: Bool) async {
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        errorMessage = nil
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }
        do {
            let page = try await environment.api.hotTopicDetail(
                account: account,
                topicID: topic.id,
                topicName: topic.name,
                page: 1,
                pageSize: 10,
                offset: 0,
                lastID: ""
            )
            guard Task.isCancelled == false, activeRequestID == requestID else { return }
            resolvedTopic = page.topic
            if replace {
                threads = Self.uniqueThreads(page.threads)
            } else {
                threads = Self.mergedThreads(existing: threads, incoming: page.threads)
            }
            currentPage = max(page.currentPage, 1)
            lastID = page.lastID
            hasMore = page.hasMore && page.threads.isEmpty == false
            didLoad = true
        } catch is CancellationError {
            return
        } catch {
            guard activeRequestID == requestID else { return }
            errorMessage = ReaderErrorMessage.message(for: error)
            didLoad = true
        }
    }

    private func loadNextPage() async {
        guard isLoading == false, hasMore else { return }
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }
        do {
            let nextPage = max(currentPage + 1, 1)
            let page = try await environment.api.hotTopicDetail(
                account: account,
                topicID: topic.id,
                topicName: topic.name,
                page: nextPage,
                pageSize: 10,
                offset: threads.count,
                lastID: lastID
            )
            guard Task.isCancelled == false, activeRequestID == requestID else { return }
            let mergedThreads = Self.mergedThreads(existing: threads, incoming: page.threads)
            let appendedCount = mergedThreads.count - threads.count
            threads = mergedThreads
            currentPage = max(page.currentPage, nextPage)
            lastID = page.lastID
            // Stop when the server repeats an already-rendered page. This
            // mirrors TiebaLite's distinctBy(feedId) reducer and prevents an
            // endless load-more loop at the bottom of a topic.
            hasMore = page.hasMore && page.threads.isEmpty == false && appendedCount > 0
        } catch is CancellationError {
            return
        } catch {
            guard activeRequestID == requestID else { return }
            errorMessage = ReaderErrorMessage.message(for: error)
        }
    }

    private static func uniqueThreads(_ values: [ThreadSummary]) -> [ThreadSummary] {
        var seen = Set<Int64>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func mergedThreads(
        existing: [ThreadSummary],
        incoming: [ThreadSummary]
    ) -> [ThreadSummary] {
        uniqueThreads(existing + incoming)
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
}
/// Hot ranking states use the system refresh bridge only. The shared
/// ReaderStateScrollView owns a short-distance UIKit gesture that is useful for
/// ordinary pages, but it can receive repeated bottom-bounce callbacks on iOS
/// 14 when a ranking has no rows. Keeping this container local makes every hot
/// page follow the same stable scroll lifecycle.
private struct HotStateScrollView<Content: View>: View {
    private let refresh: () async -> Void
    private let content: Content

    init(
        refresh: @escaping () async -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.refresh = refresh
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(proxy.size.height + 1, 1), alignment: .top)
            }
            .tieBaRefreshable {
                await refresh()
            }
            .background(TieBaXTheme.ColorToken.readerGroupedBackground)
        }
        .accessibilityIdentifier("hot-state-scroll-view")
    }
}