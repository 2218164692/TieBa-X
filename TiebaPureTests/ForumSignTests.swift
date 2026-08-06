import XCTest
@testable import TiebaPure

final class ForumSignTests: XCTestCase {
    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "forum-sign-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private var account: Account {
        FixtureTiebaAPI.account
    }

    func testSignFieldsCarryCredentialsForumAndTBS() throws {
        let fields = try TiebaForumSignRequestFactory.signFields(
            account: account,
            forumID: 4242,
            forumName: "  合成吧  ",
            tbs: " abc123 ",
            requestBuilder: TiebaRequestBuilder(
                screenScale: 3,
                screenWidth: 1179,
                screenHeight: 2556,
                clientID: "fixtureclientid"
            ),
            timestamp: 1_700_000_000_000
        )

        XCTAssertEqual(fields["BDUSS"], account.bduss)
        XCTAssertEqual(fields["kw"], "合成吧", "吧名两侧空白必须去掉")
        XCTAssertEqual(fields["tbs"], "abc123")
        XCTAssertEqual(fields["fid"], "4242")
        XCTAssertNotNil(fields["_client_version"])
        XCTAssertNil(fields["sign"], "签名由 HTTP 客户端计算，请求工厂不应预先写入")
    }

    func testSignFieldsRejectEmptyForumNameAndTBS() {
        let builder = TiebaRequestBuilder(
            screenScale: 3,
            screenWidth: 1179,
            screenHeight: 2556,
            clientID: "fixtureclientid"
        )
        XCTAssertThrowsError(
            try TiebaForumSignRequestFactory.signFields(
                account: account,
                forumID: 1,
                forumName: "   ",
                tbs: "abc",
                requestBuilder: builder
            )
        ) { error in
            XCTAssertEqual(error as? ForumSignError, .missingForumName)
        }
        XCTAssertThrowsError(
            try TiebaForumSignRequestFactory.signFields(
                account: account,
                forumID: 1,
                forumName: "合成吧",
                tbs: "  ",
                requestBuilder: builder
            )
        ) { error in
            XCTAssertEqual(error as? TiebaMutationError, .missingTBS)
        }
    }

    func testSignFieldsOmitForumIDWhenUnknown() throws {
        let fields = try TiebaForumSignRequestFactory.signFields(
            account: account,
            forumID: 0,
            forumName: "合成吧",
            tbs: "abc",
            requestBuilder: TiebaRequestBuilder(
                screenScale: 3,
                screenWidth: 1179,
                screenHeight: 2556,
                clientID: "fixtureclientid"
            )
        )
        XCTAssertNil(fields["fid"], "没有吧 ID 时只按吧名签到，不能发送 fid=0")
    }

    func testAlreadySignedCodeIsAnOutcomeNotAFailure() {
        XCTAssertTrue(ForumSignResponsePolicy.isAlreadySigned(errorCode: 160002))
        XCTAssertFalse(ForumSignResponsePolicy.isAlreadySigned(errorCode: 0))
        XCTAssertFalse(ForumSignResponsePolicy.isAlreadySigned(errorCode: 1))
    }

    func testSignResponseDecodesStreakFromStringsOrNumbers() throws {
        let json = Data("""
        {
          "error_code": "0",
          "user_info": {
            "is_sign_in": "1",
            "sign_bonus_point": 8,
            "cont_sign_num": "4",
            "user_sign_rank": "12"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(ForumSignResponseDTO.self, from: json)

        XCTAssertEqual(response.errorCode, 0)
        XCTAssertEqual(response.userInfo?.isSignedIn, true)
        XCTAssertEqual(response.userInfo?.bonusPoints, 8)
        XCTAssertEqual(response.userInfo?.continuousDays, 4)
        XCTAssertEqual(response.userInfo?.rank, 12)
    }

    @MainActor
    func testAutomaticRunHappensOncePerLocalDayPerAccount() throws {
        let defaults = try makeScratchDefaults()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ForumSignSettingsStore(
            defaults: defaults,
            calendar: .current,
            now: { now }
        )

        XCTAssertFalse(store.automaticSignEnabled, "自动签到默认关闭")
        store.setAutomaticSignEnabled(true)
        XCTAssertTrue(store.automaticSignEnabled)

        XCTAssertFalse(store.hasRunToday(accountID: "user-a"))
        store.markRunCompleted(accountID: "user-a")
        XCTAssertTrue(store.hasRunToday(accountID: "user-a"))
        XCTAssertFalse(
            store.hasRunToday(accountID: "user-b"),
            "另一个账号不应继承已签状态"
        )

        now = now.addingTimeInterval(24 * 60 * 60)
        XCTAssertFalse(store.hasRunToday(accountID: "user-a"), "跨天后需要重新签到")

        // The setting and the day stamp survive a fresh store over the same
        // defaults, which is what makes "每天第一次打开" work across launches.
        let reloaded = ForumSignSettingsStore(defaults: defaults, now: { now })
        XCTAssertTrue(reloaded.automaticSignEnabled)
        reloaded.markRunCompleted(accountID: "user-a")
        XCTAssertTrue(
            ForumSignSettingsStore(defaults: defaults, now: { now })
                .hasRunToday(accountID: "user-a")
        )
    }

    func testDayStampFollowsTheLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        // 2026-08-06 23:30 +08:00 and 00:30 the next day are different days
        // even though they are less than an hour apart.
        let lateEvening = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 6, hour: 23, minute: 30)
        )!
        let afterMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 7, hour: 0, minute: 30)
        )!

        XCTAssertEqual(ForumSignDayStamp.text(for: lateEvening, calendar: calendar), "2026-08-06")
        XCTAssertEqual(ForumSignDayStamp.text(for: afterMidnight, calendar: calendar), "2026-08-07")
    }

    func testSummaryTextReportsEveryOutcomeGroup() {
        XCTAssertEqual(
            ForumSignSummaryText.message(for: .empty),
            "没有可签到的贴吧。"
        )
        XCTAssertEqual(
            ForumSignSummaryText.message(for: ForumSignRunSummary(
                signedCount: 16,
                alreadySignedCount: 0,
                failedForumNames: []
            )),
            "成功签到 16 个吧。"
        )
        XCTAssertEqual(
            ForumSignSummaryText.message(for: ForumSignRunSummary(
                signedCount: 0,
                alreadySignedCount: 16,
                failedForumNames: []
            )),
            "16 个今天已签过。"
        )
        XCTAssertEqual(
            ForumSignSummaryText.message(for: ForumSignRunSummary(
                signedCount: 2,
                alreadySignedCount: 1,
                failedForumNames: ["甲吧", "乙吧", "丙吧", "丁吧"]
            )),
            "成功签到 2 个吧，1 个今天已签过，4 个失败（甲吧、乙吧、丙吧 等）。"
        )
    }

    @MainActor
    func testCoordinatorSignsEveryFollowedForumAndRecordsTheDay() async throws {
        let defaults = try makeScratchDefaults()
        let settings = ForumSignSettingsStore(defaults: defaults)
        let api = FixtureTiebaAPI(scenario: .success)
        let coordinator = ForumSignCoordinator(
            api: api,
            settings: settings,
            requestSpacing: .zero
        )

        let summary = await coordinator.signAllFollowedForums(account: account)

        XCTAssertEqual(summary.signedCount, 2)
        XCTAssertEqual(summary.alreadySignedCount, 0)
        XCTAssertTrue(summary.failedForumNames.isEmpty)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(settings.hasRunToday(accountID: account.id))

        // A second pass reports the repeat instead of counting new check-ins.
        let repeated = await coordinator.signAllFollowedForums(account: account)
        XCTAssertEqual(repeated.signedCount, 0)
        XCTAssertEqual(repeated.alreadySignedCount, 2)
    }

    @MainActor
    func testAutomaticRunIsSkippedWhenDisabledOrAlreadyDoneToday() async throws {
        let defaults = try makeScratchDefaults()
        let settings = ForumSignSettingsStore(defaults: defaults)
        let coordinator = ForumSignCoordinator(
            api: FixtureTiebaAPI(scenario: .success),
            settings: settings,
            requestSpacing: .zero
        )

        await coordinator.signAutomaticallyIfNeeded(account: account)
        XCTAssertNil(coordinator.lastSummary, "开关关闭时不应发起签到")

        settings.setAutomaticSignEnabled(true)
        await coordinator.signAutomaticallyIfNeeded(account: account)
        XCTAssertEqual(coordinator.lastSummary?.signedCount, 2)

        coordinator.clearLastSummary()
        await coordinator.signAutomaticallyIfNeeded(account: account)
        XCTAssertNil(coordinator.lastSummary, "同一天只自动执行一次")

        await coordinator.signAutomaticallyIfNeeded(account: nil)
        XCTAssertNil(coordinator.lastSummary, "未登录时不应发起签到")
    }

    @MainActor
    func testPartialFailureDoesNotConsumeTheDay() async throws {
        let defaults = try makeScratchDefaults()
        let settings = ForumSignSettingsStore(defaults: defaults)
        let coordinator = ForumSignCoordinator(
            api: FixtureTiebaAPI(scenario: .signFailure),
            settings: settings,
            requestSpacing: .zero
        )

        let summary = await coordinator.signAllFollowedForums(account: account)

        XCTAssertEqual(summary.signedCount, 1)
        XCTAssertEqual(summary.failedForumNames.count, 1)
        XCTAssertFalse(
            settings.hasRunToday(accountID: account.id),
            "有失败的吧时不能记为今天已完成，否则明天之前不会再自动重试"
        )
    }
}
