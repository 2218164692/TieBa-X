import SwiftProtobuf
import XCTest
@testable import TieBaX

final class FixtureDecodingTests: XCTestCase {
    private struct WireField: Equatable {
        var number: Int
        var wireType: UInt8
    }

    /// Hand-encoded wire bytes, deliberately not produced by SwiftProtobuf,
    /// so field-number or wire-type drift in the generated schemas fails the
    /// decode instead of round-tripping silently. The message is a minimal
    /// PbPageResponse: data(2) holding page(3){current_page 1, total_page 2,
    /// has_more 1}, one post_list(6) entry {id 9001, floor 1, author_id 77}
    /// whose content(5) carries a type-0 text block, a type-3 image block and
    /// a type-5 video block, thread(8){id 654321, title, replyNum 2,
    /// authorId 77} and one user_list(13) entry {id 77, name, nameShow}.
    private static let threadPageWireHex =
        "12f6021a0618012802300132ac0208a94618012a100800120ce6a5bce4b8bbe6"
        + "ada3e696872a780803222f68747470733a2f2f696d6773612e62616964752e63"
        + "6f6d2f666f72756d2f7069632f6974656d2f776972652e6a70672a073732302c"
        + "393630ca013668747470733a2f2f696d6773612e62616964752e636f6d2f666f"
        + "72756d2f7069632f6974656d2f776972655f6f726967696e2e6a70679802012a"
        + "95010805122068747470733a2f2f74696562612e62616964752e636f6d2f702f"
        + "3635343332311a2c68747470733a2f2f74622d766964656f2e62647374617469"
        + "632e636f6d2f766964656f2f776972652e6d7034223568747470733a2f2f696d"
        + "6773612e62616964752e636f6d2f666f72756d2f7069632f6974656d2f776972"
        + "655f636f7665722e6a70672a08313238302c373230685f98014d421d08f1f727"
        + "1a12e7babfe6a0bce5bc8fe6b58be8af95e5b8962002c0034d6a1e104d1a0977"
        + "6972655f75736572220fe7babfe6a0bce5bc8fe794a8e688b7"

    func testHandCraftedThreadPageWireBytesDecodeAndMapToDomain() throws {
        let wireData = try XCTUnwrap(Self.data(hex: Self.threadPageWireHex))
        let decoded = try Tieba_PbPage_PbPageResponse(serializedBytes: wireData)

        XCTAssertEqual(decoded.data.page.currentPage, 1)
        XCTAssertEqual(decoded.data.page.totalPage, 2)
        XCTAssertEqual(decoded.data.thread.id, 654321)
        XCTAssertEqual(decoded.data.thread.title, "线格式测试帖")
        XCTAssertEqual(decoded.data.postList.count, 1)
        XCTAssertEqual(decoded.data.postList.first?.content.count, 3)
        XCTAssertEqual(decoded.data.userList.first?.id, 77)
        XCTAssertEqual(decoded.data.userList.first?.nameShow, "线格式用户")

        let page = PostMapper.threadPage(from: decoded)

        XCTAssertEqual(page.thread.id, 654321)
        XCTAssertEqual(page.thread.title, "线格式测试帖")
        XCTAssertEqual(page.thread.replyCount, 2)
        XCTAssertEqual(page.thread.author.id, 77)
        XCTAssertEqual(page.thread.author.name, "wire_user")
        XCTAssertEqual(page.thread.author.displayName, "线格式用户")
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertEqual(page.totalPage, 2)
        XCTAssertTrue(page.hasMore)

        let mainPost = try XCTUnwrap(page.mainPost)
        XCTAssertEqual(mainPost.id, 9001)
        XCTAssertEqual(mainPost.threadID, 654321)
        XCTAssertEqual(mainPost.floor, 1)
        XCTAssertEqual(mainPost.author.id, 77)
        XCTAssertEqual(mainPost.author.name, "wire_user")
        XCTAssertEqual(mainPost.blocks, [
            .text("楼主正文"),
            .image(ImageContent(
                thumbnailURL: URL(string: "https://imgsa.baidu.com/forum/pic/item/wire.jpg"),
                originalURL: URL(string: "https://imgsa.baidu.com/forum/pic/item/wire_origin.jpg"),
                width: 720,
                height: 960,
                showOriginalButton: true
            )),
            .video(VideoContent(
                videoURL: URL(string: "https://tb-video.bdstatic.com/video/wire.mp4"),
                coverURL: URL(string: "https://imgsa.baidu.com/forum/pic/item/wire_cover.jpg"),
                webURL: URL(string: "https://tieba.baidu.com/p/654321"),
                width: 1280,
                height: 720,
                duration: 95
            ))
        ])
    }

