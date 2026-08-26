import SwiftUI

struct FollowedUsersView: View {
    let account: Account
    private let openUserInParent: ((UserSummary) -> Void)?

    init(
        account: Account,
        openUserInParent: ((UserSummary) -> Void)? = nil
    ) {
        self.account = account
        self.openUserInParent = openUserInParent
    }

    var body: some View {
        UserRelationshipsView(
            account: account,
            user: UserSummary(
                id: Int64(account.uid) ?? 0,
                name: account.name,
                displayName: account.displayName,
                portrait: account.portrait
            ),
            kind: .following,
            navigationTitle: "关注的用户",
            openUserInParent: openUserInParent
        )
    }
}

struct UserRelationshipsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var blocklistStore = BlocklistStore.shared

    let account: Account?
    let user: UserSummary
    let kind: UserRelationshipKind
    let navigationTitle: String
    private let openUserInParent: ((UserSummary) -> Void)?

    @State private var users: [UserSummary] = []
    @State private var nextPage = 1
    @State private var totalCount = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var requestGeneration = 0
    @State private var loadTask: Task<UserRelationshipPage, Error>?
    @State private var selectedUser: UserSummary?
    @State private var navigationSourceLifecycle = NavigationSourceLifecycleState()

    init(
        account: Account?,
        user: UserSummary,
        kind: UserRelationshipKind,
        navigationTitle: String? = nil,
        openUserInParent: ((UserSummary) -> Void)? = nil
    ) {
        self.account = account
        self.user = user
        self.kind = kind
        self.navigationTitle = navigationTitle ?? kind.navigationTitle
        self.openUserInParent = openUserInParent
    }

    var body: some View {
        Group {
            if isLoading, didLoad == false {
                ReaderStateView.loading(loadingText)
            } else if let errorMessage, users.isEmpty {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload() }
                    }
                }
            } else if users.isEmpty {
                ReaderStateScrollView(refresh: { await reload() }) {
                    ReaderStateView.empty(
                        title: emptyTitle,
                        message: emptyMessage,
                        actionTitle: hasMore && didLoad ? "继续加载" : nil,
                        action: hasMore && didLoad ? { Task { await loadMore() } } : nil
                    )
                }
            } else {
                List {
                    ForEach(users, id: \.self) { relationshipUser in
                        Button {
                            openUser(relationshipUser)
                        } label: {
                            UserRelationshipRow(user: relationshipUser)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(rowIdentifier(relationshipUser))
                        .onAppear {
                            guard let index = users.firstIndex(of: relationshipUser),
                                  PaginationPrefetchPolicy.shouldLoadMore(
                                    currentIndex: index,
                                    totalCount: users.count
                                  ) else { return }
                            Task { await loadMore() }
                        }
                    }

                    if isLoading, didLoad {
                        HStack {
                            Spacer()
                            ProgressView()
                                .accessibilityLabel("正在加载更多\(kind.navigationTitle)")
                            Spacer()
                        }
                        .tieBaListRowSeparatorHidden()
                    }

                    if let errorMessage {
                        InlineLoadErrorView(message: errorMessage) {
                            Task { await loadMore() }
                        }
                        .tieBaListRowSeparatorHidden()
                    } else if hasMore, isLoading == false, didLoad {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            Label("加载更多\(kind.navigationTitle)", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .tieBaButtonStyle(.bordered)
                        .minTouchTarget()
                        .tieBaListRowSeparatorHidden()
                        .accessibilityIdentifier("user-relationships-load-more")
                    } else if hasMore == false, totalCount > 0 {
                        Text("已显示 \(users.count) 位用户")
                            .font(.footnote)
                            .tieBaForegroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .tieBaListRowSeparatorHidden()
                            .accessibilityLabel("已显示\(users.count)位用户")
                    }
                }
                .listStyle(.plain)
                .shortPullRefresh(
                    isEnabled: didLoad && isLoading == false,
                    surface: .plain,
                    accessibilityIdentifier: "user-relationships-refresh-animation"
                ) {
                    await reload()
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Use the same stable push path for users opened from a relationship list.
        .background(userNavigationLink)
        .tieBaTask {
            guard didLoad == false else { return }
            await reload()
        }
        .onChange(of: blocklistStore.entries) { _ in
            users.removeAll { TiebaContentFilter.shouldKeep(user: $0) == false }
        }
        .onReceive(environment.socialRelationshipState.userFollowDidChange) { change in
            apply(change)
        }
        .onReceive(environment.accountStore.accountDidChange) { currentAccount in
            guard currentAccount?.sessionIdentity != account?.sessionIdentity else { return }
            cancelRequests()
            users = []
            selectedUser = nil
            presentationMode.wrappedValue.dismiss()
        }
        .onAppear { navigationSourceLifecycle.didAppear() }
        .onDisappear {
            guard navigationSourceLifecycle.shouldTearDown(
                isPresentingLocalDestination: selectedUser != nil
            ) else { return }
            cancelRequests()
        }
        .accessibilityIdentifier(kind == .following ? "followed-users-screen" : "followers-screen")
        .fullScreenInteractiveNavigationPop()
    }

    private var userNavigationLink: some View {
        NavigationLink(
            destination: userDestination,
            isActive: selectedUserIsActive
        ) {
            EmptyView()
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var userDestination: some View {
        if let selectedUser {
            UserProfileView(account: account, user: selectedUser)
                .interactiveNavigationPopStateSync {
                    self.selectedUser = nil
                }
        } else {
            EmptyView()
        }
    }

    private func openUser(_ user: UserSummary) {
        if let openUserInParent {
            navigationSourceLifecycle.beginParentNavigation()
            openUserInParent(user)
        } else {
            selectedUser = user
        }
    }

    private var loadingText: String {
        kind == .following ? "正在加载关注用户" : "正在加载粉丝"
    }

    private var emptyTitle: String {
        kind == .following ? "暂无关注用户" : "暂无粉丝"
    }

    private var emptyMessage: String {
        kind == .following ? "这里还没有可显示的关注用户。" : "这里还没有可显示的粉丝。"
    }

    private func reload() async {
        loadTask?.cancel()
        requestGeneration += 1
        isLoading = false
        nextPage = 1
        hasMore = true
        errorMessage = nil
        await loadMore(generation: requestGeneration, replacing: true)
    }

    private func loadMore() async {
        await loadMore(generation: requestGeneration, replacing: false)
    }

    private func loadMore(
        generation: Int,
        replacing: Bool,
        consecutiveHiddenPageCount: Int = 0
    ) async {
        guard user.id > 0 else {
            errorMessage = TiebaMutationError.invalidUserID.description
            didLoad = true
            return
        }
        guard isLoading == false, hasMore || replacing else { return }
        let requestedPage = replacing ? 1 : nextPage
        let requestedSession = account?.sessionIdentity
        isLoading = true
        errorMessage = nil
        var continuation: LocallyFilteredPaginationDecision?

        do {
            let task = Task {
                try await environment.api.userRelationships(
                    account: account,
                    userID: user.id,
                    kind: kind,
                    page: requestedPage
                )
            }
            loadTask = task
            let page = try await task.value
            guard generation == requestGeneration,
                  requestedSession == account?.sessionIdentity else { return }
            let reconciledUsers: [UserSummary]
            if let account, kind == .following, isCurrentAccountProfile {
                for relationshipUser in page.users {
                    environment.socialRelationshipState.seedUserFollow(
                        accountID: account.id,
                        user: relationshipUser,
                        isFollowed: true
                    )
                }
                reconciledUsers = environment.socialRelationshipState.reconciledFollowingUsers(
                    accountID: account.id,
                    loaded: page.users
                )
            } else if let account, kind == .followers {
                reconciledUsers = environment.socialRelationshipState.reconciledFollowers(
                    accountID: account.id,
                    viewedUser: user,
                    currentUser: currentAccountUser,
                    loaded: page.users
                )
            } else {
                reconciledUsers = page.users
            }
            let visibleUsers = reconciledUsers.filter(TiebaContentFilter.shouldKeep(user:))
            if replacing {
                users = deduplicated(visibleUsers)
            } else {
                users = deduplicated(users + visibleUsers)
            }
            totalCount = page.totalCount
            hasMore = page.hasMore
            nextPage = max(page.currentPage, requestedPage) + 1
            continuation = LocallyFilteredPaginationPolicy.decision(
                visibleItemCount: visibleUsers.count,
                serverHasMore: hasMore,
                consecutiveHiddenPageCount: consecutiveHiddenPageCount
            )
        } catch is CancellationError {
            guard generation == requestGeneration,
                  requestedSession == account?.sessionIdentity else { return }
            loadTask = nil
            isLoading = false
            return
        } catch {
            guard generation == requestGeneration,
                  requestedSession == account?.sessionIdentity else { return }
            errorMessage = ReaderErrorMessage.message(for: error)
        }

        guard generation == requestGeneration,
              requestedSession == account?.sessionIdentity else { return }
        loadTask = nil
        isLoading = false
        didLoad = true
        if let continuation, continuation.shouldAutomaticallyLoadNextPage {
            await loadMore(
                generation: generation,
                replacing: false,
                consecutiveHiddenPageCount: continuation.consecutiveHiddenPageCount
            )
        }
    }

    private func apply(_ change: UserFollowChange) {
        guard change.accountID == account?.id else { return }
        if kind == .following, isCurrentAccountProfile {
            let alreadyPresent = users.contains { SocialRelationshipState.sameUser($0, change.user) }
            if change.isFollowed {
                users = deduplicated([change.user] + users)
            } else {
                users.removeAll { SocialRelationshipState.sameUser($0, change.user) }
            }
            if change.isFollowed != alreadyPresent {
                totalCount = max(totalCount + (change.isFollowed ? 1 : -1), 0)
            }
        } else if kind == .followers, SocialRelationshipState.sameUser(user, change.user) {
            guard let account else { return }
            let currentUser = UserSummary(
                id: Int64(account.uid) ?? 0,
                name: account.name,
                displayName: account.displayName,
                portrait: account.portrait
            )
            let alreadyPresent = users.contains { SocialRelationshipState.sameUser($0, currentUser) }
            if change.isFollowed {
                users = deduplicated([currentUser] + users)
            } else {
                users.removeAll { SocialRelationshipState.sameUser($0, currentUser) }
            }
            if change.isFollowed != alreadyPresent {
                totalCount = max(totalCount + (change.isFollowed ? 1 : -1), 0)
            }
        }
    }

    private var isCurrentAccountProfile: Bool {
        guard let account, let accountUserID = Int64(account.uid) else { return false }
        return accountUserID == user.id
    }

    private var currentAccountUser: UserSummary? {
        guard let account else { return nil }
        return UserSummary(
            id: Int64(account.uid) ?? 0,
            name: account.name,
            displayName: account.displayName,
            portrait: account.portrait
        )
    }

    private var selectedUserIsActive: Binding<Bool> {
        Binding(
            get: { selectedUser != nil },
            set: { isActive in
                if isActive == false { selectedUser = nil }
            }
        )
    }

    private func rowIdentifier(_ relationshipUser: UserSummary) -> String {
        if kind == .following {
            return "followed-user-row-\(relationshipUser.id)"
        }
        return "follower-user-row-\(relationshipUser.id)"
    }

    private func deduplicated(_ candidates: [UserSummary]) -> [UserSummary] {
        var seen = Set<String>()
        return candidates.filter { relationshipUser in
            let key: String
            if relationshipUser.id != 0 {
                key = "id:\(relationshipUser.id)"
            } else if relationshipUser.portrait.isEmpty == false {
                key = "portrait:\(relationshipUser.portrait)"
            } else {
                key = "name:\(relationshipUser.name)|\(relationshipUser.displayName)"
            }
            return seen.insert(key).inserted
        }
    }

    private func cancelRequests() {
        loadTask?.cancel()
        loadTask = nil
        requestGeneration += 1
        isLoading = false
    }
}

private struct UserRelationshipRow: View {
    let user: UserSummary

    var body: some View {
        HStack(spacing: TieBaXTheme.Spacing.sm) {
            AvatarView(
                url: user.portraitURL,
                title: user.displayNameResolved,
                size: TieBaXTheme.AvatarSize.medium
            )

            VStack(alignment: .leading, spacing: TieBaXTheme.Spacing.xxs) {
                Text(user.displayNameResolved)
                    .font(.body.weight(.semibold))
                    .tieBaForegroundStyle(.primary)
                    .lineLimit(2)

                if secondaryName.isEmpty == false {
                    Text(secondaryName)
                        .font(.footnote)
                        .tieBaForegroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: TieBaXTheme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.vertical, TieBaXTheme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("打开用户主页")
    }

    private var secondaryName: String {
        let trimmedName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false, trimmedName != user.displayNameResolved else { return "" }
        return "@\(trimmedName)"
    }

    private var accessibilityText: String {
        secondaryName.isEmpty ? user.displayNameResolved : "\(user.displayNameResolved)，\(secondaryName)"
    }
}
