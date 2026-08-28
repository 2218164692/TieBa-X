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

    var body: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading("正在加载热榜")
            } else if let errorMessage, threads.isEmpty, topics.isEmpty, tabs.isEmpty {
                ReaderStateScrollView(refresh: { await reload(tabCode: currentTabCode, replace: true) }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload(tabCode: currentTabCode, replace: true) }
                    }
                }
            } else if threads.isEmpty && topics.isEmpty && tabs.isEmpty {
                ReaderStateScrollView(refresh: { await reload(tabCode: currentTabCode, replace: true) }) {
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
        .tieBaNavigationDestination(isPresented: allTopicsIsActive) {
            HotTopicDirectoryView(account: account, initialTopics: topics)
                .interactiveNavigationPopStateSync {
                    showAllTopics = false
                }
        }
        .accessibilityIdentifier("explore-hot-threads")
    }

    private var feed: some View {
        ScrollView {
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
                    ForEach(Array(threads.enumerated()), id: \.offset) { index, thread in
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
                        if index < threads.count - 1 {
                            Divider()
                                .padding(.horizontal, TieBaXTheme.Spacing.md)
                        }
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
    private var topicBoard: some View {
        VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xs) {
            HStack(spacing: TieBaXTheme.Spacing.sm) {
                Image(systemName: "flame.fill")
                    .tieBaForegroundStyle(TieBaXTheme.ColorToken.primaryAccent)
                Text("话题榜")
                    .font(.headline)
                Spacer()
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: TieBaXTheme.Spacing.md),
                    GridItem(.flexible(), spacing: TieBaXTheme.Spacing.md)
                ],
                alignment: .leading,
                spacing: TieBaXTheme.Spacing.xxs
            ) {
                ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                    topicRow(index: index, topic: topic)
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
        VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xs) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: TieBaXTheme.Spacing.sm),
                    count: 5
                ),
                spacing: TieBaXTheme.Spacing.xs
            ) {
                ForEach(tabs) { tab in
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
            }
            Text("(按内容热度排序，每小时更新一次)")
                .font(.caption)
                .tieBaForegroundStyle(.secondary)
        }
        .padding(.horizontal, TieBaXTheme.Spacing.md)
        .padding(.vertical, TieBaXTheme.Spacing.xs)
        .background(TieBaXTheme.ColorToken.readerGroupedBackground)
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
            guard Task.isCancelled == false else { throw CancellationError() }
            let requestedCode = tabCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = requestedCode.isEmpty ? "all" : String(requestedCode.prefix(32))
            // TiebaLite calls hotThreadList once for the selected tab. Do not
            // substitute another category when a category legitimately has no
            // results; doing so made the selected tab show the wrong list.
            let page = try await environment.api.hotThreads(account: account, tabCode: code)
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
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload() }
                    }
                }
            } else if topics.isEmpty {
                ReaderStateScrollView(refresh: { await reload() }) {
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
                SearchResultsView(account: account, scope: .global, initialKeyword: selectedTopic.name)
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