    func testHandCraftedPersonalizedWireBytesDecodeThreadAndAuthor() throws {
        let author = Self.message([
            .varint(2, 88),
            .string(3, "personalized_user"),
            .string(4, "推荐流用户")
        ])
        let thread = Self.message([
            .varint(1, 765_432),
            .string(3, "推荐流线格式主题"),
            .varint(4, 9),
            .varint(5, 120),
            .message(18, author),
            .varint(27, 66),
            .string(28, "推荐测试"),
            .varint(56, 88),
            .message(142, Self.message([.varint(1, 0), .string(2, "推荐流正文")]))
        ])
        let response = Self.message([
            .message(2, Self.message([.message(2, thread)]))
        ])

        let decoded = try Tieba_PersonalizedResponse(serializedBytes: response)
        let proto = try XCTUnwrap(decoded.data.threadList.first)
        let mapped = ThreadMapper.fromThreadInfo(proto, usersByID: [:])

        XCTAssertEqual(decoded.data.threadList.count, 1)
        XCTAssertEqual(mapped.id, 765_432)
        XCTAssertEqual(mapped.title, "推荐流线格式主题")
        XCTAssertEqual(mapped.author.id, 88)
        XCTAssertEqual(mapped.author.displayName, "推荐流用户")
        XCTAssertEqual(mapped.forumID, 66)
        XCTAssertEqual(mapped.forumName, "推荐测试")
        XCTAssertEqual(mapped.blocks, [.text("推荐流正文")])
    }

    func testRequestSchemasPreserveFieldNumbersWireTypesAndPresence() throws {
        var common = Tieba_CommonRequest()
        common.bduss = "BDUSS"
        common.stoken = "STOKEN"
        common.qType = 0
        common.isTeenager = 0
        XCTAssertEqual(
            try Self.fields(in: common.serializedData()),
            [
                WireField(number: 10, wireType: 2),
                WireField(number: 30, wireType: 2),
                WireField(number: 40, wireType: 0),
                WireField(number: 41, wireType: 0)
            ]
        )

        var frs = Tieba_FrsPage_FrsPageRequestData()
        frs.kw = "测试"
        frs.isGood = 1
        frs.cid = 0
        frs.pn = 2
        frs.common = Tieba_CommonRequest()
        frs.sortType = -1
        frs.loadType = 2
        frs.appPos = Tieba_AppPosInfo()
        frs.adParam = Tieba_FrsPage_AdParam()
        XCTAssertEqual(
            try Self.fields(in: frs.serializedData()),
            [
                WireField(number: 1, wireType: 2),
                WireField(number: 4, wireType: 0),
                WireField(number: 5, wireType: 0),
                WireField(number: 15, wireType: 0),
                WireField(number: 39, wireType: 2),
                WireField(number: 47, wireType: 0),
                WireField(number: 49, wireType: 0),
                WireField(number: 50, wireType: 2),
                WireField(number: 51, wireType: 2)
            ]
        )

        var page = Tieba_PbPage_PbPageRequestData()
        page.kz = 123
        page.lz = 1
        page.r = 2
        page.pid = 456
        page.withFloor = 1
        page.floorRn = 4
        page.rn = 15
        page.pn = 3
        page.common = Tieba_CommonRequest()
        page.forumID = 789
        page.floorSortType = 1
        page.sourceType = 2
        XCTAssertEqual(
            try Self.fields(in: page.serializedData()),
            [
                WireField(number: 4, wireType: 0),
                WireField(number: 5, wireType: 0),
                WireField(number: 6, wireType: 0),
                WireField(number: 7, wireType: 0),
                WireField(number: 8, wireType: 0),
                WireField(number: 9, wireType: 0),
                WireField(number: 13, wireType: 0),
                WireField(number: 18, wireType: 0),
                WireField(number: 25, wireType: 2),
                WireField(number: 56, wireType: 0),
                WireField(number: 74, wireType: 0),
                WireField(number: 75, wireType: 0)
            ]
        )

        var floor = Tieba_PbFloor_PbFloorRequestData()
        floor.kz = 123
        floor.pid = 456
        floor.spid = 789
        floor.pn = 2
        floor.common = Tieba_CommonRequest()
        floor.isCommReverse = 0
        floor.forumID = 42
        floor.oriUgcType = 0
        XCTAssertEqual(
            try Self.fields(in: floor.serializedData()),
            [
                WireField(number: 1, wireType: 0),
                WireField(number: 2, wireType: 0),
                WireField(number: 3, wireType: 0),
                WireField(number: 4, wireType: 0),
                WireField(number: 9, wireType: 2),
                WireField(number: 10, wireType: 0),
                WireField(number: 11, wireType: 0),
                WireField(number: 15, wireType: 0)
            ]
        )

        var personalized = Tieba_PersonalizedRequestData()
        personalized.common = Tieba_CommonRequest()
        personalized.loadType = 2
        personalized.pn = 3
        personalized.scrDip = 3
        personalized.needForumlist = 1
        personalized.appPos = Tieba_AppPosInfo()
        XCTAssertEqual(
            try Self.fields(in: personalized.serializedData()),
            [
                WireField(number: 1, wireType: 2),
                WireField(number: 4, wireType: 0),
                WireField(number: 6, wireType: 0),
                WireField(number: 10, wireType: 1),
                WireField(number: 22, wireType: 0),
                WireField(number: 36, wireType: 2)
            ]
        )

        var profile = Tiebax_Profile_UserProfileRequestData()
        profile.uid = 0
        profile.friendUid = 77
        profile.pn = 2
        profile.common = Tieba_CommonRequest()
        XCTAssertTrue(profile.hasUid)
        XCTAssertTrue(profile.hasFriendUid)
        XCTAssertEqual(
            try Self.fields(in: profile.serializedData()),
            [
                WireField(number: 1, wireType: 0),
                WireField(number: 3, wireType: 0),
                WireField(number: 6, wireType: 0),
                WireField(number: 9, wireType: 2)
            ]
        )

        var userThreads = Tiebax_Profile_UserThreadsRequestData()
        userThreads.uid = 77
        userThreads.isThread = 0
        userThreads.pn = 2
        userThreads.common = Tieba_CommonRequest()
        userThreads.isViewCard = 0
        XCTAssertTrue(userThreads.hasIsThread)
        XCTAssertTrue(userThreads.hasIsViewCard)
        XCTAssertEqual(
            try Self.fields(in: userThreads.serializedData()),
            [
                WireField(number: 1, wireType: 0),
                WireField(number: 4, wireType: 0),
                WireField(number: 26, wireType: 0),
                WireField(number: 27, wireType: 2),
                WireField(number: 33, wireType: 0)
            ]
        )
    }

