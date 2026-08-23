import SwiftUI

struct SavedThreadsView: View {
    @ObservedObject private var store = SavedThreadStore.shared
    @State private var searchText = ""
    @State private var errorMessage: String?

    private var visibleEntries: [SavedThreadSnapshot] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyword.isEmpty == false else { return store.entries }
        return store.entries.filter {
            $0.thread.title.localizedCaseInsensitiveContains(keyword)
                || $0.thread.author.displayNameResolved.localizedCaseInsensitiveContains(keyword)
                || $0.forum.displayName.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ReaderStateView.empty(
                    title: "还没有本地保存",
                    message: "在帖子页右上角的更多菜单中选择“保存到本地”。"
                )
            } else if visibleEntries.isEmpty {
                ReaderStateView.empty(
                    title: "没有匹配的帖子",
                    message: "换个标题、作者或贴吧名称搜索。"
                )
            } else {
                List {
                    Section {
                        ForEach(visibleEntries) { snapshot in
                            NavigationLink {
                                SavedThreadDetailView(snapshot: snapshot)
                            } label: {
                                SavedThreadRow(snapshot: snapshot)
                            }
                            .accessibilityIdentifier("saved-thread-\(snapshot.id)")
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) {
                                    remove(snapshot.id)
                                }
                            }
                        }
                    } footer: {
                        Text("正文和楼层结构保存在本机；图片、视频和语音仍需通过保存时的原地址联网加载。最多保存\(SavedThreadPolicy.maximumSavedThreads)个帖子。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("本地保存的帖子")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索标题、作者或贴吧")
        .alert("无法删除", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if $0 == false { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenInteractiveNavigationPop()
    }

    private func remove(_ threadID: Int64) {
        do {
            try store.remove(threadID: threadID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SavedThreadRow: View {
    let snapshot: SavedThreadSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xs) {
            Text(snapshot.thread.title.isEmpty ? snapshot.thread.textPreview : snapshot.thread.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            Text("\(snapshot.forum.displayName) · \(snapshot.thread.author.displayNameResolved)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(snapshot.replyCount)层回复 · \(snapshot.subpostCount)条楼中楼 · \(snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, TiebaPureTheme.Spacing.xxs)
    }
}

struct SavedThreadDetailView: View {
    let snapshot: SavedThreadSnapshot
    @State private var selectedPost: SavedThreadPost?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Label(
                    "保存于 \(snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))；媒体需联网加载",
                    systemImage: "internaldrive"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TiebaPureTheme.Spacing.md)
                .padding(.vertical, TiebaPureTheme.Spacing.sm)

                ForEach(snapshot.posts) { savedPost in
                    VStack(spacing: 0) {
                        PostRowView(
                            post: savedPost.displayPost,
                            threadTitle: savedPost.post.floor == 1 ? snapshot.thread.title : nil,
                            threadAuthorID: snapshot.thread.author.id,
                            isMainPost: savedPost.post.floor == 1
                        )
                        .equatable()

                        if savedPost.subposts.isEmpty == false {
                            Button {
                                selectedPost = savedPost
                            } label: {
                                HStack(spacing: TiebaPureTheme.Spacing.xxs) {
                                    Text("查看已保存的\(savedPost.subposts.count)条楼中楼")
                                    Image(systemName: "chevron.right")
                                }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(TiebaPureTheme.ColorToken.primaryAccent)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, TiebaPureTheme.Spacing.md)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("saved-thread-subposts-\(savedPost.id)")
                        }
                    }
                }
            }
            .readableWidth()
        }
        .background(TiebaPureTheme.ColorToken.readerGroupedBackground)
        .navigationTitle(snapshot.forum.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: threadURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享帖子")
            }
        }
        .sheet(item: $selectedPost) { savedPost in
            SavedSubpostsView(
                post: savedPost.post,
                subposts: savedPost.subposts,
                threadAuthorID: snapshot.thread.author.id
            )
        }
        .fullScreenInteractiveNavigationPop()
    }

    private var threadURL: URL {
        URL(string: "https://tieba.baidu.com/p/\(snapshot.id)")!
    }
}

private struct SavedSubpostsView: View {
    @Environment(\.dismiss) private var dismiss
    let post: Post
    let subposts: [Subpost]
    let threadAuthorID: Int64?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(subposts) { subpost in
                        SavedSubpostRow(subpost: subpost, threadAuthorID: threadAuthorID)
                    }
                }
                .readableWidth()
            }
            .background(TiebaPureTheme.ColorToken.readerGroupedBackground)
            .navigationTitle(SubpostSheetTitle.text(floor: post.floor, count: subposts.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct SavedSubpostRow: View {
    @Environment(\.readingPreferences) private var readingPreferences
    let subpost: Subpost
    let threadAuthorID: Int64?

    var body: some View {
        ReaderCard(contentBottomPadding: ThreadPostMetadataPlacement.standaloneReply.cardBottomPadding) {
            VStack(alignment: .leading, spacing: ThreadReplyLayout.headerContentSpacing) {
                UserHeaderView(
                    author: subpost.author,
                    floor: subpost.floor,
                    isThreadAuthor: threadAuthorID != 0 && subpost.author.id == threadAuthorID,
                    nameTone: .secondary,
                    trailingLikeCount: subpost.likeCount,
                    isLiked: subpost.isLiked
                )
                VStack(alignment: .leading, spacing: ThreadReplyLayout.bodyStackSpacing) {
                    ContentBlocksView(
                        blocks: subpost.blocks,
                        textStyle: .reply,
                        readerFontSize: readingPreferences.fontSize,
                        readerLineSpacing: readingPreferences.lineSpacing
                    )
                    ThreadPostMetadataView(
                        createdAt: subpost.createdAt,
                        ipAddress: ThreadPostMetadataText.firstLocation(
                            subpost.ipAddress,
                            subpost.author.ipAddress
                        ),
                        accessibilityIdentifier: "saved-thread-subpost-metadata"
                    )
                }
                .padding(.leading, ThreadReplyLayout.bodyLeadingInset)
            }
        }
    }
}
