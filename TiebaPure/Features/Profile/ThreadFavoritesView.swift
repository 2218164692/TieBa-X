import SwiftUI

struct ThreadFavoritesView: View {
    let account: Account?

    @Environment(\.editMode) private var editMode
    @ObservedObject private var libraryStore = LocalThreadLibraryStore.shared
    @ObservedObject private var blocklistStore = BlocklistStore.shared
    @State private var activeFavorite: ThreadFavoriteEntry?
    @State private var searchText = ""
    @State private var progressFilter: ThreadFavoritesProgressFilter = .all
    @State private var selectedThreadIDs = Set<Int64>()
    @State private var pendingDeletionThreadIDs = Set<Int64>()
    @State private var showsClearFavoritesConfirmation = false
    @State private var showsClearReadingPositionsConfirmation = false
    @State private var showsDeleteSelectionConfirmation = false
    @State private var showsPersistenceError = false

    var body: some View {
        VStack(spacing: 0) {
            if libraryStore.favorites.isEmpty == false {
                progressFilterPicker
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TiebaPureTheme.ColorToken.readerGroupedBackground)
        .navigationTitle("帖子收藏")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "搜索标题、作者或贴吧"
        )
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(allVisibleFavoritesAreSelected ? "取消全选" : "全选") {
                        selectedThreadIDs = LocalThreadListSelectionPolicy
                            .selectionByTogglingAll(
                                selectedThreadIDs,
                                visibleThreadIDs: visibleThreadIDs
                            )
                    }
                    .disabled(visibleFavorites.isEmpty)
                    .accessibilityIdentifier("thread-favorites-select-all")
                }
            }

            if isEditing == false,
               (libraryStore.favorites.isEmpty == false
                || libraryStore.readingPositions.isEmpty == false) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if libraryStore.favorites.isEmpty == false {
                            Button(role: .destructive) {
                                showsClearFavoritesConfirmation = true
                            } label: {
                                Label("清空收藏", systemImage: "star.slash")
                            }
                        }

                        if libraryStore.readingPositions.isEmpty == false {
                            Button(role: .destructive) {
                                showsClearReadingPositionsConfirmation = true
                            } label: {
                                Label("清除阅读位置", systemImage: "bookmark.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .minTouchTarget()
                    .accessibilityLabel("管理本机帖子记录")
                    .accessibilityHint("清空收藏或清除阅读位置")
                    .accessibilityIdentifier("thread-library-manage")
                }
            }

            if visibleFavorites.isEmpty == false || isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .minTouchTarget()
                        .accessibilityIdentifier("thread-favorites-edit")
                }
            }

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            selectionBar
        }
        .navigationDestination(isPresented: favoriteIsActive) {
            if let activeFavorite {
                ThreadDetailView(
                    account: account,
                    threadID: activeFavorite.threadID,
                    forumID: activeFavorite.forumID
                )
                .interactiveNavigationPopStateSync {
                    self.activeFavorite = nil
                }
            }
        }
        .confirmationDialog(
            "清空全部帖子收藏？",
            isPresented: $showsClearFavoritesConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                if libraryStore.clearFavorites() == false {
                    showsPersistenceError = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("阅读位置会继续保留，重新打开帖子时仍可继续阅读。")
        }
        .confirmationDialog(
            "清除全部帖子阅读位置？",
            isPresented: $showsClearReadingPositionsConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                Task {
                    if await libraryStore.clearReadingPositionsInBackground() == false {
                        showsPersistenceError = true
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除阅读位置，不会删除帖子收藏。")
        }
        .confirmationDialog(
            "删除选中的 \(pendingDeletionThreadIDs.count) 条帖子收藏？",
            isPresented: $showsDeleteSelectionConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleteSelectedFavorites(threadIDs: pendingDeletionThreadIDs)
                pendingDeletionThreadIDs.removeAll()
            }
            Button("取消", role: .cancel) {
                pendingDeletionThreadIDs.removeAll()
            }
        } message: {
            Text("只删除收藏，已有阅读位置会继续保留。")
        }
        .alert("操作失败", isPresented: $showsPersistenceError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("未能保存本机帖子记录，请稍后重试。")
        }
        .task {
            await libraryStore.waitForPendingReadingPositionMutations()
            _ = libraryStore.reload()
        }
        .onChange(of: visibleThreadIDs) { _, _ in
            synchronizeSelection()
        }
        .onChange(of: isEditing) { _, editing in
            if editing == false {
                selectedThreadIDs.removeAll()
            }
        }
        .onChange(of: blocklistStore.entries) { _, _ in
            guard let activeFavorite,
                  ThreadFavoritesListPolicy.shouldKeep(
                    activeFavorite,
                    blocklist: currentBlocklist
                  ) == false else { return }
            self.activeFavorite = nil
        }
        .fullScreenInteractiveNavigationPop()
    }

    @ViewBuilder
    private var content: some View {
        if visibleFavorites.isEmpty {
            ScrollView {
                ReaderStateView.empty(
                    title: emptyState.title,
                    message: emptyState.message
                )
                .frame(maxWidth: .infinity)
                .padding(.top, TiebaPureTheme.Spacing.lg)
            }
            .accessibilityIdentifier("thread-favorites-empty")
        } else {
            List(selection: $selectedThreadIDs) {
                ForEach(visibleFavorites) { favorite in
                    Group {
                        if isEditing {
                            ThreadFavoriteRow(
                                favorite: favorite,
                                readingPosition: libraryStore.position(for: favorite.threadID),
                                showsDisclosureIndicator: false
                            )
                        } else {
                            Button {
                                activeFavorite = favorite
                            } label: {
                                ThreadFavoriteRow(
                                    favorite: favorite,
                                    readingPosition: libraryStore.position(for: favorite.threadID)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .tag(favorite.threadID)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("thread-favorite-row-\(favorite.threadID)")
                    .accessibilityHint(isEditing ? "选择或取消选择" : "打开收藏的帖子")
                }
                .onDelete(perform: deleteFavorites)
            }
            .listStyle(.plain)
            .accessibilityIdentifier("thread-favorites-list")
        }
    }

    private var progressFilterPicker: some View {
        Picker("阅读进度", selection: $progressFilter) {
            ForEach(ThreadFavoritesProgressFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .frame(minHeight: 44)
        .padding(.horizontal, TiebaPureTheme.Spacing.md)
        .padding(.vertical, TiebaPureTheme.Spacing.xs)
        .accessibilityIdentifier("thread-favorites-progress-filter")
    }

    @ViewBuilder
    private var selectionBar: some View {
        if isEditing {
            HStack(spacing: TiebaPureTheme.Spacing.md) {
                Text("已选 \(selectedThreadIDs.count) 项")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("thread-favorites-selection-count")

                Spacer(minLength: TiebaPureTheme.Spacing.sm)

                Button(role: .destructive) {
                    pendingDeletionThreadIDs = selectedThreadIDs
                    showsDeleteSelectionConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedThreadIDs.isEmpty)
                .minTouchTarget()
                .accessibilityLabel("删除选中的帖子收藏")
                .accessibilityIdentifier("thread-favorites-delete-selected")
            }
            .frame(minHeight: 50)
            .padding(.horizontal, TiebaPureTheme.Spacing.md)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }

    private var currentBlocklist: BlocklistSnapshot {
        BlocklistSnapshot(entries: blocklistStore.entries)
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    private var visibleFavorites: [ThreadFavoriteEntry] {
        ThreadFavoritesListPolicy.visibleFavorites(
            libraryStore.favorites,
            blocklist: currentBlocklist,
            searchText: searchText,
            progressFilter: progressFilter,
            readingPositions: libraryStore.readingPositions
        )
    }

    private var visibleThreadIDs: [Int64] {
        visibleFavorites.map(\.threadID)
    }

    private var allVisibleFavoritesAreSelected: Bool {
        visibleThreadIDs.isEmpty == false
            && selectedThreadIDs == Set(visibleThreadIDs)
    }

    private var emptyState: (title: String, message: String) {
        if libraryStore.favorites.isEmpty {
            return (
                "暂无帖子收藏",
                "在帖子页点击右上角的收藏按钮后，会显示在这里。"
            )
        }
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || progressFilter != .all {
            return ("没有匹配的帖子收藏", "尝试调整搜索内容或阅读进度筛选。")
        }
        return ("没有可显示的帖子收藏", "已按你的屏蔽设置隐藏相关收藏。")
    }

    private var favoriteIsActive: Binding<Bool> {
        Binding(
            get: { activeFavorite != nil },
            set: { isPresented in
                if isPresented == false {
                    activeFavorite = nil
                }
            }
        )
    }

    private func deleteFavorites(at offsets: IndexSet) {
        let threadIDs = ThreadFavoritesListPolicy.threadIDs(
            at: offsets,
            in: visibleFavorites
        )
        if libraryStore.removeFavorites(threadIDs: threadIDs) == false {
            showsPersistenceError = true
        }
    }

    private func deleteSelectedFavorites(threadIDs: Set<Int64>) {
        guard threadIDs.isEmpty == false else { return }
        guard libraryStore.removeFavorites(threadIDs: threadIDs) else {
            showsPersistenceError = true
            return
        }
        selectedThreadIDs.subtract(threadIDs)
        if visibleFavorites.isEmpty {
            editMode?.wrappedValue = .inactive
        }
    }

    private func synchronizeSelection() {
        selectedThreadIDs = LocalThreadListSelectionPolicy.retainedSelection(
            selectedThreadIDs,
            visibleThreadIDs: visibleThreadIDs
        )
        if isEditing, visibleFavorites.isEmpty {
            editMode?.wrappedValue = .inactive
        }
    }
}

enum ThreadFavoritesProgressFilter: String, CaseIterable, Identifiable {
    case all
    case hasReadingPosition
    case withoutReadingPosition

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .hasReadingPosition:
            return "有进度"
        case .withoutReadingPosition:
            return "无进度"
        }
    }
}

enum ThreadFavoritesListPolicy {
    static func visibleFavorites(
        _ favorites: [ThreadFavoriteEntry],
        blocklist: BlocklistSnapshot,
        searchText: String = "",
        progressFilter: ThreadFavoritesProgressFilter = .all,
        readingPositions: [ThreadReadingPosition] = []
    ) -> [ThreadFavoriteEntry] {
        let threadsWithReadingPositions = Set(readingPositions.map(\.threadID))
        return favorites.filter { favorite in
            shouldKeep(favorite, blocklist: blocklist)
                && LocalThreadListSearchPolicy.matches(
                    query: searchText,
                    fields: [
                        favorite.title,
                        favorite.authorDisplayName,
                        favorite.forumDisplayName,
                        String(favorite.threadID)
                    ]
                )
                && progressFilter.includes(
                    favorite.threadID,
                    threadsWithReadingPositions: threadsWithReadingPositions
                )
        }
    }

    static func shouldKeep(
        _ favorite: ThreadFavoriteEntry,
        blocklist: BlocklistSnapshot
    ) -> Bool {
        if blocklist.blocksUser(id: 0, names: [favorite.authorDisplayName]) {
            return false
        }
        if blocklist.containsKeyword(in: favorite.title) {
            return false
        }
        if blocklist.blocksForum(
            id: favorite.forumID,
            names: favorite.forumDisplayName.map { [$0] } ?? []
        ) {
            return false
        }
        return true
    }

    static func threadIDs(
        at offsets: IndexSet,
        in visibleFavorites: [ThreadFavoriteEntry]
    ) -> Set<Int64> {
        Set(offsets.compactMap { index in
            visibleFavorites.indices.contains(index)
                ? visibleFavorites[index].threadID
                : nil
        })
    }
}

private extension ThreadFavoritesProgressFilter {
    func includes(
        _ threadID: Int64,
        threadsWithReadingPositions: Set<Int64>
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .hasReadingPosition:
            return threadsWithReadingPositions.contains(threadID)
        case .withoutReadingPosition:
            return threadsWithReadingPositions.contains(threadID) == false
        }
    }
}

private struct ThreadFavoriteRow: View {
    let favorite: ThreadFavoriteEntry
    let readingPosition: ThreadReadingPosition?
    var showsDisclosureIndicator = true

    var body: some View {
        HStack(alignment: .center, spacing: TiebaPureTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xs) {
                Text(favorite.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                MetadataLine(metadataItems, systemImage: "star")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.vertical, TiebaPureTheme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var metadataItems: [String] {
        [
            favorite.forumDisplayName,
            favorite.authorDisplayName,
            readingPosition.map { "上次读到 \($0.floor)楼" },
            "收藏于 \(ReaderDateText.string(from: favorite.savedAt))"
        ].compactMap { $0 }.filter { $0.isEmpty == false }
    }

    private var accessibilityText: String {
        ([favorite.title] + metadataItems).joined(separator: "，")
    }
}
