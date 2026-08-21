import Combine
import XCTest
@testable import TiebaPure

@MainActor
final class SessionExpirationMonitorTests: XCTestCase {
    func testClassifierAcceptsOnlyExplicitSessionExpirationErrors() {
        XCTAssertTrue(SessionExpirationErrorClassifier.isSessionExpired(
            TiebaAPIError.sessionExpired(code: 110001, message: "登录已失效")
        ))
        XCTAssertTrue(SessionExpirationErrorClassifier.isSessionExpired(
            ContentSubmissionError.sessionExpired
        ))
        XCTAssertFalse(SessionExpirationErrorClassifier.isSessionExpired(
            TiebaAPIError.response(code: 4, message: "操作频繁")
        ))
        XCTAssertFalse(SessionExpirationErrorClassifier.isSessionExpired(
            URLError(.notConnectedToInternet)
        ))
    }

    func testHandlingPolicyRequiresCurrentSessionAndDeduplicates() {
        let account = FixtureTiebaAPI.account
        var replacement = account
        replacement.stoken += "-replacement"

        XCTAssertTrue(SessionExpirationHandlingPolicy.shouldHandle(
            reportedSession: account.sessionIdentity,
            currentAccount: account,
            expiringSession: nil
        ))
        XCTAssertFalse(SessionExpirationHandlingPolicy.shouldHandle(
            reportedSession: account.sessionIdentity,
            currentAccount: replacement,
            expiringSession: nil
        ))
        XCTAssertFalse(SessionExpirationHandlingPolicy.shouldHandle(
            reportedSession: account.sessionIdentity,
            currentAccount: account,
            expiringSession: account.sessionIdentity
        ))
        XCTAssertFalse(SessionExpirationHandlingPolicy.shouldHandle(
            reportedSession: account.sessionIdentity,
            currentAccount: nil,
            expiringSession: nil
        ))
    }

    func testAuthenticatedExpirationIsReportedAndOriginalErrorIsPreserved() async {
        let monitor = SessionExpirationMonitor()
        let service = SessionMonitoringTiebaAPI(
            base: FixtureTiebaAPI(scenario: .expired),
            monitor: monitor
        )
        var reportedSessions: [AccountSessionIdentity] = []
        let observation = monitor.expiredSessions.sink { reportedSessions.append($0) }
        defer { observation.cancel() }

        do {
            _ = try await service.personalizedThreads(
                account: FixtureTiebaAPI.account,
                page: 1,
                loadType: 0
            )
            XCTFail("Expected the fixture to report an expired session")
        } catch {
            XCTAssertEqual(
                error as? TiebaAPIError,
                .sessionExpired(code: 110001, message: "登录已失效")
            )
        }

        XCTAssertEqual(reportedSessions, [FixtureTiebaAPI.account.sessionIdentity])
    }

    func testAnonymousExpirationAndLoginValidationDoNotReportActiveSession() async {
        let monitor = SessionExpirationMonitor()
        let service = SessionMonitoringTiebaAPI(
            base: FixtureTiebaAPI(scenario: .expired),
            monitor: monitor
        )
        var reportedSessions: [AccountSessionIdentity] = []
        let observation = monitor.expiredSessions.sink { reportedSessions.append($0) }
        defer { observation.cancel() }

        do {
            _ = try await service.personalizedThreads(account: nil, page: 1, loadType: 0)
        } catch {}
        do {
            _ = try await service.validateLogin(cookies: BaiduCookies(
                bduss: FixtureTiebaAPI.account.bduss,
                stoken: FixtureTiebaAPI.account.stoken,
                baiduID: FixtureTiebaAPI.account.baiduID
            ))
        } catch {}

        XCTAssertTrue(reportedSessions.isEmpty)
    }

    func testOrdinaryNetworkFailureDoesNotReportExpiration() async {
        let monitor = SessionExpirationMonitor()
        let service = SessionMonitoringTiebaAPI(
            base: FixtureTiebaAPI(scenario: .error),
            monitor: monitor
        )
        var reportedSessions: [AccountSessionIdentity] = []
        let observation = monitor.expiredSessions.sink { reportedSessions.append($0) }
        defer { observation.cancel() }

        do {
            _ = try await service.personalizedThreads(
                account: FixtureTiebaAPI.account,
                page: 1,
                loadType: 0
            )
        } catch {}

        XCTAssertTrue(reportedSessions.isEmpty)
    }
}
