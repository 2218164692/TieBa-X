import SwiftUI
import UniformTypeIdentifiers

struct SavedThreadsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = SavedThreadStore.shared
    let account: Account?

    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var storageByteCount: Int64 = 0
    @State private var storageRefreshGeneration = 0
    @State private var isCheckingUpdates = false
    @State private var isManagingBackup = false
    @State private var backupDocument: SavedThreadBackupDocument?
    @State private var showsBackupExporter = false
    @State private var showsBackupImporter = false
    @State private var pendingImport: SavedThreadBackupDocument?
    @State private var showsImportOptions = false
    @State private var confirmsClear = false

    init(account: Account? = nil) {
        self.account = account
    }

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
                                SavedThreadDetailDestination(
                                    snapshot: snapshot,
                                    mediaStore: store.mediaStore
                                )
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
                        Text("共占用 \(formattedStorageByteCount)，最多保存\(SavedThreadPolicy.maximumSavedThreads)个帖子。完整媒体保存会在无网络时直接读取本机文件。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("本地保存的帖子")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索标题、作者或贴吧")
        .refreshable { await checkAllUpdates(showsResult: false) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await checkAllUpdates(showsResult: true) }
                    } label: {
                        Label("检查新回复", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.entries.isEmpty || isCheckingUpdates)

                    Divider()

                    Button(action: exportBackup) {
                        Label("导出备份", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.entries.isEmpty || isManagingBackup)

                    Button {
                        showsBackupImporter = true
                    } label: {
                        Label("恢复备份", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isManagingBackup)

                    Divider()

                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Label("清空全部", systemImage: "trash")
                    }
                    .disabled(store.entries.isEmpty)
                } label: {
                    if isCheckingUpdates || isManagingBackup {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityLabel("管理本地保存")
                .accessibilityIdentifier("saved-threads-management")
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if $0 == false { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("本地保存", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if $0 == false { resultMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
        .confirmationDialog(
            "如何恢复这份备份？",
            isPresented: $showsImportOptions,
            titleVisibility: .visible
        ) {
            Button("合并到现有保存") { applyPendingImport(replacingExisting: false) }
            Button("替换现有保存", role: .destructive) {
                applyPendingImport(replacingExisting: true)
            }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: {
            Text("备份不包含账号登录状态。合并时，同一帖子保留保存时间较新的版本。")
        }
        .confirmationDialog(
            "清空全部本地保存？",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("清空全部", role: .destructive, action: clearAll)
            Button("取消", role: .cancel) {}
        } message: {
            Text("帖子快照和离线媒体都会从这台设备删除。")
        }
        .fileExporter(
            isPresented: $showsBackupExporter,
            document: backupDocument,
            contentType: .tiebaPureBackup,
            defaultFilename: "TiebaPure-本地保存"
        ) { result in
            backupDocument = nil
            if case let .failure(error) = result {
                errorMessage = error.localizedDescription
            } else {
                resultMessage = "备份已导出。"
            }
        }
        .fileImporter(
            isPresented: $showsBackupImporter,
            allowedContentTypes: [.tiebaPureBackup],
            allowsMultipleSelection: false,
            onCompletion: handleBackupImport
        )
        .task {
            refreshStorageUsage()
            if shouldAutomaticallyCheckUpdates {
                await checkAllUpdates(showsResult: false)
            }
        }
        .fullScreenInteractiveNavigationPop()
    }

    private func remove(_ threadID: Int64) {
        Task {
            do {
                try await store.removeWithoutBlocking(threadID: threadID)
                refreshStorageUsage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var formattedStorageByteCount: String {
        ByteCountFormatter.string(fromByteCount: storageByteCount, countStyle: .file)
    }

    private var shouldAutomaticallyCheckUpdates: Bool {
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        return store.entries.contains { ($0.latestCheckedAt ?? .distantPast) < cutoff }
    }

    @MainActor
    private func checkAllUpdates(showsResult: Bool) async {
        guard isCheckingUpdates == false, store.entries.isEmpty == false else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let service = SavedThreadUpdateService(api: environment.api)
        var updatedCount = 0
        var failedCount = 0
        var latestReplyCounts: [Int64: Int] = [:]
        let snapshots = store.entries
        for snapshot in snapshots {
            do {
                let latest = try await service.latestReplyCount(snapshot: snapshot, account: account)
                latestReplyCounts[snapshot.id] = latest
                if latest > snapshot.thread.replyCount { updatedCount += 1 }
            } catch is CancellationError {
                return
            } catch {
                failedCount += 1
            }
        }
        do {
            try await store.recordUpdateChecksWithoutBlocking(latestReplyCounts)
        } catch is CancellationError {
            return
        } catch {
            if showsResult {
                errorMessage = "检查已完成，但保存检查结果失败：\(error.localizedDescription)"
            }
            return
        }
        if showsResult {
            resultMessage = failedCount == 0
                ? "检查完成，\(updatedCount)个帖子有新回复。"
                : "检查完成，\(updatedCount)个帖子有新回复，\(failedCount)个检查失败。"
        }
    }

    private func exportBackup() {
        guard isManagingBackup == false else { return }
        isManagingBackup = true
        let snapshots = store.entries
        let mediaStore = store.mediaStore
        Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try SavedThreadBackupDocument(
                        snapshots: snapshots,
                        mediaStore: mediaStore
                    )
                }.value
                backupDocument = document
                showsBackupExporter = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isManagingBackup = false
        }
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard isManagingBackup == false else { return }
            isManagingBackup = true
            Task {
                do {
                    pendingImport = try await Task.detached(priority: .userInitiated) {
                        try SavedThreadBackupDocument.load(from: url)
                    }.value
                    showsImportOptions = true
                } catch {
                    errorMessage = error.localizedDescription
                }
                isManagingBackup = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyPendingImport(replacingExisting: Bool) {
        guard let pendingImport, isManagingBackup == false else { return }
        isManagingBackup = true
        Task {
            do {
                try await store.importBackupWithoutBlocking(
                    snapshots: pendingImport.snapshots,
                    mediaFiles: pendingImport.mediaFiles,
                    replacingExisting: replacingExisting
                )
                self.pendingImport = nil
                refreshStorageUsage()
                resultMessage = "备份处理完成，共读取\(pendingImport.snapshots.count)个帖子。"
            } catch {
                errorMessage = error.localizedDescription
            }
            isManagingBackup = false
        }
    }

    private func clearAll() {
        Task {
            do {
                try await store.clearWithoutBlocking()
                refreshStorageUsage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshStorageUsage() {
        storageRefreshGeneration &+= 1
        let generation = storageRefreshGeneration
        let mediaStore = store.mediaStore
        Task {
            let byteCount = await Task.detached(priority: .utility) {
                mediaStore.storageByteCount()
            }.value
            guard generation == storageRefreshGeneration else { return }
            storageByteCount = byteCount
        }
    }
}

private struct SavedThreadDetailDestination: View {
    let snapshot: SavedThreadSnapshot
    let mediaStore: SavedThreadMediaStore
    @State private var resolvedSnapshot: SavedThreadSnapshot?

    var body: some View {
        Group {
            if let resolvedSnapshot {
                SavedThreadDetailView(snapshot: resolvedSnapshot)
            } else {
                ProgressView("正在读取本地帖子")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TiebaPureTheme.ColorToken.readerGroupedBackground)
            }
        }
        .task {
            let value = await Task.detached(priority: .userInitiated) {
                mediaStore.resolvedSnapshot(snapshot)
            }.value
            guard Task.isCancelled == false else { return }
            resolvedSnapshot = value
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

            HStack(spacing: TiebaPureTheme.Spacing.xs) {
                Label(snapshot.effectiveMediaMode.title, systemImage: mediaSystemImage)
                if snapshot.newReplyCount > 0 {
                    Text("新增 \(snapshot.newReplyCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TiebaPureTheme.ColorToken.primaryAccent, in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, TiebaPureTheme.Spacing.xxs)
    }

    private var mediaSystemImage: String {
        switch snapshot.effectiveMediaMode {
        case .textOnly: return "doc.text"
        case .images: return "photo.on.rectangle"
        case .complete: return "internaldrive.fill"
        }
    }
}

struct SavedThreadDetailView: View {
    @Environment(\.readingPreferences) private var readingPreferences
    let snapshot: SavedThreadSnapshot
    @State private var selectedPost: SavedThreadPost?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Label(savedStatusText, systemImage: "internaldrive")
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
        .environment(\.readingPreferences, offlineReadingPreferences)
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

    private var savedStatusText: String {
        let time = snapshot.savedAt.formatted(date: .abbreviated, time: .shortened)
        let update = snapshot.newReplyCount > 0 ? "；线上新增\(snapshot.newReplyCount)条回复" : ""
        switch snapshot.effectiveMediaMode {
        case .textOnly:
            return "保存于 \(time)；媒体需联网加载\(update)"
        case .images:
            return "保存于 \(time)；图片已离线，视频和语音未离线\(update)"
        case .complete:
            return "保存于 \(time)；正文和媒体均已离线\(update)"
        }
    }

    private var offlineReadingPreferences: ReadingPreferences {
        guard snapshot.effectiveMediaMode != .textOnly else { return readingPreferences }
        var preferences = readingPreferences
        preferences.mediaLoading = .automatic
        return preferences
    }
}

private extension UTType {
    static let tiebaPureBackup = UTType(
        exportedAs: "dev.infinityf4p.tiebapure.saved-threads-backup",
        conformingTo: .package
    )
}

struct SavedThreadBackupDocument: FileDocument {
    private struct Manifest: Codable {
        static let currentFormatVersion = 1
        var formatVersion: Int
        var exportedAt: Date
        var snapshots: [SavedThreadSnapshot]
    }

    static var readableContentTypes: [UTType] { [.tiebaPureBackup] }

    let snapshots: [SavedThreadSnapshot]
    let mediaFiles: [Int64: [String: Data]]

    init(snapshots: [SavedThreadSnapshot], mediaStore: SavedThreadMediaStore) throws {
        self.snapshots = try snapshots.map { try $0.validated() }
        let manifestByteCount = try Self.encodedManifest(
            snapshots: self.snapshots,
            exportedAt: Date()
        ).count
        guard manifestByteCount < SavedThreadPolicy.maximumBackupBytes else {
            throw SavedThreadError.backupStorageLimitExceeded
        }
        var files: [Int64: [String: Data]] = [:]
        var remainingBytes = SavedThreadPolicy.maximumBackupBytes - manifestByteCount
        for snapshot in self.snapshots {
            let threadFiles = try mediaStore.backupFiles(
                for: snapshot,
                maximumTotalByteCount: remainingBytes
            )
            remainingBytes -= threadFiles.values.reduce(0) { $0 + $1.count }
            files[snapshot.id] = threadFiles
        }
        guard 2 + self.snapshots.count + files.values.reduce(0, { $0 + $1.count })
            <= SavedThreadPolicy.maximumBackupEntries else {
            throw SavedThreadError.invalidBackup
        }
        mediaFiles = files
    }

    init(fileWrapper: FileWrapper) throws {
        guard Self.hasAllowedEntryCount(fileWrapper),
              fileWrapper.isDirectory,
              let root = fileWrapper.fileWrappers,
              Set(root.keys) == ["manifest.json", "Media"],
              let manifestWrapper = root["manifest.json"],
              manifestWrapper.isRegularFile,
              manifestWrapper.isSymbolicLink == false,
              let manifestData = manifestWrapper.regularFileContents,
              manifestData.count <= SavedThreadPolicy.maximumStorageByteCount else {
            throw SavedThreadError.invalidBackup
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.formatVersion == Manifest.currentFormatVersion,
              manifest.snapshots.count <= SavedThreadPolicy.maximumSavedThreads else {
            throw SavedThreadError.invalidBackup
        }
        snapshots = try manifest.snapshots.map { try $0.validated() }

        let snapshotIDs = snapshots.map(\.id)
        guard Set(snapshotIDs).count == snapshotIDs.count,
              let mediaWrapper = root["Media"],
              mediaWrapper.isDirectory,
              mediaWrapper.isSymbolicLink == false,
              let mediaRoot = mediaWrapper.fileWrappers,
              Set(mediaRoot.keys) == Set(snapshotIDs.map(String.init)) else {
            throw SavedThreadError.invalidBackup
        }

        var files: [Int64: [String: Data]] = [:]
        var totalBytes = manifestData.count
        for snapshot in snapshots {
            let expectedNames = Set(snapshot.effectiveMediaAssets.map(\.fileName))
            guard let threadWrapper = mediaRoot[String(snapshot.id)],
                  threadWrapper.isDirectory,
                  threadWrapper.isSymbolicLink == false,
                  let threadRoot = threadWrapper.fileWrappers,
                  Set(threadRoot.keys) == expectedNames else {
                throw SavedThreadError.invalidBackup
            }
            var threadFiles: [String: Data] = [:]
            for name in expectedNames {
                guard let wrapper = threadRoot[name],
                      wrapper.isRegularFile,
                      wrapper.isSymbolicLink == false,
                      let data = wrapper.regularFileContents else {
                    throw SavedThreadError.invalidBackup
                }
                totalBytes += data.count
                guard totalBytes <= SavedThreadPolicy.maximumBackupBytes else {
                    throw SavedThreadError.backupStorageLimitExceeded
                }
                threadFiles[name] = data
            }
            files[snapshot.id] = threadFiles
        }
        mediaFiles = files
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    static func load(from url: URL, fileManager: FileManager = .default) throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SavedThreadError.invalidBackup
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: []
        ) else {
            throw SavedThreadError.invalidBackup
        }
        var totalBytes = 0
        var entryCount = 0
        for case let child as URL in enumerator {
            entryCount += 1
            guard entryCount <= SavedThreadPolicy.maximumBackupEntries else {
                throw SavedThreadError.invalidBackup
            }
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw SavedThreadError.invalidBackup
            }
            if values.isRegularFile == true {
                totalBytes += values.fileSize ?? 0
                guard totalBytes <= SavedThreadPolicy.maximumBackupBytes else {
                    throw SavedThreadError.backupStorageLimitExceeded
                }
            }
        }
        return try Self(fileWrapper: FileWrapper(url: url, options: [.immediate]))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let manifest = Manifest(
            formatVersion: Manifest.currentFormatVersion,
            exportedAt: Date(),
            snapshots: snapshots
        )
        let manifestData = try Self.encodedManifest(manifest)
        let mediaByteCount = mediaFiles.values.reduce(0) { partial, files in
            partial + files.values.reduce(0) { $0 + $1.count }
        }
        let entryCount = 2 + snapshots.count
            + mediaFiles.values.reduce(0) { $0 + $1.count }
        guard entryCount <= SavedThreadPolicy.maximumBackupEntries,
              manifestData.count + mediaByteCount <= SavedThreadPolicy.maximumBackupBytes else {
            throw SavedThreadError.backupStorageLimitExceeded
        }
        let manifestWrapper = FileWrapper(regularFileWithContents: manifestData)
        manifestWrapper.preferredFilename = "manifest.json"

        var threadWrappers: [String: FileWrapper] = [:]
        for snapshot in snapshots {
            var fileWrappers: [String: FileWrapper] = [:]
            for (name, data) in mediaFiles[snapshot.id] ?? [:] {
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = name
                fileWrappers[name] = wrapper
            }
            let wrapper = FileWrapper(directoryWithFileWrappers: fileWrappers)
            wrapper.preferredFilename = String(snapshot.id)
            threadWrappers[String(snapshot.id)] = wrapper
        }
        let mediaWrapper = FileWrapper(directoryWithFileWrappers: threadWrappers)
        mediaWrapper.preferredFilename = "Media"
        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": manifestWrapper,
            "Media": mediaWrapper
        ])
    }

    private static func encodedManifest(
        snapshots: [SavedThreadSnapshot],
        exportedAt: Date
    ) throws -> Data {
        try encodedManifest(Manifest(
            formatVersion: Manifest.currentFormatVersion,
            exportedAt: exportedAt,
            snapshots: snapshots
        ))
    }

    private static func encodedManifest(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private static func hasAllowedEntryCount(_ root: FileWrapper) -> Bool {
        var stack = [root]
        var count = 0
        while let current = stack.popLast() {
            guard current.isDirectory else { continue }
            guard let children = current.fileWrappers?.values else { return false }
            for child in children {
                count += 1
                guard count <= SavedThreadPolicy.maximumBackupEntries else { return false }
                stack.append(child)
            }
        }
        return true
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
                        readerFontFamily: readingPreferences.fontFamily,
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
