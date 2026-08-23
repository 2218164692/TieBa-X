import SwiftUI
import UniformTypeIdentifiers

struct ReadingSettingsView: View {
    @EnvironmentObject private var store: ReadingPreferencesStore
    @EnvironmentObject private var fontStore: ReaderFontStore
    @State private var showsFontImporter = false
    @State private var pendingFontDeletion: ImportedReaderFont?
    @State private var fontErrorMessage: String?
    @State private var isImportingFont = false

    var body: some View {
        Form {
            Section {
                Picker("字体", selection: fontFamilySelection) {
                    ForEach(ReaderFontFamily.builtInChoices) { family in
                        Text(family.title).tag(family)
                    }
                    ForEach(fontStore.entries) { font in
                        if let family = font.family {
                            Text(font.displayName).tag(family)
                        }
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("reading-font-family-picker")

                Button {
                    showsFontImporter = true
                } label: {
                    if isImportingFont {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在导入")
                        }
                    } else {
                        Label("导入字体", systemImage: "doc.badge.plus")
                    }
                }
                .disabled(isImportingFont || fontStore.isReady == false)
                .accessibilityIdentifier("reading-font-import-button")

                ForEach(fontStore.entries) { font in
                    HStack(spacing: TiebaPureTheme.Spacing.sm) {
                        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
                            Text(font.displayName)
                                .lineLimit(1)
                            Text(font.postScriptName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: TiebaPureTheme.Spacing.sm)
                        Button(role: .destructive) {
                            pendingFontDeletion = font
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除字体\(font.displayName)")
                    }
                }
            } header: {
                Text("字体")
            } footer: {
                Text("支持 TTF 和 OTF，单个文件不超过 20 MB，最多导入 20 个。字体只保存在本机应用私有目录。")
            }

            Section {
                Picker("字号", selection: fontSizeSelection) {
                    ForEach(ReaderFontSize.allCases) { size in
                        Text(size.shortTitle)
                            .tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reading-font-size-picker")

                Picker("正文间距", selection: lineSpacingSelection) {
                    ForEach(ReaderLineSpacing.allCases) { spacing in
                        Text(spacing.title)
                            .tag(spacing)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reading-line-spacing-picker")

                InlineContentText(
                    blocks: [.text("阅读设置会应用到主贴、楼层回复和楼中楼正文。")],
                    style: .body,
                    lineLimit: ThreadContentDisplayPolicy.detailLineLimit,
                    readerFontSize: store.preferences.fontSize,
                    readerFontFamily: store.preferences.fontFamily,
                    readerLineSpacing: store.preferences.lineSpacing,
                    allowsLinkInteraction: false,
                    accessibilityIdentifier: "reading-typography-preview"
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, TiebaPureTheme.Spacing.xs)
            } header: {
                Text("正文")
            } footer: {
                Text("系统大字体仍会继续生效；首页和吧页的帖子摘要保持紧凑显示。")
            }

            Section {
                Picker("帖子回复默认排序", selection: replySortSelection) {
                    ForEach(ThreadReplySort.allCases) { sort in
                        Text(sort.title)
                            .tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reading-reply-sort-picker")
            } header: {
                Text("回复")
            } footer: {
                Text("只影响新打开的帖子；恢复上次阅读位置时会使用正序定位。")
            }

            Section {
                Picker("媒体加载", selection: mediaLoadingSelection) {
                    ForEach(ReaderMediaLoadingPolicy.allCases) { policy in
                        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
                            Text(policy.title)
                            Text(policy.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(policy)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("reading-media-loading-picker")
            } header: {
                Text("图片与视频")
            } footer: {
                Text("此设置只影响帖子媒体和视频封面，不影响头像、贴吧图标或表情。")
            }

            Section {
                Button("恢复默认设置", role: .destructive) {
                    store.reset()
                }
                .disabled(store.preferences == .default)
                .accessibilityIdentifier("reading-settings-reset")
            }
        }
        .navigationTitle("阅读设置")
        .fullScreenInteractiveNavigationPop()
        .fileImporter(
            isPresented: $showsFontImporter,
            allowedContentTypes: [.font],
            allowsMultipleSelection: false,
            onCompletion: handleFontImport
        )
        .confirmationDialog(
            "删除这个字体？",
            isPresented: Binding(
                get: { pendingFontDeletion != nil },
                set: { if $0 == false { pendingFontDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingFontDeletion {
                Button("删除字体", role: .destructive) {
                    removeFont(pendingFontDeletion)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后使用这个字体的阅读设置会恢复为系统默认。")
        }
        .alert("字体操作失败", isPresented: Binding(
            get: { fontErrorMessage != nil },
            set: { if $0 == false { fontErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fontErrorMessage ?? "")
        }
    }

    private var fontSizeSelection: Binding<ReaderFontSize> {
        Binding(
            get: { store.preferences.fontSize },
            set: { store.select(fontSize: $0) }
        )
    }

    private var fontFamilySelection: Binding<ReaderFontFamily> {
        Binding(
            get: { store.preferences.fontFamily },
            set: { store.select(fontFamily: $0) }
        )
    }

    private func handleFontImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard isImportingFont == false else { return }
            isImportingFont = true
            Task {
                do {
                    let imported = try await fontStore.importFont(from: url)
                    guard let family = imported.family else {
                        throw ReaderFontStoreError.invalidFont
                    }
                    store.select(fontFamily: family)
                } catch {
                    fontErrorMessage = error.localizedDescription
                }
                isImportingFont = false
            }
        } catch {
            fontErrorMessage = error.localizedDescription
        }
    }

    private func removeFont(_ font: ImportedReaderFont) {
        do {
            let wasSelected = store.preferences.fontFamily == font.family
            try fontStore.remove(font)
            if wasSelected { store.select(fontFamily: .system) }
            pendingFontDeletion = nil
        } catch {
            fontErrorMessage = error.localizedDescription
        }
    }

    private var lineSpacingSelection: Binding<ReaderLineSpacing> {
        Binding(
            get: { store.preferences.lineSpacing },
            set: { store.select(lineSpacing: $0) }
        )
    }

    private var replySortSelection: Binding<ThreadReplySort> {
        Binding(
            get: { store.preferences.defaultReplySort },
            set: { store.select(defaultReplySort: $0) }
        )
    }

    private var mediaLoadingSelection: Binding<ReaderMediaLoadingPolicy> {
        Binding(
            get: { store.preferences.mediaLoading },
            set: { store.select(mediaLoading: $0) }
        )
    }
}
