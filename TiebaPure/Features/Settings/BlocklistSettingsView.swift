import SwiftUI

struct BlocklistSettingsView: View {
    @ObservedObject private var store = BlocklistStore.shared

    @State private var keywordInput = ""
    @State private var userInput = ""
    @State private var forumInput = ""
    @State private var clearTarget: BlocklistEntryKind?

    var body: some View {
        Form {
            blockSection(
                kind: .keyword,
                header: "关键词",
                footer: "标题或内容包含关键词的帖子和楼层会被隐藏，不区分大小写。",
                prompt: "添加关键词",
                emptyText: "暂无屏蔽关键词",
                input: $keywordInput,
                add: { store.addKeyword($0) }
            )

            blockSection(
                kind: .user,
                header: "用户",
                footer: "可直接输入用户名；在用户主页中屏蔽可精确匹配账号。",
                prompt: "添加用户名",
                emptyText: "暂无屏蔽用户",
                input: $userInput,
                add: { store.addUser(id: nil, displayName: $0) }
            )

            blockSection(
                kind: .forum,
                header: "吧",
                footer: "填写吧名，无需带“吧”字后缀。",
                prompt: "添加吧名",
                emptyText: "暂无屏蔽的吧",
                input: $forumInput,
                add: { store.addForum(named: $0) }
            )
        }
        .navigationTitle("屏蔽设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "清空\(clearTarget.map(header(for:)) ?? "")屏蔽？",
            isPresented: clearConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                if let clearTarget {
                    store.clear(kind: clearTarget)
                }
                clearTarget = nil
            }
            Button("取消", role: .cancel) {
                clearTarget = nil
            }
        } message: {
            Text("此操作只会删除本机保存的屏蔽规则。")
        }
        .fullScreenInteractiveNavigationPop()
    }

    private func blockSection(
        kind: BlocklistEntryKind,
        header: String,
        footer: String,
        prompt: String,
        emptyText: String,
        input: Binding<String>,
        add: @escaping (String) -> Void
    ) -> some View {
        Section {
            HStack(spacing: TiebaPureTheme.Spacing.sm) {
                TextField(prompt, text: input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { submit(input: input, add: add) }
                    .accessibilityIdentifier("blocklist-\(kind.rawValue)-field")

                Button("添加") {
                    submit(input: input, add: add)
                }
                .disabled(trimmed(input.wrappedValue).isEmpty)
                .accessibilityLabel("添加\(header)屏蔽")
                .accessibilityIdentifier("blocklist-\(kind.rawValue)-add")
            }

            let entries = store.entries(of: kind)
            if entries.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("blocklist-\(kind.rawValue)-empty")
            } else {
                ForEach(entries) { entry in
                    entryRow(entry)
                }
                .onDelete { offsets in
                    store.remove(ids: Set(offsets.compactMap { index in
                        entries.indices.contains(index) ? entries[index].id : nil
                    }))
                }

                Button("清空", role: .destructive) {
                    clearTarget = kind
                }
                .accessibilityLabel("清空全部\(header)屏蔽")
                .accessibilityIdentifier("blocklist-\(kind.rawValue)-clear")
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }

    private func entryRow(_ entry: BlocklistEntry) -> some View {
        HStack(spacing: TiebaPureTheme.Spacing.sm) {
            Text(entry.value)
                .foregroundStyle(.primary)

            if entry.kind == .user, let userID = entry.userID {
                Spacer(minLength: TiebaPureTheme.Spacing.sm)

                Text("UID \(userID)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("blocklist-row-\(entry.id)")
    }

    private var clearConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { clearTarget != nil },
            set: { isPresented in
                if isPresented == false {
                    clearTarget = nil
                }
            }
        )
    }

    private func header(for kind: BlocklistEntryKind) -> String {
        switch kind {
        case .keyword:
            return "关键词"
        case .user:
            return "用户"
        case .forum:
            return "吧"
        }
    }

    private func submit(input: Binding<String>, add: (String) -> Void) {
        let value = trimmed(input.wrappedValue)
        guard value.isEmpty == false else { return }
        add(value)
        input.wrappedValue = ""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
