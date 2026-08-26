import XCTest
@testable import TieBaX

final class TieBaXContractTests: XCTestCase {
    func testProductIdentityTargetsIOS14() {
        XCTAssertEqual(TieBaXProduct.name, "TieBa-X")
        XCTAssertEqual(TieBaXProduct.minimumOSVersion, "14.0")
        XCTAssertEqual(TieBaXProduct.urlScheme, "tiebax")
        XCTAssertTrue(TieBaXProduct.bundleIdentifier.hasPrefix("com.tiebax."))
    }

    func testAllMVPFeaturesAreAvailableOnMinimumOS() {
        let iOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        for feature in TieBaXFeature.allCases {
            XCTAssertTrue(
                TieBaXFeatureAvailability.isSupported(feature, on: iOS14),
                "feature \(feature.rawValue) must not require iOS 15+"
            )
        }
    }

    func testSearchPolicyUsesAllTerms() {
        XCTAssertTrue(LocalThreadListSearchPolicy.matches(
            query: "Swift iOS",
            fields: ["TieBa-X", "iOS 14 Swift client"]
        ))
        XCTAssertFalse(LocalThreadListSearchPolicy.matches(
            query: "Swift Android",
            fields: ["TieBa-X", "iOS 14 Swift client"]
        ))
    }

    func testRequestPolicyNormalizesIndependentFeatureInput() throws {
        XCTAssertEqual(
            TieBaXRequestPolicy.normalizedKeyword("  iOS 14  "),
            "iOS 14"
        )
        XCTAssertNil(TieBaXRequestPolicy.normalizedForumName("\n\t"))
        XCTAssertEqual(TieBaXRequestPolicy.searchPageSize(0), 1)
        XCTAssertEqual(
            TieBaXRequestPolicy.searchPageSize(10_000),
            TieBaXRequestPolicy.maximumSearchPageSize
        )
        XCTAssertEqual(try TieBaXRequestPolicy.signedPage(2), 2)
        XCTAssertThrowsError(try TieBaXRequestPolicy.signedPage(0))
    }

    func testRequestPolicyRejectsNonPositiveSignedIdentifiers() {
        XCTAssertNoThrow(try TieBaXRequestPolicy.positiveIdentifier(42))
        XCTAssertThrowsError(try TieBaXRequestPolicy.positiveIdentifier(0)) {
            XCTAssertEqual(
                $0 as? TiebaRequestValidationError,
                .invalidSignedIdentifier(0)
            )
        }
        XCTAssertThrowsError(try TieBaXRequestPolicy.positiveIdentifier(-1)) {
            XCTAssertEqual(
                $0 as? TiebaRequestValidationError,
                .invalidSignedIdentifier(-1)
            )
        }
    }

    func testPaginationPolicyNeverLoopsAtTheIntegerBoundary() {
        XCTAssertEqual(
            TiebaPaginationPolicy.nextPage(requestedPage: 2, responseCurrentPage: 1),
            3
        )
        XCTAssertNil(
            TiebaPaginationPolicy.nextPage(
                requestedPage: Int(Int32.max),
                responseCurrentPage: Int(Int32.max)
            )
        )
    }

    func testExternalRouteAcceptsProductSchemeAndRejectsUnsafeThreadID() {
        XCTAssertNotNil(URL(string: "tiebax://thread/123").flatMap(ExternalRoute.parse))
        XCTAssertNil(URL(string: "tiebax://thread/0").flatMap(ExternalRoute.parse))
        XCTAssertNil(URL(string: "https://example.com/thread/123").flatMap(ExternalRoute.parse))
    }

    func testURLCompatibilityKeepsEndpointPathAndQuerySeparators() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test"))
            .tieBaAppendingPath("/c/f/pb/page")
            .tieBaAppendingQueryItems([
                URLQueryItem(name: "format", value: "protobuf"),
                URLQueryItem(name: "kw", value: "iOS 14")
            ])

        XCTAssertEqual(url.path, "/c/f/pb/page")
        XCTAssertEqual(url.query, "format=protobuf&kw=iOS%2014")
    }
    func testHotThreadListUsesTiebaLiteTabRequestShape() throws {
        XCTAssertEqual(TiebaEndpoint.hotThreadList.url.host, "tiebac.baidu.com")
        XCTAssertEqual(TiebaEndpoint.hotThreadList.url.path, "/c/f/forum/hotThreadList")
        XCTAssertEqual(TiebaEndpoint.hotThreadList.url.query, "cmd=309661")

        var data = Tieba_HotThreadList_HotThreadListRequestData()
        data.common = Tieba_CommonRequest()
        data.tabId = "1"
        data.tabCode = "all"
        var request = Tieba_HotThreadList_HotThreadListRequest()
        request.data = data

        let wireData = try request.serializedData()
        let decoded = try Tieba_HotThreadList_HotThreadListRequest(
            serializedBytes: wireData
        )
        XCTAssertEqual(decoded.data.tabId, "1")
        XCTAssertEqual(decoded.data.tabCode, "all")
        XCTAssertTrue(decoded.data.hasCommon)
    }
}
