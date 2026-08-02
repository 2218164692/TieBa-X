import SwiftUI

struct ReadingSettingsView: View {
    @EnvironmentObject private var store: ReadingPreferencesStore

    var body: some View {
        Form {
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
    }

    private var fontSizeSelection: Binding<ReaderFontSize> {
        Binding(
            get: { store.preferences.fontSize },
            set: { store.select(fontSize: $0) }
        )
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
