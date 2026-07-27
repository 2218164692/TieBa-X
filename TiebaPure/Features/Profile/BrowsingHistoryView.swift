import SwiftUI

struct BrowsingHistoryView: View {
    let account: Account?

    @ObservedObject private var historyStore = BrowsingHistoryStore.shared
    @ObservedObject private var blocklistStore = BlocklistStore.shared
    @State private var activeEntry: BrowsingHistoryEntry?
    @State private var showsClearConfirmation = false
    @State private var showsPersistenceError = false

    var body: some View {
        Group {
            if visibleEntries.isEmpty {
                ScrollView {
                    ReaderStateView.empty(
                        title: historyStore.items.isEmpty
                            ? "暂无浏览历史"
                            : "没有可显示的浏览历史",
                        message: historyStore.items.isEmpty
                            ? "成功打开过的帖子会显示在这里。"
                            : "已按你的屏蔽设置隐藏相关记录。"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, TiebaPureTheme.Spacing.lg)
                }
                .background(TiebaPureTheme.ColorToken.readerGroupedBackground)
                .accessibilityIdentifier("browsing-history-empty")
            } else {
                List {
                    ForEach(visibleEntries) { entry in
                        Button {
                            activeEntry = entry
                        } label: {
                            BrowsingHistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("browsing-history-row-\(entry.threadID)")
                        .accessibilityHint("打开该帖子")
                    }
                    .onDelete(perform: deleteEntries)
                }
                .listStyle(.plain)
                .accessibilityIdentifier("browsing-history-list")
            }
        }
        .navigationTitle("浏览历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if historyStore.items.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") {
                        showsClearConfirmation = true
                    }
                    .minTouchTarget()
                    .accessibilityLabel("清空全部浏览历史")
                    .accessibilityIdentifier("browsing-history-clear-all")
                }
            }
        }
        .navigationDestination(isPresented: entryIsActive) {
            if let activeEntry {
                ThreadDetailView(
                    account: account,
                    threadID: activeEntry.threadID,
                    forumID: activeEntry.forumID
                )
                .interactiveNavigationPopStateSync {
                    self.activeEntry = nil
                }
            }
        }
        .confirmationDialog(
            "清空全部浏览历史？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                if historyStore.clear() == false {
                    showsPersistenceError = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作只会删除本机保存的帖子浏览记录。")
        }
        .alert("操作失败", isPresented: $showsPersistenceError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("未能保存浏览历史更改，请稍后重试。")
        }
        .onAppear {
            historyStore.reload()
        }
        .onChange(of: blocklistStore.entries) { _ in
            guard let activeEntry,
                  BrowsingHistoryListPolicy.shouldKeep(
                    activeEntry,
                    blocklist: currentBlocklist
                  ) == false else { return }
            self.activeEntry = nil
        }
        .fullScreenInteractiveNavigationPop()
    }

    private var currentBlocklist: BlocklistSnapshot {
        BlocklistSnapshot(entries: blocklistStore.entries)
    }

    private var visibleEntries: [BrowsingHistoryEntry] {
        BrowsingHistoryListPolicy.visibleEntries(
            historyStore.items,
            blocklist: currentBlocklist
        )
    }

    private var entryIsActive: Binding<Bool> {
        Binding(
            get: { activeEntry != nil },
            set: { isPresented in
                if isPresented == false {
                    activeEntry = nil
                }
            }
        )
    }

    private func deleteEntries(at offsets: IndexSet) {
        let threadIDs = BrowsingHistoryListPolicy.threadIDs(
            at: offsets,
            in: visibleEntries
        )
        if historyStore.remove(threadIDs: threadIDs) == false {
            showsPersistenceError = true
        }
    }
}

enum BrowsingHistoryListPolicy {
    static func visibleEntries(
        _ entries: [BrowsingHistoryEntry],
        blocklist: BlocklistSnapshot
    ) -> [BrowsingHistoryEntry] {
        entries.filter { shouldKeep($0, blocklist: blocklist) }
    }

    static func shouldKeep(
        _ entry: BrowsingHistoryEntry,
        blocklist: BlocklistSnapshot
    ) -> Bool {
        if blocklist.blocksUser(id: 0, names: [entry.authorDisplayName]) {
            return false
        }
        if blocklist.containsKeyword(in: entry.title) {
            return false
        }
        if let forumDisplayName = entry.forumDisplayName,
           blocklist.blocksForum(named: forumDisplayName) {
            return false
        }
        return true
    }

    static func threadIDs(
        at offsets: IndexSet,
        in visibleEntries: [BrowsingHistoryEntry]
    ) -> Set<Int64> {
        Set(offsets.compactMap { index in
            visibleEntries.indices.contains(index)
                ? visibleEntries[index].threadID
                : nil
        })
    }
}

private struct BrowsingHistoryRow: View {
    let entry: BrowsingHistoryEntry

    var body: some View {
        HStack(alignment: .center, spacing: TiebaPureTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xs) {
                Text(entry.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                MetadataLine(metadataItems, systemImage: "clock")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.vertical, TiebaPureTheme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var metadataItems: [String] {
        [
            entry.forumDisplayName,
            entry.authorDisplayName,
            "浏览于 \(ReaderDateText.string(from: entry.visitedAt))"
        ].compactMap { $0 }.filter { $0.isEmpty == false }
    }

    private var accessibilityText: String {
        ([entry.title] + metadataItems).joined(separator: "，")
    }
}