    func testContentSubmissionCommonRequestPreservesPublishingWireContract() throws {
        let common = Self.publishingCommonRequest()

        XCTAssertTrue(common.hasBduss)
        XCTAssertTrue(common.hasTbs)
        XCTAssertTrue(common.hasStoken)
        XCTAssertTrue(common.hasCuidGid)
        XCTAssertTrue(common.hasQType)
        XCTAssertTrue(common.hasIsTeenager)
        XCTAssertEqual(
            try Self.fields(in: common.serializedData()),
            [
                WireField(number: 1, wireType: 0),
                WireField(number: 2, wireType: 2),
                WireField(number: 3, wireType: 2),
                WireField(number: 5, wireType: 2),
                WireField(number: 6, wireType: 2),
                WireField(number: 7, wireType: 2),
                WireField(number: 8, wireType: 0),
                WireField(number: 9, wireType: 2),
                WireField(number: 10, wireType: 2),
                WireField(number: 11, wireType: 2),
                WireField(number: 12, wireType: 0),
                WireField(number: 24, wireType: 2),
                WireField(number: 25, wireType: 2),
                WireField(number: 26, wireType: 2),
                WireField(number: 28, wireType: 2),
                WireField(number: 29, wireType: 2),
                WireField(number: 30, wireType: 2),
                WireField(number: 31, wireType: 2),
                WireField(number: 32, wireType: 2),
                WireField(number: 33, wireType: 2),
                WireField(number: 35, wireType: 2),
                WireField(number: 36, wireType: 2),
                WireField(number: 37, wireType: 0),
                WireField(number: 38, wireType: 0),
                WireField(number: 39, wireType: 1),
                WireField(number: 40, wireType: 0),
                WireField(number: 41, wireType: 0),
                WireField(number: 42, wireType: 2),
                WireField(number: 43, wireType: 2),
                WireField(number: 44, wireType: 2),
                WireField(number: 49, wireType: 0),
                WireField(number: 50, wireType: 0),
                WireField(number: 51, wireType: 0),
                WireField(number: 53, wireType: 2),
                WireField(number: 54, wireType: 2),
                WireField(number: 55, wireType: 0),
                WireField(number: 57, wireType: 0),
                WireField(number: 60, wireType: 2),
                WireField(number: 62, wireType: 2),
                WireField(number: 63, wireType: 0),
                WireField(number: 70, wireType: 2),
                WireField(number: 88, wireType: 2)
            ]
        )
    }

