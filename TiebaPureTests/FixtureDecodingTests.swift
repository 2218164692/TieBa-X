import SwiftProtobuf
import XCTest
@testable import TiebaPure

final class FixtureDecodingTests: XCTestCase {
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
}
