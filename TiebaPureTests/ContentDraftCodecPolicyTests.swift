import Foundation
import XCTest
@testable import TiebaPure

final class ContentDraftCodecPolicyTests: XCTestCase {
    func testAttachmentCodecStoresRawBytesWithoutBase64Inflation() throws {
        let data = Data(repeating: 0xa5, count: 1_024 * 1_024)
        let image = ContentSubmissionImage(
            data: data,
            pixelWidth: 1_000,
            pixelHeight: 2_000,
            mimeType: "image/jpeg"
        )

        let encoded = try ContentDraftImageBlobCodec.encode([image])

        XCTAssertLessThan(encoded.count, data.count + 256)
        XCTAssertEqual(ContentDraftImageBlobCodec.decode(encoded), [image])
    }

    func testAttachmentCodecRejectsOversizedFrameInsteadOfSilentlyDroppingIt() {
        let image = ContentSubmissionImage(
            data: Data(
                repeating: 0xa5,
                count: ContentSubmissionPolicy.maximumImageBytes + 1
            ),
            pixelWidth: 1,
            pixelHeight: 1,
            mimeType: "image/jpeg"
        )

        XCTAssertThrowsError(try ContentDraftImageBlobCodec.encode([image]))
    }

    func testGlobalDraftCountPrunesTheOldestAcrossAccounts() {
        let candidates = (0...ContentDraftPolicy.maximumDraftsGlobally).map { index in
            ContentDraftPruneCandidate(
                sourceIndex: index,
                persistentID: nil,
                accountID: "account-\(index % 3)",
                targetKey: "target-\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                imagesByteCount: 8
            )
        }

        XCTAssertEqual(ContentDraftPruner.deletionIndices(for: candidates), Set([0]))
    }

    func testGlobalAttachmentBudgetPrunesTheOldestWithoutLargeAllocations() {
        let attachmentBytes = 90 * 1_024 * 1_024
        let candidates = (0..<6).map { index in
            ContentDraftPruneCandidate(
                sourceIndex: index,
                persistentID: nil,
                accountID: "account-\(index % 3)",
                targetKey: "target-\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                imagesByteCount: attachmentBytes
            )
        }

        XCTAssertEqual(ContentDraftPruner.deletionIndices(for: candidates), Set([0]))
    }
}