    func testContentSubmissionRequestsPreserveFieldNumbersAndOptionalPresence() throws {
        var emptyPost = Tieba_AddPostRequest.DataMessage()
        XCTAssertFalse(emptyPost.hasReplyUid)
        XCTAssertFalse(emptyPost.hasQuoteID)
        XCTAssertFalse(emptyPost.hasSubPostID)
        XCTAssertFalse(emptyPost.hasPostFrom)
        emptyPost.replyUid = ""
        XCTAssertTrue(emptyPost.hasReplyUid)
        XCTAssertEqual(
            try Self.fields(in: emptyPost.serializedData()),
            [WireField(number: 20, wireType: 2)]
        )

        var post = Tieba_AddPostRequest.DataMessage()
        post.common = Self.publishingCommonRequest()
        post.anonymous = "1"
        post.canNoForum = "0"
        post.isFeedback = "0"
        post.takephotoNum = "1"
        post.entranceType = "0"
        post.vcode = "{}"
        post.vcodeMd5 = "md5"
        post.vcodeType = "6"
        post.vcodeTag = "12"
        post.newVcode = "1"
        post.content = "回复正文"
        post.replyUid = "77"
        post.fid = "88"
        post.vFid = ""
        post.vFname = ""
        post.kw = "测试"
        post.isBarrage = "0"
        post.barrageTime = "0"
        post.fromFourmID = "88"
        post.tid = "654321"
        post.quoteID = "9001"
        post.floorNum = "2"
        post.repostid = "9001"
        post.subPostID = "9101"
        post.isAd = "0"
        post.isAddition = "0"
        post.isGiftpost = "0"
        post.postFrom = "0"
        post.nameShow = "线格式用户"
        post.isPictxt = "1"
        post.showCustomFigure = 0
        post.isShowBless = 0

        var postRequest = Tieba_AddPostRequest()
        postRequest.data = post
        XCTAssertEqual(
            try Self.fields(in: postRequest.serializedData()),
            [WireField(number: 1, wireType: 2)]
        )
        XCTAssertEqual(
            try Self.fields(in: post.serializedData()),
            [
                WireField(number: 1, wireType: 2),
                WireField(number: 6, wireType: 2),
                WireField(number: 7, wireType: 2),
                WireField(number: 8, wireType: 2),
                WireField(number: 9, wireType: 2),
                WireField(number: 10, wireType: 2),
                WireField(number: 13, wireType: 2),
                WireField(number: 14, wireType: 2),
                WireField(number: 15, wireType: 2),
                WireField(number: 16, wireType: 2),
                WireField(number: 18, wireType: 2),
                WireField(number: 19, wireType: 2),
                WireField(number: 20, wireType: 2),
                WireField(number: 26, wireType: 2),
                WireField(number: 28, wireType: 2),
                WireField(number: 29, wireType: 2),
                WireField(number: 30, wireType: 2),
                WireField(number: 31, wireType: 2),
                WireField(number: 32, wireType: 2),
                WireField(number: 44, wireType: 2),
                WireField(number: 45, wireType: 2),
                WireField(number: 46, wireType: 2),
                WireField(number: 48, wireType: 2),
                WireField(number: 49, wireType: 2),
                WireField(number: 50, wireType: 2),
                WireField(number: 51, wireType: 2),
                WireField(number: 52, wireType: 2),
                WireField(number: 53, wireType: 2),
                WireField(number: 55, wireType: 2),
                WireField(number: 58, wireType: 2),
                WireField(number: 60, wireType: 2),
                WireField(number: 64, wireType: 0),
                WireField(number: 67, wireType: 0)
            ]
        )
        XCTAssertTrue(post.hasReplyUid)
        XCTAssertTrue(post.hasQuoteID)
        XCTAssertTrue(post.hasRepostid)
        XCTAssertTrue(post.hasSubPostID)
        XCTAssertTrue(post.hasPostFrom)

        let emptyThread = Tieba_AddThreadRequest.DataMessage()
        XCTAssertFalse(emptyThread.hasIsQuestion)
        XCTAssertFalse(emptyThread.hasIsShowBless)

        var thread = Tieba_AddThreadRequest.DataMessage()
        thread.common = Self.publishingCommonRequest()
        thread.anonymous = "1"
        thread.canNoForum = "0"
        thread.isFeedback = "0"
        thread.takephotoNum = "1"
        thread.entranceType = "1"
        thread.vcode = "{}"
        thread.vcodeMd5 = "md5"
        thread.vcodeType = "6"
        thread.vcodeTag = "12"
        thread.newVcode = "1"
        thread.content = "主题正文"
        thread.fid = "88"
        thread.kw = "测试"
        thread.isHide = "0"
        thread.isRepostToDynamic = "0"
        thread.proZone = "0"
        thread.callFrom = "2"
        thread.title = "线格式主题"
        thread.isNtitle = "0"
        thread.isLinkThread = "0"
        thread.isForumBusinessAccount = "0"
        thread.nameShow = "线格式用户"
        thread.isPictxt = "1"
        thread.isArticle = "0"
        thread.showCustomFigure = 0
        thread.isQuestion = 0
        thread.isXiuxiuThread = 0
        thread.isShowBless = 0
        thread.ext = #"{"need_image":1,"need_follow_forum":0}"#

        var threadRequest = Tieba_AddThreadRequest()
        threadRequest.data = thread
        XCTAssertEqual(
            try Self.fields(in: threadRequest.serializedData()),
            [WireField(number: 1, wireType: 2)]
        )
        XCTAssertEqual(
            try Self.fields(in: thread.serializedData()),
            [
                WireField(number: 1, wireType: 2),
                WireField(number: 6, wireType: 2),
                WireField(number: 7, wireType: 2),
                WireField(number: 8, wireType: 2),
                WireField(number: 9, wireType: 2),
                WireField(number: 10, wireType: 2),
                WireField(number: 13, wireType: 2),
                WireField(number: 14, wireType: 2),
                WireField(number: 15, wireType: 2),
                WireField(number: 16, wireType: 2),
                WireField(number: 18, wireType: 2),
                WireField(number: 19, wireType: 2),
                WireField(number: 26, wireType: 2),
                WireField(number: 27, wireType: 2),
                WireField(number: 29, wireType: 2),
                WireField(number: 30, wireType: 2),
                WireField(number: 36, wireType: 2),
                WireField(number: 37, wireType: 2),
                WireField(number: 38, wireType: 2),
                WireField(number: 41, wireType: 2),
                WireField(number: 55, wireType: 2),
                WireField(number: 63, wireType: 2),
                WireField(number: 75, wireType: 2),
                WireField(number: 77, wireType: 2),
                WireField(number: 79, wireType: 2),
                WireField(number: 80, wireType: 0),
                WireField(number: 83, wireType: 0),
                WireField(number: 86, wireType: 0),
                WireField(number: 87, wireType: 0),
                WireField(number: 96, wireType: 2)
            ]
        )
        XCTAssertTrue(thread.hasIsQuestion)
        XCTAssertTrue(thread.hasIsXiuxiuThread)
        XCTAssertTrue(thread.hasIsShowBless)
    }

