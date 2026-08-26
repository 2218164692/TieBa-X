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
                        HotTopicsView(account: account)
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

private struct HotTopicsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let account: Account?

    @State private var topics: [HotTopicSummary] = []
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var selectedTopic: HotTopicSummary?

    var body: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading("正在加载热门话题")
            } else if let errorMessage, topics.isEmpty {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload() }
                    }
                }
            } else if topics.isEmpty {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.empty(
                        title: "暂无热门话题",
                        message: "官方榜单暂时没有返回内容，请稍后重试。",
                        actionTitle: "重新加载",
                        action: { Task { await reload() } }
                    )
                }
            } else {
                topicList
            }
        }
        .tieBaTask {
            guard didLoad == false else { return }
            await reload()
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
        .accessibilityIdentifier("explore-hot-topics")
    }

    private var topicList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.sm) {
                    HStack(spacing: TieBaXTheme.Spacing.sm) {
                        Image(systemName: "flame.fill")
                            .tieBaForegroundStyle(TieBaXTheme.ColorToken.primaryAccent)
                        Text("热门话题")
                            .font(.title3.weight(.semibold))
                        Spacer()
                    }
                    Text("官方实时榜单，点击话题查看相关帖子。")
                        .font(.subheadline)
                        .tieBaForegroundStyle(.secondary)
                }
                .padding(TieBaXTheme.Spacing.md)

                ForEach(topics) { topic in
                    Button {
                        selectedTopic = topic
                    } label: {
                        ReaderCard {
                            VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xs) {
                                Text(topic.name)
                                    .font(.body.weight(.semibold))
                                    .tieBaForegroundStyle(.primary)
                                if topic.description.isEmpty == false {
                                    Text(topic.description)
                                        .font(.subheadline)
                                        .tieBaForegroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text("查看相关帖子")
                                    .font(.footnote)
                                    .tieBaForegroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .minTouchTarget()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看热门话题\(topic.name)")
                    .accessibilityIdentifier("hot-topic-row-\(topic.id)")
                }
            }
            .readableWidth()
        }
        .shortPullRefresh(
            isEnabled: didLoad && isLoading == false,
            surface: .grouped,
            accessibilityIdentifier: "explore-hot-topics-refresh"
        ) {
            await reload()
        }
    }

    private func reload() async {
        guard isLoading == false else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            topics = try await environment.api.hotTopics()
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
