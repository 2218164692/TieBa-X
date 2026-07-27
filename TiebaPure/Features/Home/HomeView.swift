import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let account: Account?
    var refreshToken: Int = 0

    @ObservedObject private var blocklistStore = BlocklistStore.shared
    @State private var activeSearch: SearchRoute?
    @State private var threads: [ThreadSummary] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var navigationPath: [HomeNavigationRoute] = []
    @State private var selectedVideoPreview: HomeVideoPreview?
    @State private var selectedUser: UserSummary?
    @State private var showsInlineRefreshAnimation = false
    @State private var showsPullRefreshIndicator = false
    @State private var pullProgress: CGFloat = 0
    @State private var pullReachedTrigger = false
    @State private var lastScenePhase: ScenePhase = .inactive
    @State private var scrollToTopRequest = 0
    @State private var requestGeneration = 0
    @State private var loadTask: Task<[ThreadSummary], Error>?
    @State private var pendingPaginationRequest = false
    @State private var paginationRequestScheduled = false
    @State private var scrollDistanceFromTop: CGFloat = 0
    @State private var isTrackingPullGesture = false
    @State private var pullGestureStartedAtTop = false
    @State private var splitDetailPath: [ReaderSplitThreadRoute] = []

    var body: some View {
        ReaderSplitLayout(
            account: account,
            navigationPath: $navigationPath,
            detailPath: $splitDetailPath,
            openThreadInDetail: { openThreadInSplitDetail($0) },
            openThreadInCompact: { openThreadInCompactStack($0) },
            listColumn: { feedColumn },
            detailRoot: { placeholder in
                // Regular width routes global search into the detail column so
                // the feed list stays visible and drivable next to it.
                placeholder
                    .navigationDestination(isPresented: splitSearchIsActive) {
                        if let activeSearch {
                            SearchResultsView(account: account, scope: .global, initialKeyword: activeSearch.keyword)
                                .interactiveNavigationPopStateSync {
                                    self.activeSearch = nil
                                }
                        }
                    }
            }
        )
        .toolbar(.visible, for: .tabBar)
        .onChange(of: horizontalSizeClass) { sizeClass in
            foldNavigationForSizeClassChange(to: sizeClass)
        }
    }

    private var feedColumn: some View {
        Group {
            if isLoading && didLoad == false {
                ReaderStateView.loading("正在加载帖子")
            } else if let errorMessage, threads.isEmpty {
                refreshableScrollView(usesSystemRefresh: true) {
                    ReaderStateView.error(message: errorMessage) {
                        Task { await reload(trigger: .retry) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, TiebaPureTheme.Spacing.lg)
                }
            } else if threads.isEmpty {
                refreshableScrollView(usesSystemRefresh: true) {
                    ReaderStateView.empty(
                        title: "暂无推荐",
                        message: "下拉即可刷新推荐帖子。",
                        actionTitle: hasMore && didLoad ? "继续加载" : nil,
                        action: hasMore && didLoad ? { Task { await loadMore() } } : nil
                    )
                        .frame(maxWidth: .infinity)
                        .padding(.top, TiebaPureTheme.Spacing.lg)
                }
            } else {
                ScrollViewReader { scrollProxy in
                    refreshableScrollView {
                        LazyVStack(spacing: TiebaPureTheme.Spacing.sm, pinnedViews: []) {
                            Color.clear
                                .frame(height: 0)
                                .id(HomeScrollTarget.top)

                            ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                                ForumThreadRow(
                                    thread: thread,
                                    presentation: .homeFeed,
                                    onOpenThread: {
                                        openThread(threadID: thread.id, forumID: thread.forumID)
                                    },
                                    onOpenForum: { forum in
                                        RecentForumStore.shared.save(forum)
                                        navigationPath.append(.fromForum(forum))
                                    },
                                    onOpenUser: { selectedUser = $0 },
                                    onOpenMedia: { item, mediaItems, sourceFrame, sourceImage, sourceAnchor in
                                        switch HomeMediaActionPolicy.action(for: item, in: mediaItems) {
                                        case let .previewImages(images, index):
                                            ImagePreviewCoordinator.shared.present(
                                                ImagePreviewSession(
                                                    images: images,
                                                    initialIndex: index,
                                                    sourceFrame: sourceFrame,
                                                    sourceImage: sourceImage,
                                                    sourceAnchor: sourceAnchor
                                                )
                                            )
                                        case let .playVideo(video):
                                            selectedVideoPreview = HomeVideoPreview(video: video)
                                        case .openThread:
                                            openThread(threadID: thread.id, forumID: thread.forumID)
                                        }
                                    }
                                )
                                .onAppear {
                                    requestLoadMoreIfNeeded(currentIndex: index, totalCount: threads.count)
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("thread-row")

                                if index == threads.count - 1, isLoading, didLoad {
                                    ProgressView()
                                        .padding(TiebaPureTheme.Spacing.md)
                                        .accessibilityLabel("正在加载更多帖子")
                                }
                            }

                            if let errorMessage {
                                InlineLoadErrorView(message: errorMessage) {
                                    Task {
                                        if page <= 1 { await reload(trigger: .retry) }
                                        else {
                                            self.errorMessage = nil
                                            await loadMore()
                                        }
                                    }
                                }
                            } else if hasMore, isLoading == false, didLoad {
                                Button {
                                    Task { await loadMore() }
                                } label: {
                                    Label("加载更多", systemImage: "arrow.down.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .minTouchTarget()
                                .accessibilityHint("加载下一页推荐帖子")
                                .padding(.horizontal, TiebaPureTheme.Spacing.md)
                            }

                            Color.clear
                                .frame(height: 64)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, TiebaPureTheme.Spacing.sm)
                        .padding(.vertical, TiebaPureTheme.Spacing.sm)
                        .readableWidth()
                    }
                    .onChange(of: scrollToTopRequest) { _ in
                        if reduceMotion || disablesUITestAnimations {
                            scrollProxy.scrollTo(HomeScrollTarget.top, anchor: .top)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo(HomeScrollTarget.top, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showsInlineRefreshAnimation || showsPullRefreshIndicator {
                InlineRefreshActivityIndicator(
                    progress: showsInlineRefreshAnimation ? 1 : pullProgress,
                    isRefreshing: showsInlineRefreshAnimation,
                    accessibilityIdentifier: "home-refresh-animation"
                )
                .padding(.top, TiebaPureTheme.Spacing.xs)
                .offset(y: showsInlineRefreshAnimation ? 0 : -14 + 22 * pullProgress)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
                .zIndex(2)
            }
        }
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSearch = SearchRoute(keyword: "")
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .minTouchTarget()
                .accessibilityLabel("搜索")
                .accessibilityHint("打开单独的搜索页面")
                .accessibilityIdentifier("home-search-button")
            }
        }
        .navigationDestination(isPresented: searchIsActive) {
            if let activeSearch {
                SearchResultsView(account: account, scope: .global, initialKeyword: activeSearch.keyword)
                    .interactiveNavigationPopStateSync {
                        self.activeSearch = nil
                    }
            }
        }
        .navigationDestination(for: HomeNavigationRoute.self) { route in
            switch route {
            case let .thread(threadID, forumID):
                ThreadDetailView(
                    account: account,
                    threadID: threadID,
                    forumID: forumID
                )
                .interactiveNavigationPopStateSync {
                    removeNavigationRouteIfCurrent(route)
                }
            case let .forum(id, name, displayName, avatarURL):
                ForumThreadsView(
                    account: account,
                    forum: Forum(
                        id: id,
                        name: name,
                        displayName: displayName,
                        avatarURL: avatarURL,
                        memberCount: 0,
                        threadCount: 0
                    ),
                    openThreadInParent: { route in
                        openThreadFromNestedForum(route)
                    }
                )
                .interactiveNavigationPopStateSync {
                    removeNavigationRouteIfCurrent(route)
                }
            }
        }
        .navigationDestination(isPresented: selectedUserIsActive) {
            if let selectedUser {
                UserProfileView(account: account, user: selectedUser)
                    .interactiveNavigationPopStateSync {
                        self.selectedUser = nil
                    }
            }
        }
        .interactiveNavigationPopRevealSource()
        .task {
            guard didLoad == false else { return }
            await reload(trigger: .initial)
        }
        .onChange(of: refreshToken) { _ in
            // Tab re-tap while pushed pops to root instead of refreshing
            // the covered feed, matching the iOS tab-reselect convention. In
            // the split layout the detail selection likewise clears back to
            // the placeholder without reloading.
            if navigationPath.isEmpty == false || activeSearch != nil || selectedUser != nil
                || splitDetailPath.isEmpty == false {
                navigationPath = []
                activeSearch = nil
                selectedUser = nil
                splitDetailPath = []
                return
            }
            Task { await reload(trigger: .tabTap) }
        }
        .onChange(of: account?.id) { _ in
            loadTask?.cancel()
            requestGeneration += 1
            threads = []
            page = 1
            hasMore = true
            didLoad = false
            isLoading = false
            pendingPaginationRequest = false
            paginationRequestScheduled = false
            errorMessage = nil
            showsInlineRefreshAnimation = false
            showsPullRefreshIndicator = false
            scrollDistanceFromTop = 0
            resetPullGestureState()
            navigationPath = []
            selectedUser = nil
            splitDetailPath = []
            Task { await reload(trigger: .initial) }
        }
        .onChange(of: blocklistStore.entries) { _ in
            threads.removeAll { TiebaContentFilter.shouldKeep(thread: $0) == false }
        }
        .onChange(of: scenePhase) { newPhase in
            let previousPhase = lastScenePhase
            lastScenePhase = newPhase
            guard HomeOpenRefreshPolicy.shouldRefreshOnScenePhaseChange(
                from: previousPhase,
                to: newPhase,
                didLoad: didLoad
            ) else {
                return
            }
            Task { await reload(trigger: .appOpen) }
        }
        .fullScreenCover(item: $selectedVideoPreview) { preview in
            DirectVideoPlaybackView(video: preview.video)
        }
        .onDisappear {
            loadTask?.cancel()
            requestGeneration += 1
            isLoading = false
            showsInlineRefreshAnimation = false
            showsPullRefreshIndicator = false
            pendingPaginationRequest = false
            paginationRequestScheduled = false
            resetPullGestureState()
        }
    }

    private var usesSplitDetailLayout: Bool {
        horizontalSizeClass == .regular
    }

    // Search presents in exactly one column per layout: the feed stack when
    // compact, the detail column when the split layout is active.
    private var searchIsActive: Binding<Bool> {
        Binding(
            get: { usesSplitDetailLayout == false && activeSearch != nil },
            set: { isActive in
                if isActive == false {
                    activeSearch = nil
                }
            }
        )
    }

    private var splitSearchIsActive: Binding<Bool> {
        Binding(
            get: { usesSplitDetailLayout && activeSearch != nil },
            set: { isActive in
                if isActive == false {
                    activeSearch = nil
                }
            }
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

    private func removeNavigationRouteIfCurrent(_ route: HomeNavigationRoute) {
        guard navigationPath.last == route else { return }
        navigationPath.removeLast()
    }

    private func openThread(threadID: Int64, forumID: Int64?) {
        if usesSplitDetailLayout {
            openThreadInSplitDetail(ReaderSplitThreadRoute(threadID: threadID, forumID: forumID))
            return
        }
        navigationPath.append(.thread(threadID: threadID, forumID: forumID))
    }

    private func openThreadInSplitDetail(_ route: ReaderSplitThreadRoute) {
        // A newly selected thread owns the whole detail column; a search page
        // pushed there would otherwise keep covering the new selection.
        activeSearch = nil
        splitDetailPath = [route]
    }

    private func openThreadInCompactStack(_ route: ReaderSplitThreadRoute) {
        navigationPath.append(
            .thread(threadID: route.threadID, forumID: route.forumID)
        )
    }

    private func openThreadFromNestedForum(_ route: ReaderSplitThreadRoute) {
        if usesSplitDetailLayout {
            openThreadInSplitDetail(route)
        } else {
            openThreadInCompactStack(route)
        }
    }

    /// Keeps the open thread when the split layout appears or collapses
    /// mid-session (e.g. iPad Split View resizes across the width threshold).
    private func foldNavigationForSizeClassChange(to sizeClass: UserInterfaceSizeClass?) {
        switch sizeClass {
        case .compact:
            guard let route = splitDetailPath.last else { return }
            splitDetailPath = []
            navigationPath.append(.thread(threadID: route.threadID, forumID: route.forumID))
        case .regular:
            guard case let .thread(threadID, forumID)? = navigationPath.last else { return }
            navigationPath.removeLast()
            splitDetailPath = [ReaderSplitThreadRoute(threadID: threadID, forumID: forumID)]
        default:
            break
        }
    }

    @ViewBuilder
    private func refreshableScrollView<Content: View>(
        usesSystemRefresh: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let scrollView = ScrollView {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HomeScrollTopOffsetPreferenceKey.self,
                        value: proxy.frame(in: .named(HomeScrollCoordinateSpace.name)).minY
                    )
                }
                .frame(height: 0)

                ScrollViewPanGestureObserver(onStateChange: handlePullRefreshPan)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)

                content()
            }
            .contentShape(Rectangle())
        }
        .coordinateSpace(name: HomeScrollCoordinateSpace.name)
        .onPreferenceChange(HomeScrollTopOffsetPreferenceKey.self) { markerOffset in
            if #unavailable(iOS 18.0) {
                scrollDistanceFromTop = ShortPullRefreshPolicy.distanceFromTop(
                    markerOffset: markerOffset
                )
            }
        }
        .trackVerticalScrollDistanceFromTop($scrollDistanceFromTop)
        .background(TiebaPureTheme.ColorToken.readerGroupedBackground)
        .accessibilityIdentifier("home-feed-scroll-view")

        if usesSystemRefresh {
            scrollView.refreshable { await refreshFromPullGestureIfIdle() }
        } else {
            scrollView
        }
    }

    private func handlePullRefreshPan(
        state: UIGestureRecognizer.State,
        translation: CGSize
    ) {
        switch state {
        case .changed:
            if isTrackingPullGesture == false {
                isTrackingPullGesture = true
                pullGestureStartedAtTop = ShortPullRefreshPolicy.shouldBegin(
                    distanceFromTop: scrollDistanceFromTop,
                    initialTranslation: translation
                )
                if pullGestureStartedAtTop, isLoading == false {
                    setPullRefreshIndicator(visible: true)
                }
            } else if ShortPullRefreshPolicy.isAtTop(
                distanceFromTop: scrollDistanceFromTop
            ) == false {
                // Eligibility is latched at gesture start. Reaching the top
                // later in the same downward drag must not refresh.
                pullGestureStartedAtTop = false
                setPullRefreshIndicator(visible: false)
            }
            if pullGestureStartedAtTop, isLoading == false {
                // Direct manipulation: the indicator follows the finger, so
                // no implicit animation between updates.
                pullProgress = ShortPullRefreshPolicy.pullProgress(translation: translation)
                let ready = pullProgress >= 1
                if ready != pullReachedTrigger {
                    pullReachedTrigger = ready
                    if ready {
                        PullRefreshHaptics.triggerReady()
                    }
                }
            }
        case .ended:
            let shouldRefresh = ShortPullRefreshPolicy.shouldTrigger(
                startedAtTop: pullGestureStartedAtTop,
                isRefreshing: isLoading,
                translation: translation
            )
            resetPullGestureState()
            guard shouldRefresh else { return }
            Task { await refreshFromPullGestureIfIdle() }
        case .cancelled, .failed:
            resetPullGestureState()
        default:
            break
        }
    }

    private func refreshFromPullGestureIfIdle() async {
        guard isLoading == false else { return }
        await reload(trigger: .pullToRefresh)
    }

    private func reload(trigger: HomeRefreshTrigger) async {
        if HomeRefreshRevealPolicy.shouldScrollToTop(
            trigger: trigger,
            hasExistingContent: threads.isEmpty == false
        ) {
            scrollToTopRequest += 1
        }
        loadTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = false
        pendingPaginationRequest = false
        paginationRequestScheduled = false
        let showsInlineAnimation = HomeRefreshAnimationPolicy.shouldAnimate(
            trigger: trigger,
            hasExistingContent: threads.isEmpty == false,
            reduceMotion: reduceMotion
        )
        if showsInlineAnimation && reduceMotion == false {
            setInlineRefreshAnimation(visible: true)
        }
        let animationStart = DispatchTime.now().uptimeNanoseconds
        page = 1
        hasMore = true
        errorMessage = nil
        if threads.isEmpty {
            didLoad = false
        }
        await loadMore(generation: generation)
        if showsInlineAnimation && reduceMotion == false {
            let minimumVisibleDuration = HomeRefreshAnimationPolicy.minimumVisibleDurationNanoseconds
            let elapsed = DispatchTime.now().uptimeNanoseconds - animationStart
            let remaining = HomeRefreshAnimationPolicy.remainingVisibleDurationNanoseconds(
                minimum: minimumVisibleDuration,
                elapsed: elapsed
            )
            if remaining > 0 {
                // Do not inherit cancellation from SwiftUI's gesture task. The
                // request generation remains the authority for whether this
                // refresh is still current.
                let minimumVisibilityTask = Task.detached {
                    try? await Task.sleep(nanoseconds: remaining)
                }
                await minimumVisibilityTask.value
            }
            guard generation == requestGeneration else { return }
            setInlineRefreshAnimation(visible: false)
        }
    }

    private func setInlineRefreshAnimation(visible: Bool) {
        if disablesUITestAnimations || reduceMotion {
            showsInlineRefreshAnimation = visible
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                showsInlineRefreshAnimation = visible
            }
        }
    }

    private func setPullRefreshIndicator(visible: Bool) {
        let resolvedVisibility = visible && reduceMotion == false
        if disablesUITestAnimations {
            showsPullRefreshIndicator = resolvedVisibility
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                showsPullRefreshIndicator = resolvedVisibility
            }
        }
    }

    private func resetPullGestureState() {
        isTrackingPullGesture = false
        pullGestureStartedAtTop = false
        pullProgress = 0
        pullReachedTrigger = false
        setPullRefreshIndicator(visible: false)
    }

    private var disablesUITestAnimations: Bool {
        HomeRefreshAnimationPolicy.disablesUITestAnimations(
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    private func loadMore() async {
        await loadMore(generation: requestGeneration)
    }

    private func loadMore(
        generation: Int,
        consecutiveHiddenPageCount: Int = 0
    ) async {
        guard hasMore else {
            pendingPaginationRequest = false
            return
        }
        guard errorMessage == nil else {
            pendingPaginationRequest = false
            return
        }
        guard isLoading == false else {
            pendingPaginationRequest = true
            return
        }
        let requestedAccountID = account?.id
        isLoading = true
        errorMessage = nil
        var continuation: LocallyFilteredPaginationDecision?

        do {
            let requestedPage = page
            let task = Task {
                try await environment.api.personalizedThreads(
                    account: account,
                    page: requestedPage,
                    loadType: requestedPage == 1 ? 1 : 2
                )
            }
            loadTask = task
            let next = try await task.value
            guard generation == requestGeneration,
                  requestedAccountID == account?.id else { return }
            let visibleNext = next.filter(TiebaContentFilter.shouldKeep(thread:))
            if requestedPage == 1 {
                threads = HomeFeedMerge.refresh(existing: threads, incoming: visibleNext)
            } else {
                threads = HomeFeedMerge.append(existing: threads, incoming: visibleNext)
            }
            // Pagination follows the service page, not the number left after
            // applying local block rules.
            hasMore = next.isEmpty == false
            page = requestedPage + 1
            continuation = LocallyFilteredPaginationPolicy.decision(
                visibleItemCount: visibleNext.count,
                serverHasMore: hasMore,
                consecutiveHiddenPageCount: consecutiveHiddenPageCount
            )
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            loadTask = nil
            isLoading = false
            pendingPaginationRequest = false
            paginationRequestScheduled = false
            return
        } catch {
            guard generation == requestGeneration, requestedAccountID == account?.id else { return }
            errorMessage = ReaderErrorMessage.message(for: error)
        }
        guard generation == requestGeneration else { return }
        loadTask = nil
        isLoading = false
        didLoad = true
        if let continuation, continuation.shouldAutomaticallyLoadNextPage {
            await loadMore(
                generation: generation,
                consecutiveHiddenPageCount: continuation.consecutiveHiddenPageCount
            )
            return
        }
        if continuation?.shouldOfferManualContinuation == true {
            // A still-visible footer/empty-state button resumes with a fresh
            // bounded batch instead of turning a queued prefetch into a loop.
            pendingPaginationRequest = false
            return
        }
        let shouldContinuePagination = pendingPaginationRequest
            && hasMore
            && errorMessage == nil
        pendingPaginationRequest = false
        if shouldContinuePagination {
            await loadMore(generation: generation)
        }
    }

    private func requestLoadMoreIfNeeded(currentIndex: Int, totalCount: Int) {
        guard PaginationPrefetchPolicy.shouldLoadMore(
            currentIndex: currentIndex,
            totalCount: totalCount
        ) else { return }
        if isLoading {
            pendingPaginationRequest = true
            return
        }
        guard paginationRequestScheduled == false else { return }
        paginationRequestScheduled = true
        Task {
            await loadMore()
            paginationRequestScheduled = false
        }
    }
}

enum HomeRefreshTrigger {
    case initial
    case retry
    case pullToRefresh
    case tabTap
    case appOpen
}

enum HomeRefreshAnimationPolicy {
    static var minimumVisibleDurationNanoseconds: UInt64 {
        minimumVisibleDurationNanoseconds(arguments: ProcessInfo.processInfo.arguments)
    }

    static func minimumVisibleDurationNanoseconds(arguments: [String]) -> UInt64 {
        #if DEBUG
        if arguments.contains("UITEST_EXTENDED_REFRESH_ANIMATION") {
            return 5_000_000_000
        }
        #endif

        return 600_000_000
    }

    static func disablesUITestAnimations(arguments: [String]) -> Bool {
        #if DEBUG
        return arguments.contains("UITEST_DISABLE_ANIMATIONS")
        #else
        return false
        #endif
    }

    static func showsInlineAnimation(trigger: HomeRefreshTrigger, hasExistingContent: Bool) -> Bool {
        hasExistingContent && (trigger == .tabTap || trigger == .pullToRefresh || trigger == .appOpen)
    }

    static func shouldAnimate(trigger: HomeRefreshTrigger, hasExistingContent: Bool, reduceMotion: Bool) -> Bool {
        reduceMotion == false && showsInlineAnimation(trigger: trigger, hasExistingContent: hasExistingContent)
    }

    static func remainingVisibleDurationNanoseconds(minimum: UInt64, elapsed: UInt64) -> UInt64 {
        minimum > elapsed ? minimum - elapsed : 0
    }
}

enum HomeRefreshRevealPolicy {
    static func shouldScrollToTop(trigger: HomeRefreshTrigger, hasExistingContent: Bool) -> Bool {
        hasExistingContent && trigger == .tabTap
    }
}

enum ShortPullRefreshPolicy {
    static let triggerDistance: CGFloat = 64
    static let topTolerance: CGFloat = 2
    static let verticalDominance: CGFloat = 1.2

    static func distanceFromTop(contentOffsetY: CGFloat, topInset: CGFloat) -> CGFloat {
        max(contentOffsetY + topInset, 0)
    }

    static func distanceFromTop(markerOffset: CGFloat) -> CGFloat {
        max(-markerOffset, 0)
    }

    static func isAtTop(distanceFromTop: CGFloat) -> Bool {
        distanceFromTop <= topTolerance
    }

    static func shouldBegin(
        distanceFromTop: CGFloat,
        initialTranslation: CGSize
    ) -> Bool {
        guard isAtTop(distanceFromTop: distanceFromTop) else { return false }
        guard initialTranslation.height > 0 else { return false }
        return initialTranslation.height >= abs(initialTranslation.width) * verticalDominance
    }

    static func shouldTrigger(
        startedAtTop: Bool,
        isRefreshing: Bool,
        translation: CGSize
    ) -> Bool {
        guard startedAtTop, isRefreshing == false else { return false }
        guard translation.height >= triggerDistance else { return false }
        return translation.height >= abs(translation.width) * verticalDominance
    }

    /// 0...1 fraction of the release threshold covered by the current drag,
    /// driving the indicator's fill, rotation, and slide-in.
    static func pullProgress(translation: CGSize) -> CGFloat {
        guard translation.height > 0 else { return 0 }
        return min(translation.height / triggerDistance, 1)
    }
}

extension View {
    @ViewBuilder
    func trackVerticalScrollDistanceFromTop(_ distance: Binding<CGFloat>) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                ShortPullRefreshPolicy.distanceFromTop(
                    contentOffsetY: geometry.contentOffset.y,
                    topInset: geometry.contentInsets.top
                )
            } action: { _, newDistance in
                distance.wrappedValue = newDistance
            }
        } else {
            self
        }
    }
}