    func testHandCraftedContentSubmissionResponseWireBytesDecodeRequiredFields() throws {
        let verification = Self.message([
            .string(3, "1"),
            .string(4, "wire-vcode-md5"),
            .string(6, "6"),
            .string(12, "https://tieba.baidu.com/cgi-bin/genimg?wire")
        ])
        let postWire = Self.message([
            .message(1, Self.message([
                .varint(1, 0),
                .string(2, ""),
                .string(3, "请完成验证")
            ])),
            .message(2, Self.message([
                .string(2, "654321"),
                .string(3, "9001"),
                .string(5, "回复待验证"),
                .string(6, "验证后继续"),
                .string(7, "安全验证"),
                .message(14, verification)
            ]))
        ])

        let post = try Tieba_AddPostResponse(serializedBytes: postWire)
        XCTAssertEqual(post.error.errorCode, 0)
        XCTAssertEqual(post.error.userMsg, "请完成验证")
        XCTAssertEqual(post.data.tid, "654321")
        XCTAssertEqual(post.data.pid, "9001")
        XCTAssertEqual(post.data.msg, "回复待验证")
        XCTAssertEqual(post.data.preMsg, "验证后继续")
        XCTAssertEqual(post.data.colorMsg, "安全验证")
        XCTAssertEqual(post.data.info.needVcode, "1")
        XCTAssertEqual(post.data.info.vcodeMd5, "wire-vcode-md5")
        XCTAssertEqual(post.data.info.vcodeType, "6")
        XCTAssertEqual(
            post.data.info.vcodePicURL,
            "https://tieba.baidu.com/cgi-bin/genimg?wire"
        )

        let threadWire = Self.message([
            .message(1, Self.message([
                .varint(1, 7),
                .string(2, "操作频繁"),
                .string(3, "请稍后重试")
            ])),
            .message(2, Self.message([
                .string(2, "765432"),
                .string(3, "9101"),
                .string(5, "发帖失败"),
                .message(14, Self.message([.string(3, "0")]))
            ]))
        ])

        let thread = try Tieba_AddThreadResponse(serializedBytes: threadWire)
        XCTAssertEqual(thread.error.errorCode, 7)
        XCTAssertEqual(thread.error.errorMsg, "操作频繁")
        XCTAssertEqual(thread.error.userMsg, "请稍后重试")
        XCTAssertEqual(thread.data.tid, "765432")
        XCTAssertEqual(thread.data.pid, "9101")
        XCTAssertEqual(thread.data.msg, "发帖失败")
        XCTAssertEqual(thread.data.info.needVcode, "0")
    }

