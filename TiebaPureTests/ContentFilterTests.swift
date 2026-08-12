import XCTest
@testable import TiebaPure

final class ContentFilterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot())
    }

    override func tearDown() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot())
        super.tearDown()
    }

    func testFilterDropsLiveThreadButKeepsVideoThread() {
        var live = Tieba_ThreadInfo()
        live.id = 1
        live.alaInfo = Tieba_AlaLiveInfo()

        var video = Tieba_ThreadInfo()
        video.id = 2
        var videoInfo = Tieba_VideoInfo()
        videoInfo.videoURL = "https://video.example/a.mp4"
        video.videoInfo = videoInfo

        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: live))
        XCTAssertTrue(TiebaContentFilter.shouldKeep(thread: video))
    }

    func testFilterKeepsValidVoiceContentAndDropsInvalidVoiceContent() {
        var voice = Tieba_PbContent()
        voice.type = 10
        voice.voiceMd5 = "abcdef0123456789abcdef0123456789"

        XCTAssertTrue(TiebaContentFilter.shouldKeep(content: voice))

        voice.voiceMd5 = "invalid"
        XCTAssertFalse(TiebaContentFilter.shouldKeep(content: voice))
    }

    func testFilterDropsAdAndFoldedPostsEvenWithValidFloors() {
        var ad = Tieba_Post()
        ad.advertisement = Tieba_Advertisement()
        ad.floor = 2

        var folded = Tieba_Post()
        folded.isFold = 1
        folded.floor = 3

        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: ad))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: folded))
    }

    func testFilterKeepsValidVoiceFloorsAndDropsInvalidOrEmptyFloors() {
        var voice = Tieba_PbContent()
        voice.type = 10
        voice.voiceMd5 = "abcdef0123456789abcdef0123456789"

        // A valid voice is renderable content, so its floor remains visible.
        var voiceOnly = Tieba_Post()
        voiceOnly.content = [voice]
        voiceOnly.floor = 5
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: voiceOnly))

        var invalidVoiceOnly = Tieba_Post()
        var invalidVoice = Tieba_PbContent()
        invalidVoice.type = 10
        invalidVoiceOnly.content = [invalidVoice]
        invalidVoiceOnly.floor = 5
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: invalidVoiceOnly))

        var invalidVoiceWithSubposts = invalidVoiceOnly
        invalidVoiceWithSubposts.subPostNumber = 3
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: invalidVoiceWithSubposts))

        var emptyContent = Tieba_Post()
        emptyContent.floor = 6
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: emptyContent))

        var emptyContentWithSubposts = emptyContent
        emptyContentWithSubposts.subPostList.subPostList = [Tieba_SubPostList()]
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: emptyContentWithSubposts))
    }

    func testBlocklistDropsThreadsByKeywordCaseInsensitively() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["spoiler"]))

        var titled = Tieba_ThreadInfo()
        titled.id = 1
        titled.title = "全是 SPOILER 的标题"
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: titled))

        var abstracted = Tieba_ThreadInfo()
        abstracted.id = 2
        abstracted.title = "普通标题"
        var abstract = Tieba_Abstract()
        abstract.text = "摘要里提到了 Spoiler 内容"
        abstracted.abstract = [abstract]
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: abstracted))

        var clean = Tieba_ThreadInfo()
        clean.id = 3
        clean.title = "普通标题"
        XCTAssertTrue(TiebaContentFilter.shouldKeep(thread: clean))
    }

    func testBlocklistDropsThreadsByAuthorIDAndForumName() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(userIDs: [42], forumNames: ["steam"]))

        var byAuthorID = Tieba_ThreadInfo()
        byAuthorID.id = 1
        byAuthorID.authorID = 42
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: byAuthorID))

        var byNestedAuthor = Tieba_ThreadInfo()
        byNestedAuthor.id = 2
        var author = Tieba_User()
        author.id = 42
        byNestedAuthor.author = author
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: byNestedAuthor))

        var byForum = Tieba_ThreadInfo()
        byForum.id = 3
        byForum.forumName = "Steam"
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: byForum))

        var unrelated = Tieba_ThreadInfo()
        unrelated.id = 4
        unrelated.authorID = 7
        unrelated.forumName = "dota2"
        XCTAssertTrue(TiebaContentFilter.shouldKeep(thread: unrelated))
    }

    func testForumBlocklistCanonicalizesCaseWhitespaceAndOptionalSuffixBothWays() {
        let suffixedRule = BlocklistSnapshot(forumNames: ["  Steam吧  "])
        XCTAssertTrue(suffixedRule.blocksForum(named: "steam"))
        XCTAssertTrue(suffixedRule.blocksForum(named: " STEAM吧 "))
        XCTAssertFalse(suffixedRule.blocksForum(named: "steam deck"))

        let plainRule = BlocklistSnapshot(forumNames: ["steam"])
        XCTAssertTrue(plainRule.blocksForum(named: "Steam吧"))

        XCTAssertEqual(
            BlocklistPolicy.normalized(
                BlocklistEntry(kind: .forum, value: " 测试吧吧 ", userID: 42)
            ),
            BlocklistEntry(kind: .forum, value: "测试吧", userID: nil)
        )
    }

    func testForumBlocklistMatchesPreciseIDAndKnownNameIndependently() {
        let idOnlyRule = BlocklistSnapshot(forumIDs: [765])
        XCTAssertTrue(idOnlyRule.blocksForum(id: 765, names: []))
        XCTAssertTrue(idOnlyRule.blocksForum(id: 765, names: ["完全不同"]))
        XCTAssertFalse(idOnlyRule.blocksForum(id: 766, names: ["完全不同"]))
        XCTAssertFalse(idOnlyRule.blocksForum(named: "贴吧 ID 765"))

        let namedRule = BlocklistSnapshot(
            forumIDs: [123],
            forumNames: [" Steam吧 "]
        )
        XCTAssertTrue(namedRule.blocksForum(id: 123, names: []))
        XCTAssertTrue(namedRule.blocksForum(id: 999, names: ["STEAM"]))
        XCTAssertFalse(namedRule.blocksForum(id: 999, names: ["dota2"]))
    }

    func testForumIDOnlyBlockAppliesAcrossThreadForumAndLocalLibraryLists() {
        let blocklist = BlocklistSnapshot(forumIDs: [88])
        TiebaContentFilter.updateBlocklist(blocklist)

        let author = UserSummary(
            id: 1,
            name: "author",
            displayName: "作者",
            portrait: ""
        )
        let thread = ThreadSummary(
            id: 1,
            forumID: 88,
            title: "没有吧名的帖子",
            author: author,
            forumName: nil,
            replyCount: 0,
            viewCount: 0,
            blocks: [.text("正文")]
        )
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: thread))

        var proto = Tieba_ThreadInfo()
        proto.id = 2
        proto.forumID = 88
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: proto))

        var nestedForumOnlyProto = Tieba_ThreadInfo()
        nestedForumOnlyProto.id = 3
        var nestedForum = Tieba_SimpleForum()
        nestedForum.id = 88
        nestedForumOnlyProto.forumInfo = nestedForum
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: nestedForumOnlyProto))

        let forum = Forum(
            id: 88,
            name: "接口返回的新名字",
            displayName: "接口返回的新名字吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        XCTAssertFalse(TiebaContentFilter.shouldKeep(forum: forum))
        XCTAssertFalse(
            ForumListPresentationPolicy.shouldKeep(forum, blocklist: blocklist)
        )

        let favorite = AccountThreadFavorite(
            threadID: 3,
            forumID: 88,
            forumName: "接口返回的新名字",
            title: "账号收藏",
            authorDisplayName: "作者",
            replyCount: 0,
            lastReplyAt: nil,
            markedPostID: nil
        )
        XCTAssertFalse(
            ThreadFavoritesListPolicy.shouldKeep(favorite, blocklist: blocklist)
        )

        let history = BrowsingHistoryEntry(
            threadID: 4,
            forumID: 88,
            title: "浏览记录",
            authorDisplayName: "作者",
            forumDisplayName: nil,
            visitedAt: .now
        )
        XCTAssertFalse(
            BrowsingHistoryListPolicy.shouldKeep(history, blocklist: blocklist)
        )

        var visibleThread = thread
        visibleThread.forumID = 89
        XCTAssertTrue(TiebaContentFilter.shouldKeep(thread: visibleThread))
    }

    func testBlocklistMatchesNameOnlyUserEntriesByDisplayName() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(entries: [
            BlocklistEntry(kind: .user, value: "  @捣乱用户 ", userID: nil)
        ]))

        var thread = Tieba_ThreadInfo()
        thread.id = 1
        var author = Tieba_User()
        author.id = 9
        author.nameShow = "捣乱用户"
        thread.author = author
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: thread))

        var post = Tieba_Post()
        post.floor = 2
        post.author = author
        var text = Tieba_PbContent()
        text.text = "普通内容"
        post.content = [text]
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: post))

        var otherAuthor = Tieba_User()
        otherAuthor.id = 10
        otherAuthor.nameShow = "无辜用户"
        var keptPost = post
        keptPost.author = otherAuthor
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: keptPost))
    }

    func testBlocklistNeverOverridesExistingRejects() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["不会命中"]))

        var live = Tieba_ThreadInfo()
        live.id = 1
        live.title = "普通标题"
        live.alaInfo = Tieba_AlaLiveInfo()
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: live))

        var ad = Tieba_Post()
        ad.advertisement = Tieba_Advertisement()
        ad.floor = 2
        var text = Tieba_PbContent()
        text.text = "普通内容"
        ad.content = [text]
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: ad))
    }

    func testStructuralPostFilterKeepsBlocklistedFirstFloorForThreadDetail() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["屏蔽主楼"]))
        var post = Tieba_Post()
        post.id = 1
        post.floor = 1
        var text = Tieba_PbContent()
        text.text = "正文含屏蔽主楼"
        post.content = [text]

        XCTAssertTrue(TiebaContentFilter.shouldMap(post: post))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: post))
    }

    func testBlocklistDropsPostsByAuthorEvenWhenKeptOnlyForSubposts() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(userIDs: [77]))

        var continuityOnly = Tieba_Post()
        continuityOnly.floor = 4
        continuityOnly.subPostNumber = 3
        continuityOnly.authorID = 77
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: continuityOnly))

        var sameShapeOtherAuthor = continuityOnly
        sameShapeOtherAuthor.authorID = 78
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: sameShapeOtherAuthor))
    }

    func testBlocklistDropsPostsByKeywordButKeepsVoiceFloors() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["安利链接"]))

        var matching = Tieba_Post()
        matching.floor = 2
        var text = Tieba_PbContent()
        text.text = "楼层里有安利链接出现"
        matching.content = [text]
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: matching))

        var voice = Tieba_PbContent()
        voice.type = 10
        voice.voiceMd5 = "0123456789abcdef0123456789abcdef"
        var voiceOnly = Tieba_Post()
        voiceOnly.floor = 5
        voiceOnly.content = [voice]
        XCTAssertTrue(TiebaContentFilter.shouldKeep(post: voiceOnly))
    }

    func testBlocklistFiltersSubpostsByAuthorAndKeyword() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["敏感词"], userIDs: [5]))

        var byAuthor = Tieba_SubPostList()
        byAuthor.authorID = 5
        XCTAssertFalse(TiebaContentFilter.shouldKeep(subpost: byAuthor))

        var byKeyword = Tieba_SubPostList()
        byKeyword.authorID = 6
        var text = Tieba_PbContent()
        text.text = "含敏感词的回复"
        byKeyword.content = [text]
        XCTAssertFalse(TiebaContentFilter.shouldKeep(subpost: byKeyword))

        var clean = Tieba_SubPostList()
        clean.authorID = 6
        var cleanText = Tieba_PbContent()
        cleanText.text = "普通回复"
        clean.content = [cleanText]
        XCTAssertTrue(TiebaContentFilter.shouldKeep(subpost: clean))
    }

    func testDomainModelsApplyBlocklistAcrossMajorLists() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(
            keywords: ["剧透"],
            userIDs: [42],
            forumNames: ["测试"]
        ))

        let blockedUser = UserSummary(
            id: 42,
            name: "blocked",
            displayName: "屏蔽用户",
            portrait: ""
        )
        let cleanUser = UserSummary(
            id: 7,
            name: "clean",
            displayName: "普通用户",
            portrait: ""
        )
        let forum = Forum(
            id: 1,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        let blockedThread = ThreadSummary(
            id: 1,
            title: "普通标题",
            author: blockedUser,
            forumName: "其他",
            replyCount: 0,
            viewCount: 0,
            blocks: []
        )
        let keywordThread = ThreadSummary(
            id: 2,
            title: "普通标题",
            author: cleanUser,
            forumName: "其他",
            replyCount: 0,
            viewCount: 0,
            blocks: [.text("这里包含剧透")]
        )
        let searchResult = SearchResult(
            threadID: 2,
            postID: nil,
            forumID: nil,
            forumName: "其他",
            forumAvatarURL: nil,
            title: "普通标题",
            content: "这里包含剧透",
            author: cleanUser,
            createdAt: nil,
            replyCount: 0,
            likeCount: 0,
            shareCount: 0,
            blocks: [],
            isReplyMatch: false
        )
        let post = Post(
            id: 1,
            threadID: 1,
            floor: 2,
            author: cleanUser,
            ipAddress: nil,
            createdAt: nil,
            blocks: [.text("回复中有剧透")],
            subpostCount: 0,
            likeCount: 0,
            previewSubposts: []
        )
        let subpost = Subpost(
            id: 1,
            floor: 1,
            author: blockedUser,
            ipAddress: nil,
            blocks: [.text("普通回复")],
            createdAt: nil,
            likeCount: 0
        )

        XCTAssertFalse(TiebaContentFilter.shouldKeep(user: blockedUser))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(forum: forum))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: blockedThread))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: keywordThread))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(searchResult: searchResult))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: post))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(subpost: subpost))
        XCTAssertTrue(TiebaContentFilter.shouldKeep(user: cleanUser))
    }

    func testOpenedThreadMainPostIsStructuralEvenWhenItsBodyMatchesBlocklist() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["剧透"]))
        let post = Post(
            id: 1,
            threadID: 1,
            floor: 1,
            author: UserSummary(
                id: 7,
                name: "author",
                displayName: "作者",
                portrait: ""
            ),
            ipAddress: nil,
            createdAt: nil,
            blocks: [.text("主楼正文包含剧透")],
            subpostCount: 0,
            likeCount: 0,
            previewSubposts: []
        )

        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: post))
        XCTAssertTrue(
            TiebaContentFilter.shouldKeep(
                post: post,
                asOpenedThreadMainPost: true
            )
        )
    }

    func testThreadPageMapperRetainsBlockedFirstFloorAsStructuralMainPost() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["隐藏主楼正文"]))

        var author = Tieba_User()
        author.id = 42
        author.nameShow = "楼主"

        var thread = Tieba_ThreadInfo()
        thread.id = 123
        thread.title = "摘要没有命中屏蔽词"
        thread.author = author

        var mainContent = Tieba_PbContent()
        mainContent.type = 0
        mainContent.text = "这段隐藏主楼正文只在完整内容中出现"

        var firstFloor = Tieba_Post()
        firstFloor.id = 11
        firstFloor.tid = 123
        firstFloor.floor = 1
        firstFloor.author = author
        firstFloor.content = [mainContent]

        var replyContent = Tieba_PbContent()
        replyContent.type = 0
        replyContent.text = "普通回复"

        var reply = Tieba_Post()
        reply.id = 12
        reply.tid = 123
        reply.floor = 2
        reply.author = author
        reply.content = [replyContent]

        var data = Tieba_PbPage_PbPageResponseData()
        data.thread = thread
        data.firstFloorPost = firstFloor
        data.postList = [reply]
        data.page.currentPage = 1
        data.page.totalPage = 1

        var response = Tieba_PbPage_PbPageResponse()
        response.data = data

        let page = PostMapper.threadPage(from: response)

        XCTAssertEqual(page.mainPost?.id, 11)
        XCTAssertEqual(page.mainPost?.contentPreview, mainContent.text)
        XCTAssertEqual(page.posts.map(\.id), [12])
        XCTAssertFalse(TiebaContentFilter.shouldKeep(post: firstFloor))
    }

    func testBlocklistFiltersMessagesByAuthorKeywordAndForum() {
        let blockedAuthor = UserSummary(
            id: 42,
            name: "blocked",
            displayName: "屏蔽用户",
            portrait: ""
        )
        let cleanAuthor = UserSummary(
            id: 7,
            name: "clean",
            displayName: "普通用户",
            portrait: ""
        )
        let base = MessageItem(
            id: "reply-1-2",
            kind: .reply,
            author: cleanAuthor,
            content: "普通回复",
            threadID: 1,
            postID: 2,
            threadTitle: "普通主题",
            forumName: "其他",
            isFloorReply: false,
            createdAt: nil
        )

        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(
            keywords: ["spoiler"],
            userIDs: [42],
            forumNames: ["测试"]
        ))

        var byAuthor = base
        byAuthor.author = blockedAuthor
        XCTAssertFalse(TiebaContentFilter.shouldKeep(message: byAuthor))

        var byContent = base
        byContent.content = "回复中有 SPOILER"
        XCTAssertFalse(TiebaContentFilter.shouldKeep(message: byContent))

        var byTitle = base
        byTitle.threadTitle = "Spoiler 主题"
        XCTAssertFalse(TiebaContentFilter.shouldKeep(message: byTitle))

        var byForum = base
        byForum.forumName = "测试吧"
        XCTAssertFalse(TiebaContentFilter.shouldKeep(message: byForum))

        XCTAssertTrue(TiebaContentFilter.shouldKeep(message: base))
    }

    func testFilteredMessagePageKeepsRawServerPagination() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(keywords: ["屏蔽词"]))
        let blocked = MessageItem(
            id: "reply-1-2",
            kind: .reply,
            author: UserSummary(id: 7, name: "clean", displayName: "普通用户", portrait: ""),
            content: "包含屏蔽词",
            threadID: 1,
            postID: 2,
            threadTitle: "普通主题",
            forumName: "其他",
            isFloorReply: false,
            createdAt: nil
        )
        let rawPage = MessagesPage(items: [blocked], currentPage: 4, hasMore: true)

        XCTAssertTrue(rawPage.items.filter(TiebaContentFilter.shouldKeep(message:)).isEmpty)
        XCTAssertEqual(
            MessagePaginationPolicy.state(after: rawPage, requestedPage: 4),
            MessagePaginationState(nextPage: 5, hasMore: true)
        )
    }

    func testStructuralThreadFilterPreservesBlockedPageCardinality() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(userIDs: [42]))

        var blocked = Tieba_ThreadInfo()
        blocked.id = 1
        blocked.authorID = 42
        XCTAssertTrue(TiebaContentFilter.shouldMap(thread: blocked))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: blocked))

        var live = Tieba_ThreadInfo()
        live.id = 2
        live.alaInfo = Tieba_AlaLiveInfo()
        XCTAssertFalse(TiebaContentFilter.shouldMap(thread: live))
        XCTAssertFalse(TiebaContentFilter.shouldKeep(thread: live))
    }

    func testUserThreadPageKeepsHasMoreWhenOnlyRawItemIsBlocked() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(userIDs: [42]))

        var item = Tiebapure_Profile_UserThreadItem()
        item.threadID = 123
        item.userID = 42
        item.title = "会被本机屏蔽的帖子"
        var data = Tiebapure_Profile_UserThreadsResponseData()
        data.postList = [item]
        var response = Tiebapure_Profile_UserThreadsResponse()
        response.data = data

        let page = UserProfileMapper.threadsPage(from: response, page: 1)

        XCTAssertTrue(page.threads.isEmpty)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.currentPage, 1)
    }

    func testLocalForumBlockDoesNotChangeServerProfilePrivacy() {
        TiebaContentFilter.updateBlocklist(BlocklistSnapshot(forumNames: ["测试"]))

        var forum = Tieba_LikeForumInfo()
        forum.forumID = 1
        forum.forumName = "测试"
        var privacy = Tieba_PrivSets()
        privacy.like = 1
        var proto = Tieba_User()
        proto.id = 42
        proto.myLikeNum = 1
        proto.likeForum = [forum]
        proto.privSets = privacy

        let profile = UserProfileMapper.profile(
            from: proto,
            fallback: UserSummary(id: 42, name: "u", displayName: "用户", portrait: ""),
            isCurrentUser: false
        )

        XCTAssertEqual(profile.followedForumsVisibility, .visible)
        XCTAssertEqual(profile.followedForums.map(\.name), ["测试"])
        XCTAssertFalse(TiebaContentFilter.shouldKeep(forum: profile.followedForums[0]))
    }

    @MainActor
    func testBlocklistStoreTrimsDeduplicatesAndCapsPerKind() throws {
        let suiteName = "BlocklistStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var snapshots: [BlocklistSnapshot] = []
        let store = BlocklistStore(
            defaults: defaults,
            key: "blocklist",
            limitPerKind: 2
        ) { snapshots.append($0) }

        store.addKeyword("  Spoiler  ")
        store.addKeyword("spoiler")
        XCTAssertEqual(store.entries(of: .keyword).map(\.value), ["spoiler"])

        store.addKeyword("第二个")
        store.addKeyword("第三个")
        XCTAssertEqual(store.entries(of: .keyword).map(\.value), ["第三个", "第二个"])

        store.addUser(id: 42, displayName: "用户甲")
        store.addUser(id: 42, displayName: "用户甲改名")
        XCTAssertEqual(store.entries(of: .user).count, 1)
        XCTAssertEqual(store.entries(of: .user).first?.value, "用户甲改名")
        XCTAssertTrue(snapshots.last?.userNames.contains(TiebaUserName.normalized("用户甲改名")) == true)

        store.addForum(named: "  Steam吧  ")
        store.addForum(named: "steam")
        XCTAssertEqual(store.entries(of: .forum).map(\.value), ["steam"])

        // The keyword cap must not bleed into other kinds.
        XCTAssertEqual(store.entries.count, 4)

        XCTAssertEqual(snapshots.last?.keywords, Set(["第三个", "第二个"]))
        XCTAssertEqual(snapshots.last?.userIDs, Set([42]))
        XCTAssertEqual(snapshots.last?.forumNames, Set(["steam"]))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testBlocklistStorePersistsRoundTripAndSkipsCorruptElements() throws {
        let suiteName = "BlocklistStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let key = "blocklist"

        let store = BlocklistStore(defaults: defaults, key: key, publishSnapshot: { _ in })
        store.addKeyword("剧透")
        store.addUser(id: 9, displayName: "屏蔽对象")
        store.addUser(id: nil, displayName: "只按名字")
        store.addForum(named: "示例")

        let reloaded = BlocklistStore(defaults: defaults, key: key, publishSnapshot: { _ in })
        XCTAssertEqual(reloaded.entries, store.entries)

        // Element-tolerant decode: one corrupt element must not wipe the rest.
        let corrupted = """
        [{"kind":"keyword","value":"有效"},{"kind":"unknown-kind","value":"无效"},12]
        """
        defaults.set(Data(corrupted.utf8), forKey: key)
        reloaded.reload()
        XCTAssertEqual(reloaded.entries.map(\.value), ["有效"])

        reloaded.clear(kind: .keyword)
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertNil(defaults.object(forKey: key))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testBlocklistStorePersistsIDOnlyForumWithReadableLabelAndLoadsLegacyJSON() throws {
        let suiteName = "BlocklistStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let key = "blocklist"
        var snapshots: [BlocklistSnapshot] = []
        let store = BlocklistStore(
            defaults: defaults,
            key: key
        ) { snapshots.append($0) }

        store.addForum(id: 2468, named: nil)
        let idOnly = try XCTUnwrap(store.entries(of: .forum).first)
        XCTAssertEqual(idOnly.forumID, 2468)
        XCTAssertEqual(idOnly.value, "贴吧 ID 2468")
        XCTAssertEqual(snapshots.last?.forumIDs, Set([2468]))
        XCTAssertTrue(snapshots.last?.forumNames.isEmpty == true)

        let reloaded = BlocklistStore(
            defaults: defaults,
            key: key,
            publishSnapshot: { _ in }
        )
        XCTAssertEqual(reloaded.entries, store.entries)

        store.addForum(id: 2468, named: "示例吧")
        XCTAssertEqual(store.entries(of: .forum).count, 1)
        XCTAssertEqual(store.entries(of: .forum).first?.value, "示例")
        XCTAssertEqual(snapshots.last?.forumIDs, Set([2468]))
        XCTAssertEqual(snapshots.last?.forumNames, Set(["示例"]))

        let legacyJSON = """
        [{"kind":"forum","value":" Steam吧 "}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: key)
        reloaded.reload()
        let legacy = try XCTUnwrap(reloaded.entries(of: .forum).first)
        XCTAssertNil(legacy.forumID)
        XCTAssertEqual(legacy.value, "steam")
        XCTAssertTrue(BlocklistSnapshot(entries: reloaded.entries).blocksForum(named: "STEAM吧"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testBlocklistStoreTogglesUserByIDAndByName() throws {
        let suiteName = "BlocklistStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = BlocklistStore(defaults: defaults, key: "blocklist", publishSnapshot: { _ in })

        XCTAssertTrue(store.toggleUser(id: 7, displayName: "样例用户"))
        XCTAssertTrue(store.isUserBlocked(id: 7, displayName: "改名后"))
        XCTAssertTrue(store.isUserBlocked(id: 0, displayName: "样例用户"))
        XCTAssertFalse(store.toggleUser(id: 7, displayName: "改名后"))
        XCTAssertFalse(store.isUserBlocked(id: 7, displayName: "样例用户"))

        store.addUser(id: nil, displayName: "只按名字")
        XCTAssertTrue(store.isUserBlocked(id: 123, displayName: "@只按名字"))
        XCTAssertFalse(store.toggleUser(id: 123, displayName: "只按名字"))
        XCTAssertTrue(store.entries(of: .user).isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testBlocklistPolicyCapsPersistedValueLengths() {
        let keyword = BlocklistPolicy.normalized(
            BlocklistEntry(kind: .keyword, value: String(repeating: "字", count: 500), userID: nil)
        )
        let user = BlocklistPolicy.normalized(
            BlocklistEntry(kind: .user, value: String(repeating: "人", count: 500), userID: 1)
        )
        let forum = BlocklistPolicy.normalized(
            BlocklistEntry(kind: .forum, value: String(repeating: "吧", count: 500), userID: nil)
        )

        XCTAssertEqual(keyword?.value.count, BlocklistPolicy.maximumKeywordCharacters)
        XCTAssertEqual(user?.value.count, BlocklistPolicy.maximumUserNameCharacters)
        XCTAssertEqual(forum?.value.count, BlocklistPolicy.maximumForumNameCharacters)
    }
}