/// Observes the `UIScrollView`'s existing pan recognizer without installing a
/// competing SwiftUI drag gesture. That distinction matters on iOS 26: UIKit's
/// native content-area pop gesture can arbitrate normally with a scroll view,
/// while a page-wide `DragGesture` can claim the same horizontal drag first.
struct ScrollViewPanGestureObserver: UIViewRepresentable {
    let onStateChange: (UIGestureRecognizer.State, CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: onStateChange)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onHierarchyChange = { [weak coordinator = context.coordinator] attachmentView in
            coordinator?.scheduleAttachment(from: attachmentView)
        }
        context.coordinator.scheduleAttachment(from: view)
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.onStateChange = onStateChange
        context.coordinator.scheduleAttachment(from: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        uiView.onHierarchyChange = nil
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        var onHierarchyChange: ((UIView) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onHierarchyChange?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onHierarchyChange?(self)
        }
    }

    final class Coordinator: NSObject {
        var onStateChange: (UIGestureRecognizer.State, CGSize) -> Void
        private weak var panGestureRecognizer: UIPanGestureRecognizer?
        private var pendingAttachment: DispatchWorkItem?

        init(onStateChange: @escaping (UIGestureRecognizer.State, CGSize) -> Void) {
            self.onStateChange = onStateChange
        }