    func testHandCraftedForumWireBytesDecodeUsersAndThreads() throws {
        let author = Self.message([
            .varint(2, 77),
            .string(3, "wire_user"),
            .string(4, "线格式用户"),
            .string(125, "协议测试")
        ])
        let thread = Self.message([
            .varint(1, 654_321),
            .string(3, "线格式吧页主题"),
            .varint(4, 12),
            .varint(5, 345),
            .varint(27, 88),
            .string(28, "测试"),
            .varint(56, 77),
            .message(142, Self.message([.varint(1, 0), .string(2, "主题正文")]))
        ])
        let response = Self.message([
            .message(2, Self.message([
                .message(7, thread),
                .message(17, author)
            ]))
        ])

        let decoded = try Tieba_FrsPage_FrsPageResponse(serializedBytes: response)
        XCTAssertEqual(decoded.data.threadList.count, 1)
        XCTAssertEqual(decoded.data.userList.count, 1)

        let users = Dictionary(uniqueKeysWithValues: decoded.data.userList.map { ($0.id, $0) })
        let mapped = ThreadMapper.fromThreadInfo(try XCTUnwrap(decoded.data.threadList.first), usersByID: users)
        XCTAssertEqual(mapped.id, 654_321)
        XCTAssertEqual(mapped.title, "线格式吧页主题")
        XCTAssertEqual(mapped.author.displayName, "线格式用户")
        XCTAssertEqual(mapped.author.levelName, "协议测试")
        XCTAssertEqual(mapped.forumID, 88)
        XCTAssertEqual(mapped.forumName, "测试")
        XCTAssertEqual(mapped.blocks, [.text("主题正文")])
    }

    func testHandCraftedFloorWireBytesDecodeReplyMetadata() throws {
        let author = Self.message([
            .varint(2, 77),
            .string(3, "reply_user"),
            .string(4, "回复用户"),
            .string(127, "广东")
        ])
        let content = Self.message([.varint(1, 0), .string(2, "楼中楼正文")])
        let agree = Self.message([.varint(1, 23), .varint(2, 1)])
        let location = Self.message([.string(3, "深圳")])
        let subpost = Self.message([
            .varint(1, 9_001),
            .message(2, content),
            .varint(3, 1_720_000_000),
            .varint(4, 77),
            .varint(6, 3),
            .message(7, author),
            .message(9, agree),
            .message(10, location)
        ])
        let response = Self.message([
            .message(2, Self.message([.message(4, subpost)]))
        ])

        let decoded = try Tieba_PbFloor_PbFloorResponse(serializedBytes: response)
        let proto = try XCTUnwrap(decoded.data.subpostList.first)
        XCTAssertEqual(proto.location.name, "深圳")
        XCTAssertEqual(proto.author.ipAddress, "广东")
        let mapped = PostMapper.subpost(proto)
        XCTAssertEqual(mapped.id, 9_001)
        XCTAssertEqual(mapped.floor, 3)
        XCTAssertEqual(mapped.author.displayName, "回复用户")
        XCTAssertEqual(mapped.ipAddress, "广东")
        XCTAssertEqual(mapped.likeCount, 23)
        XCTAssertTrue(mapped.isLiked)
        XCTAssertEqual(mapped.blocks, [.text("楼中楼正文")])
    }

