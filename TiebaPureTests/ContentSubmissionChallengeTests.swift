import Foundation
import XCTest
@testable import TiebaPure

final class ContentSubmissionChallengeTests: XCTestCase {
    func testStructuredChallengeParsesKnownInfoExtraAndAntiFields() throws {
        let payload = try decode(#"""
        {
          "info": {
            "need_vcode": true,
            "vcode_md5": "fixture-md5",
            "vcode_prev_type": "old",
            "vcode_type": "slide",
            "pass_token": "fixture-pass-token",
            "block_content": "请完成验证",
            "block_cancel": "取消",
            "block_confirm": "验证",
            "vcode_pic_url": "https://tieba.baidu.com/challenge.png",
            "vcode_extra": {
              "textimg": "https://himg.bdimg.com/text.png",
              "slideendpoint": "https://tieba.baidu.com/challenge/slide"
            },
            "anti_stat": {
              "ifpost": 0,
              "forbid_flag": "1",
              "forbid_info": "需要验证",
              "vcode_stat": 1,
              "days_tofree": 3,
              "has_chance": true
            }
          },
          "ext_msg": "补充说明",
          "toast": {"content":"验证提示"}
        }
        """#)

        let challenge = try XCTUnwrap(TiebaWebSubmissionChallengePayload.challenge(
            from: [payload],
            messages: ["请完成安全验证"]
        ))

        XCTAssertEqual(challenge.message, "请完成安全验证")
        XCTAssertEqual(challenge.verificationMD5?.value, "fixture-md5")
        XCTAssertEqual(challenge.passToken?.value, "fixture-pass-token")
        XCTAssertEqual(challenge.verificationType, "slide")
        XCTAssertEqual(challenge.previousVerificationType, "old")
        XCTAssertEqual(challenge.pictureURL?.host, "tieba.baidu.com")
        XCTAssertEqual(challenge.blockPrompt?.confirmTitle, "验证")
        XCTAssertEqual(challenge.extra?.textImageURL?.host, "himg.bdimg.com")
        XCTAssertEqual(challenge.extra?.slideEndpointURL?.path, "/challenge/slide")
        XCTAssertEqual(challenge.antiState?.verificationState, "1")
        XCTAssertEqual(challenge.antiState?.daysToFree, 3)
        XCTAssertEqual(challenge.antiState?.hasChance, true)
        XCTAssertEqual(challenge.extensionMessage, "补充说明")
        XCTAssertEqual(challenge.toastMessage, "验证提示")
        XCTAssertFalse(challenge.hasConflictingPayload)
    }

    func testConflictingCredentialsAreDiscardedWithoutGuessing() throws {
        let top = try decode(#"{"need_vcode":1,"vcode_md5":"first","pass_token":"one"}"#)
        let nested = try decode(#"{"need_vcode":1,"vcode_md5":"second","pass_token":"two"}"#)

        let challenge = try XCTUnwrap(TiebaWebSubmissionChallengePayload.challenge(
            from: [top, nested],
            messages: []
        ))

        XCTAssertNil(challenge.verificationMD5)
        XCTAssertNil(challenge.passToken)
        XCTAssertTrue(challenge.hasConflictingPayload)
    }

    func testChallengeURLsRejectHTTPUserInfoPrivateAndForeignHosts() throws {
        let values = [
            "http://tieba.baidu.com/challenge",
            "https://user@tieba.baidu.com/challenge",
            "https://127.0.0.1/challenge",
            "https://example.com/challenge"
        ]

        for value in values {
            let data = try JSONSerialization.data(withJSONObject: [
                "need_vcode": 1,
                "vcode_pic_url": value
            ])
            let payload = try JSONDecoder().decode(
                TiebaWebSubmissionChallengePayload.self,
                from: data
            )
            let challenge = try XCTUnwrap(TiebaWebSubmissionChallengePayload.challenge(
                from: [payload],
                messages: []
            ))
            XCTAssertNil(challenge.pictureURL, value)
        }
    }

    func testFalseFlagDoesNotCreateChallengeButUnknownNonemptyFlagFailsClosed() throws {
        for value in ["0", "false", "off", "none"] {
            let payload = try decode("{\"need_vcode\":\"\(value)\"}")
            XCTAssertNil(TiebaWebSubmissionChallengePayload.challenge(
                from: [payload],
                messages: []
            ))
        }

        let unknown = try decode(#"{"need_vcode":"unexpected-state"}"#)
        XCTAssertNotNil(TiebaWebSubmissionChallengePayload.challenge(
            from: [unknown],
            messages: []
        ))
    }

    func testVerificationMessageRemainsFallbackWhenStructuredFieldsAreAbsent() throws {
        let empty = try decode("{}")
        let challenge = try XCTUnwrap(TiebaWebSubmissionChallengePayload.challenge(
            from: [empty],
            messages: ["captcha required"]
        ))
        XCTAssertEqual(challenge.message, "captcha required")
    }

    private func decode(_ json: String) throws -> TiebaWebSubmissionChallengePayload {
        try JSONDecoder().decode(
            TiebaWebSubmissionChallengePayload.self,
            from: Data(json.utf8)
        )
    }
}