        func scheduleAttachment(from view: UIView) {
            pendingAttachment?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                self.attach(to: Self.enclosingScrollView(startingAt: view))
            }
            pendingAttachment = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        func detach() {
            pendingAttachment?.cancel()
            pendingAttachment = nil
            panGestureRecognizer?.removeTarget(self, action: #selector(handlePan(_:)))
            panGestureRecognizer = nil
        }

        private func attach(to scrollView: UIScrollView?) {
            guard let recognizer = scrollView?.panGestureRecognizer else { return }
            guard panGestureRecognizer !== recognizer else { return }
            panGestureRecognizer?.removeTarget(self, action: #selector(handlePan(_:)))
            panGestureRecognizer = recognizer
            recognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.translation(in: recognizer.view)
            onStateChange(
                recognizer.state,
                CGSize(width: point.x, height: point.y)
            )
        }

        private static func enclosingScrollView(startingAt view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
        }
    }
}

private enum HomeScrollCoordinateSpace {
    static let name = "home-refresh-scroll"
}

private struct HomeScrollTopOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum HomeOpenRefreshPolicy {
    static func shouldRefreshOnScenePhaseChange(
        from previousPhase: ScenePhase,
        to newPhase: ScenePhase,
        didLoad: Bool
    ) -> Bool {
        didLoad && previousPhase == .background && newPhase == .active
    }
}

private enum HomeScrollTarget {
    case top
}

enum HomeFeedMerge {
    static func refresh(existing: [ThreadSummary], incoming: [ThreadSummary]) -> [ThreadSummary] {
        merge(preferred: incoming, fallback: existing)
    }