    func testHandCraftedProfileWireBytesPreserveHighNumberedUserFields() throws {
        let forum = Self.message([.string(1, "测试"), .varint(2, 88)])
        let privacy = Self.message([.varint(2, 1)])
        let user = Self.message([
            .varint(2, 77),
            .string(3, "wire_user"),
            .string(4, "线格式用户"),
            .varint(30, 56),
            .varint(31, 34),
            .varint(33, 1),
            .varint(35, 1),
            .string(38, "8.5"),
            .message(45, privacy),
            .message(47, forum),
            .varint(87, 12),
            .varint(118, 4_321),
            .string(120, "tieba-wire-id"),
            .string(125, "协议测试"),
            .string(127, "广东"),
            .string(138, "简介")
        ])
        let response = Self.message([
            .message(2, Self.message([.message(1, user)]))
        ])

        let decoded = try Tiebax_Profile_UserProfileResponse(serializedBytes: response)
        let profile = UserProfileMapper.profile(
            from: decoded.data.user,
            fallback: UserSummary(id: 77, name: "wire_user", displayName: "线格式用户", portrait: ""),
            isCurrentUser: false
        )
        XCTAssertTrue(profile.isFollowed)
        XCTAssertEqual(profile.tiebaID, "tieba-wire-id")
        XCTAssertEqual(profile.tiebaAge, "8.5")
        XCTAssertEqual(profile.location, "广东")
        XCTAssertEqual(profile.intro, "简介")
        XCTAssertEqual(profile.agreeCount, 4_321)
        XCTAssertEqual(profile.followingCount, 34)
        XCTAssertEqual(profile.followerCount, 56)
        XCTAssertEqual(profile.threadCount, 12)
        XCTAssertEqual(profile.followedForums.map(\.name), ["测试"])
        XCTAssertEqual(decoded.data.user.privSets.like, 1)
        XCTAssertEqual(profile.followedForumsVisibility, .visible)
    }

    func testHandCraftedUserThreadsWireBytesDecodeContentAndPrivacy() throws {
        let post = Self.message([
            .varint(1, 66),
            .varint(2, 765_432),
            .varint(5, 1_720_000_000),
            .string(6, "推荐测试"),
            .string(7, "用户主题线格式"),
            .string(9, "用户主题正文"),
            .string(10, "user_threads"),
            .string(11, "广东"),
            .varint(17, 15),
            .varint(18, 88),
            .string(19, "portrait-token"),
            .string(35, "用户主题作者"),
            .varint(37, 23),
            .varint(38, 456)
        ])
        let visibleResponse = Self.message([
            .message(2, Self.message([.message(1, post)]))
        ])

        let decoded = try Tiebax_Profile_UserThreadsResponse(serializedBytes: visibleResponse)
        let page = UserProfileMapper.threadsPage(from: decoded, page: 1)
        let thread = try XCTUnwrap(page.threads.first)

        XCTAssertEqual(page.visibility, .visible)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(thread.id, 765_432)
        XCTAssertEqual(thread.forumID, 66)
        XCTAssertEqual(thread.forumName, "推荐测试")
        XCTAssertEqual(thread.author.id, 88)
        XCTAssertEqual(thread.author.displayName, "用户主题作者")
        XCTAssertEqual(thread.author.ipAddress, "广东")
        XCTAssertEqual(thread.replyCount, 15)
        XCTAssertEqual(thread.likeCount, 23)
        XCTAssertEqual(thread.viewCount, 456)
        XCTAssertEqual(thread.blocks, [.text("用户主题正文")])

        let privateResponse = Self.message([
            .message(2, Self.message([.varint(2, 1)]))
        ])
        let privateDecoded = try Tiebax_Profile_UserThreadsResponse(serializedBytes: privateResponse)
        let privatePage = UserProfileMapper.threadsPage(from: privateDecoded, page: 1)
        XCTAssertEqual(privatePage.visibility, .privateContent)
        XCTAssertFalse(privatePage.hasMore)
        XCTAssertTrue(privatePage.threads.isEmpty)
    }

    func testHandCraftedVoiceWireFieldsDecodeAndMapAcrossThreadLists() throws {
        let uppercaseMD5 = "ABCDEF0123456789ABCDEF0123456789"
        let voice = Self.message([
            .varint(2, 3_456),
            .string(3, uppercaseMD5)
        ])
        let threadWire = Self.message([
            .varint(1, 123),
            .varint(15, 1),
            .message(23, voice)
        ])

        let decodedThread = try Tieba_ThreadInfo(serializedBytes: threadWire)
        XCTAssertEqual(decodedThread.isVoiceThread, 1)
        XCTAssertEqual(decodedThread.voiceInfo.first?.duringTime, 3_456)
        XCTAssertEqual(decodedThread.voiceInfo.first?.voiceMd5, uppercaseMD5)

        let threadSummary = ThreadMapper.fromThreadInfo(decodedThread, usersByID: [:])
        guard case let .voice(threadVoice)? = threadSummary.blocks.first else {
            return XCTFail("expected thread voice")
        }
        XCTAssertEqual(threadVoice.md5, uppercaseMD5.lowercased())
        XCTAssertEqual(threadVoice.durationMilliseconds, 3_456)

        let profileItemWire = Self.message([
            .varint(2, 456),
            .message(23, voice)
        ])
        let decodedItem = try Tiebax_Profile_UserThreadItem(serializedBytes: profileItemWire)
        XCTAssertEqual(decodedItem.voiceInfo.count, 1)

        let profileSummary = try XCTUnwrap(UserProfileMapper.thread(from: decodedItem))
        guard case let .voice(profileVoice)? = profileSummary.blocks.first else {
            return XCTFail("expected profile voice")
        }
        XCTAssertEqual(profileVoice.md5, uppercaseMD5.lowercased())
        XCTAssertEqual(profileVoice.durationMilliseconds, 3_456)
    }

