import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appearanceStore: AppAppearanceStore
    @EnvironmentObject private var contentSubmissionSettingsStore: ContentSubmissionSettingsStore
    @Environment(\.colorScheme) private var effectiveColorScheme
    let account: Account?

    @State private var confirmsLogout = false
    @State private var isLoggingOut = false
    @State private var logoutErrorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("显示模式", selection: appearanceSelection) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.systemImage)
                            .tag(appearance)
                            .accessibilityIdentifier("appearance-option-\(appearance.rawValue)")
                    }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("appearance-picker")

                HStack(spacing: TiebaPureTheme.Spacing.sm) {
                    Label("当前显示", systemImage: "display")

                    Spacer(minLength: TiebaPureTheme.Spacing.sm)

                    Text(effectiveColorScheme == .dark ? "深色" : "浅色")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("当前显示为\(effectiveColorScheme == .dark ? "深色" : "浅色")")
                .accessibilityIdentifier("appearance-effective-mode")
            } header: {
                Text("外观")
            } footer: {
                Text("选择后会立即应用；跟随系统会随 iPhone 的外观设置自动切换。")
            }

            Section {
                Toggle(isOn: newThreadsEnabledSelection) {
                    Label("允许发帖", systemImage: "square.and.pencil")
                }
                .accessibilityHint("关闭后不能发布新主题")
                .accessibilityIdentifier("settings-new-threads-enabled-toggle")

                Toggle(isOn: repliesEnabledSelection) {
                    Label("允许回帖", systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityHint("开启后可以回复帖子、楼层和楼中楼")
                .accessibilityIdentifier("settings-replies-enabled-toggle")

                Toggle(isOn: likesEnabledSelection) {
                    Label("允许点赞", systemImage: "hand.thumbsup")
                }
                .accessibilityHint("关闭后仍会显示点赞数量，但不能点赞或取消点赞")
                .accessibilityIdentifier("settings-likes-enabled-toggle")

                NavigationLink {
                    ReadingSettingsView()
                } label: {
                    Label("阅读设置", systemImage: "textformat.size")
                }
                .accessibilityHint("调整帖子正文、回复排序和媒体加载方式")
                .accessibilityIdentifier("settings-reading-entry")

                NavigationLink {
                    BlocklistSettingsView()
                } label: {
                    Label("屏蔽设置", systemImage: "hand.raised")
                }
                .accessibilityHint("管理本机保存的关键词、用户和吧屏蔽")
                .accessibilityIdentifier("settings-blocklist-entry")
            } header: {
                Text("内容")
            } footer: {
                Text("发帖和点赞默认开启，回帖默认关闭。关闭点赞后仍会显示点赞数量；尚未确认过发布风险时，首次发帖或回帖会显示非官方接口说明。设置和屏蔽规则仅保存在本机。")
            }

            if let account {
                Section("账号") {
                    HStack(spacing: TiebaPureTheme.Spacing.sm) {
                        AvatarView(
                            url: account.portraitURL,
                            title: account.displayName,
                            size: TiebaPureTheme.AvatarSize.large
                        )

                        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
                            Text(account.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)

                            if account.name != account.displayName {
                                Text(account.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Text("UID \(account.uid)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, TiebaPureTheme.Spacing.xs)
                }

                Section {
                    Button(role: .destructive) {
                        confirmsLogout = true
                    } label: {
                        HStack(spacing: TiebaPureTheme.Spacing.sm) {
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")

                            Spacer(minLength: TiebaPureTheme.Spacing.sm)

                            if isLoggingOut {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isLoggingOut)
                    .accessibilityHint("清除本机保存的百度登录状态")
                }
            }
        }
        .navigationTitle("设置")
        .confirmationDialog(
            "退出登录？",
            isPresented: $confirmsLogout,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                Task { await logOut() }
            }

            Button("取消", role: .cancel) {}
        } message: {
            Text("这会清除本机保存的百度登录状态。")
        }
        .alert(
            "退出失败",
            isPresented: Binding(
                get: { logoutErrorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        logoutErrorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            if let logoutErrorMessage {
                Text(logoutErrorMessage)
            }
        }
        .fullScreenInteractiveNavigationPop()
    }

    private var appearanceSelection: Binding<AppAppearance> {
        Binding(
            get: { appearanceStore.selection },
            set: { appearanceStore.select($0) }
        )
    }

    private var repliesEnabledSelection: Binding<Bool> {
        Binding(
            get: { contentSubmissionSettingsStore.repliesEnabled },
            set: { contentSubmissionSettingsStore.setRepliesEnabled($0) }
        )
    }

    private var newThreadsEnabledSelection: Binding<Bool> {
        Binding(
            get: { contentSubmissionSettingsStore.newThreadsEnabled },
            set: { contentSubmissionSettingsStore.setNewThreadsEnabled($0) }
        )
    }

    private var likesEnabledSelection: Binding<Bool> {
        Binding(
            get: { contentSubmissionSettingsStore.likesEnabled },
            set: { contentSubmissionSettingsStore.setLikesEnabled($0) }
        )
    }

    private func logOut() async {
        isLoggingOut = true
        defer { isLoggingOut = false }

        do {
            try await environment.logoutCoordinator.logOut()
        } catch {
            logoutErrorMessage = ReaderErrorMessage.message(for: error)
        }
    }
}