    static func append(existing: [ThreadSummary], incoming: [ThreadSummary]) -> [ThreadSummary] {
        merge(preferred: existing, fallback: incoming)
    }

    private static func merge(preferred: [ThreadSummary], fallback: [ThreadSummary]) -> [ThreadSummary] {
        var seen = Set<Int64>()
        var merged: [ThreadSummary] = []
        merged.reserveCapacity(preferred.count + fallback.count)

        for thread in preferred + fallback where seen.insert(thread.id).inserted {
            merged.append(thread)
        }

        return merged
    }
}

struct HomeVideoPreview: Identifiable {
    let id = UUID()
    let video: VideoContent
}

enum HomeMediaAction: Equatable {
    case previewImages([ImageContent], index: Int)
    case playVideo(VideoContent)
    case openThread
}

enum HomeMediaActionPolicy {
    static func action(for item: ReaderMediaItem, in mediaItems: [ReaderMediaItem]) -> HomeMediaAction {
        if let video = item.video {
            return .playVideo(video)
        }
        if let image = item.image {
            let images = mediaItems.compactMap(\.image)
            let resolvedImages = images.isEmpty ? [image] : images
            let index = resolvedImages.firstIndex(of: image) ?? 0
            return .previewImages(resolvedImages, index: index)
        }
        return .openThread
    }

    static func action(for item: ReaderMediaItem) -> HomeMediaAction {
        action(for: item, in: [item])
    }
}

private enum HomeNavigationRoute: Hashable {
    case thread(threadID: Int64, forumID: Int64?)
    case forum(id: Int64, name: String, displayName: String, avatarURL: URL?)

    static func fromForum(_ forum: Forum) -> HomeNavigationRoute {
        .forum(
            id: forum.id,
            name: forum.name,
            displayName: forum.displayName,
            avatarURL: forum.avatarURL
        )
    }
}