    private static func publishingCommonRequest() -> Tieba_CommonRequest {
        var common = Tieba_CommonRequest()
        common.clientType = 2
        common.clientVersion = "12.35.1.0"
        common.clientID = "wire-client-id"
        common.phoneImei = "000000000000000"
        common.from = "1008621x"
        common.cuid = "wire-cuid"
        common.timestamp = 1_700_000_000_000
        common.model = "wire-model"
        common.bduss = "wire-bduss"
        common.tbs = "wire-tbs"
        common.netType = 1
        common.pversion = "1.0.3"
        common.osVersion = "18.0"
        common.brand = "Apple"
        common.legoLibVersion = "3.0.0"
        common.applist = "[]"
        common.stoken = "wire-stoken"
        common.zID = "wire-z-id"
        common.cuidGalaxy2 = "wire-cuid"
        common.cuidGid = ""
        common.c3Aid = "wire-c3-aid"
        common.sampleID = "wire-sample-id"
        common.scrW = 1_179
        common.scrH = 2_556
        common.scrDip = 3
        common.qType = 0
        common.isTeenager = 0
        common.sdkVer = "2.34.0"
        common.frameworkVer = "3340042"
        common.nawsGameVer = "1038000"
        common.activeTimestamp = 1_699_000_000_000
        common.firstInstallTime = 1_699_000_000_000
        common.lastUpdateTime = 1_699_000_000_000
        common.eventDay = "20231114"
        common.androidID = "wire-android-id"
        common.cmode = 1
        common.startScheme = ""
        common.startType = 1
        common.idfv = "0"
        common.extra = ""
        common.userAgent = "TieBa-X/wire"
        common.personalizedRecSwitch = 1
        common.deviceScore = "0.4"
        common.packageVersion = "hybrid-main-pb_1.0.324.1"
        return common
    }

    private static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private enum RawField {
        case varint(Int, UInt64)
        case string(Int, String)
        case message(Int, Data)
    }

    private static func message(_ fields: [RawField]) -> Data {
        var data = Data()
        for field in fields {
            switch field {
            case let .varint(number, value):
                appendVarint(UInt64(number << 3), to: &data)
                appendVarint(value, to: &data)
            case let .string(number, value):
                appendLengthDelimited(number: number, bytes: Data(value.utf8), to: &data)
            case let .message(number, value):
                appendLengthDelimited(number: number, bytes: value, to: &data)
            }
        }
        return data
    }

    private static func appendLengthDelimited(number: Int, bytes: Data, to data: inout Data) {
        appendVarint(UInt64((number << 3) | 2), to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private static func fields(in data: Data) throws -> [WireField] {
        var index = data.startIndex
        var fields = [WireField]()
        while index < data.endIndex {
            let key = try readVarint(from: data, index: &index)
            let wireType = UInt8(key & 0x07)
            fields.append(WireField(number: Int(key >> 3), wireType: wireType))
            switch wireType {
            case 0:
                _ = try readVarint(from: data, index: &index)
            case 1:
                try advance(&index, by: 8, in: data)
            case 2:
                let count = try readVarint(from: data, index: &index)
                guard count <= UInt64(Int.max) else { throw WireFixtureError.invalidLength }
                try advance(&index, by: Int(count), in: data)
            case 5:
                try advance(&index, by: 4, in: data)
            default:
                throw WireFixtureError.unsupportedWireType(wireType)
            }
        }
        return fields
    }

    private static func readVarint(from data: Data, index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw WireFixtureError.truncated
    }

    private static func advance(_ index: inout Data.Index, by count: Int, in data: Data) throws {
        guard let next = data.index(index, offsetBy: count, limitedBy: data.endIndex) else {
            throw WireFixtureError.truncated
        }
        index = next
    }

    private enum WireFixtureError: Error {
        case truncated
        case invalidLength
        case unsupportedWireType(UInt8)
    }
}
