import XCTest
@testable import TieBaX

final class AccountThreadFavoritesTests: XCTestCase {
    private var account: Account {
        FixtureTiebaAPI.account
    }

    func testRequestFieldsCarryCredentialsAndPaging() throws {
        let fields = try AccountThreadFavoritesPolicy.fields(account: account, page: 3)

        XCTAssertEqual(fields["BDUSS"], account.bduss)
        XCTAssertEqual(fields["stoken"], account.stoken)
        XCTAssertEqual(fields["pn"], "3")
        XCTAssertEqual(fields["rn"], "\(AccountThreadFavoritesPolicy.pageSize)")
    }

    func testRequestFieldsRejectInvalidPage() {
        XCTAssertThrowsError(try AccountThreadFavoritesPolicy.fields(account: account, page: 0))
    }

    /// Mirrors the live payload: `tid`/`id` both present, `has_more` as a
    /// number, and the collected floor as a string.
    func testResponseDecodesLiveShape() throws {
        let json = Data("""
        {
          "ctime": "0",
          "error_code": 0,
          "data": {
            "has_more": 1,
            "thread_list": [
              {
                "id": 9430000001,
                "tid": 9430000001,
                "title": "超级选卡多少也有点运气在的",
                "fid": 22295035,
                "fname": "皇室战争",
                "reply_num": 19,
                "view_num": 3200,
                "last_time_int": 1748670872,
                "create_time": 1748405966,
                "collect_status": 1,
                "collect_mark_pid": "152158975438",
                "author": { "id": 123, "name": "raw_name", "name_show": "那改个名吧" },
                "forum_info": { "id": 22295035, "name": "皇室战争" }
              }
            ]
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(ThreadStoreListResponseDTO.self, from: json)

        XCTAssertEqual(response.errorCode, 0)
        XCTAssertTrue(response.hasMore)
        let favorite = try XCTUnwrap(response.threads.first?.favorite)
        XCTAssertEqual(favorite.threadID, 9_430_000_001)
        XCTAssertEqual(favorite.forumID, 22_295_035)
        XCTAssertEqual(favorite.forumName, "皇室战争")
        XCTAssertEqual(favorite.title, "超级选卡多少也有点运气在的")
        XCTAssertEqual(favorite.authorDisplayName, "那改个名吧", "优先展示昵称而不是原始用户名")
        XCTAssertEqual(favorite.replyCount, 19)
        XCTAssertEqual(favorite.lastReplyAt, Date(timeIntervalSince1970: 1_748_670_872))
        XCTAssertEqual(
            favorite.markedPostID,
            152_158_975_438,
            "贴吧把收藏时的楼层一起存了，打开时应该直接落到那一层"
        )
    }

    func testResponseTreatsMissingHasMoreAsEndOfList() throws {
        let json = Data("""
        { "error_code": 0, "data": { "thread_list": [] } }
        """.utf8)

        let response = try JSONDecoder().decode(ThreadStoreListResponseDTO.self, from: json)

        XCTAssertFalse(response.hasMore)
        XCTAssertTrue(response.threads.isEmpty)
    }

    func testResponseKeepsBusinessErrorForValidation() throws {
        let json = Data("""
        { "error_code": 110001, "error_msg": "未知错误", "data": {} }
        """.utf8)

        let response = try JSONDecoder().decode(ThreadStoreListResponseDTO.self, from: json)

        XCTAssertEqual(response.errorCode, 110001)
        XCTAssertEqual(response.errorMessage, "未知错误")
        XCTAssertThrowsError(
            try TiebaResponseValidator.validate(
                code: response.errorCode,
                message: response.errorMessage
            )
        )
    }

    func testEntryWithoutThreadIDIsDropped() throws {
        let json = Data("""
        {
          "error_code": 0,
          "data": { "has_more": 0, "thread_list": [ { "title": "没有 ID 的条目" } ] }
        }
        """.utf8)

        let response = try JSONDecoder().decode(ThreadStoreListResponseDTO.self, from: json)

        XCTAssertEqual(response.threads.count, 1)
        XCTAssertNil(response.threads.first?.favorite, "缺少帖子 ID 的条目无法打开，应该丢弃")
    }

    func testMissingTitleAndAuthorFallBackToPlaceholders() throws {
        let json = Data("""
        {
          "error_code": 0,
          "data": { "has_more": 0, "thread_list": [ { "tid": 42, "fid": 7, "fname": "测试" } ] }
        }
        """.utf8)

        let response = try JSONDecoder().decode(ThreadStoreListResponseDTO.self, from: json)
        let favorite = try XCTUnwrap(response.threads.first?.favorite)

        XCTAssertEqual(favorite.title, "帖子 42")
        XCTAssertEqual(favorite.authorDisplayName, "未知用户")
        XCTAssertNil(favorite.markedPostID)
        XCTAssertNil(favorite.lastReplyAt)
    }

    func testAddPayloadMarksTheCollectedFloor() throws {
        let payload = try AccountThreadFavoriteMutationPolicy.addPayload(
            threadID: 9_430_000_001,
            postID: 152_158_975_438
        )

        XCTAssertEqual(
            payload,
            "[{\"tid\":\"9430000001\",\"pid\":\"152158975438\",\"status\":1}]"
        )
    }

    func testAddFieldsCarryPayloadAndTBS() throws {
        let fields = try AccountThreadFavoriteMutationPolicy.addFields(
            account: account,
            threadID: 42,
            postID: 7,
            tbs: " tbs-value "
        )

        XCTAssertEqual(fields["BDUSS"], account.bduss)
        XCTAssertEqual(fields["tbs"], "tbs-value")
        XCTAssertEqual(fields["data"], "[{\"tid\":\"42\",\"pid\":\"7\",\"status\":1}]")
    }

    func testRemoveFieldsCarryThreadAndTBS() throws {
        let fields = try AccountThreadFavoriteMutationPolicy.removeFields(
            account: account,
            threadID: 42,
            tbs: "tbs-value"
        )

        XCTAssertEqual(fields["BDUSS"], account.bduss)
        XCTAssertEqual(fields["tid"], "42")
        XCTAssertEqual(fields["tbs"], "tbs-value")
        XCTAssertNil(fields["data"], "取消收藏只需要帖子 ID")
    }

    func testMutationsRejectMissingThreadOrTBS() {
        XCTAssertThrowsError(
            try AccountThreadFavoriteMutationPolicy.addPayload(threadID: 0, postID: 1)
        ) { error in
            XCTAssertEqual(error as? AccountThreadFavoriteMutationError, .invalidThreadID)
        }
        XCTAssertThrowsError(
            try AccountThreadFavoriteMutationPolicy.removeFields(
                account: account,
                threadID: 0,
                tbs: "tbs"
            )
        ) { error in
            XCTAssertEqual(error as? AccountThreadFavoriteMutationError, .invalidThreadID)
        }
        XCTAssertThrowsError(
            try AccountThreadFavoriteMutationPolicy.addFields(
                account: account,
                threadID: 1,
                postID: 1,
                tbs: "   "
            )
        ) { error in
            XCTAssertEqual(error as? TiebaMutationError, .missingTBS)
        }
    }

    func testRemovalOperationsFinishIndependentlyAndInvalidateAsOneGeneration() {
        var state = ThreadFavoritesRemovalOperationState()
        let first = state.begin(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = state.begin(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        state.finish(first)

        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(
            state.isCurrent(second),
            "第一批取消收藏完成时不能清掉后一批任务的引用"
        )

        state.invalidate()

        XCTAssertFalse(
            state.isCurrent(second),
            "账号切换后旧批次不能再提交错误或触发旧账号重载"
        )
        XCTAssertTrue(state.activeOperationIDs.isEmpty)
    }
}
