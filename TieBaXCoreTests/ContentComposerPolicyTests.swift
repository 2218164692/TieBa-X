import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TieBaX

final class ContentComposerPolicyTests: XCTestCase {
    func testForumResolverUsesKnownIDAndRequiresForumName() {
        let known = Forum(
            id: 42,
            name: "fixture",
            displayName: "夹具吧",
            memberCount: 0,
            threadCount: 0
        )
        XCTAssertEqual(ContentSubmissionForumResolver.resolve(known, fallbackID: nil)?.id, 42)

        let idOnly = Forum(
            id: 0,
            name: "fixture",
            displayName: "夹具吧",
            memberCount: 0,
            threadCount: 0
        )
        XCTAssertEqual(ContentSubmissionForumResolver.resolve(idOnly, fallbackID: 84)?.id, 84)
        XCTAssertNil(ContentSubmissionForumResolver.resolve(idOnly, fallbackID: nil))

        let unnamed = Forum(
            id: 42,
            name: "  ",
            displayName: "夹具吧",
            memberCount: 0,
            threadCount: 0
        )
        XCTAssertNil(ContentSubmissionForumResolver.resolve(unnamed, fallbackID: 84))
    }

    func testTitleIsOnlyShownForNewThreads() {
        XCTAssertTrue(ContentComposerPolicy.showsTitle(for: .newThread))
        XCTAssertFalse(ContentComposerPolicy.showsTitle(for: .threadReply))
        XCTAssertFalse(ContentComposerPolicy.showsTitle(for: .postReply))
        XCTAssertFalse(ContentComposerPolicy.showsTitle(for: .subpostReply))
    }

    func testRemainingImageSlotsAreClampedToPolicyRange() {
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(currentCount: -1, kind: .threadReply),
            ContentSubmissionPolicy.maximumImages
        )
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(currentCount: 3, kind: .threadReply),
            ContentSubmissionPolicy.maximumImages - 3
        )
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(
                currentCount: ContentSubmissionPolicy.maximumImages + 1,
                kind: .threadReply
            ),
            0
        )
        XCTAssertEqual(
            ContentComposerPolicy.remainingImageSlots(currentCount: 0, kind: .newThread),
            0
        )
    }

    func testEmoticonInsertionSeparatesTokenFromExistingText() {
        XCTAssertEqual(ContentComposerPolicy.appendingEmoticon("#(滑稽)", to: ""), "#(滑稽)")
        XCTAssertEqual(ContentComposerPolicy.appendingEmoticon("#(滑稽)", to: "正文"), "正文 #(滑稽)")
        XCTAssertEqual(ContentComposerPolicy.appendingEmoticon("#(滑稽)", to: "正文\n"), "正文\n#(滑稽)")
    }

    func testValidationMessageUsesSubmissionContract() {
        var request = ContentSubmissionRequest(
            target: makeTarget(kind: .newThread),
            title: "",
            body: "正文",
            images: []
        )

        XCTAssertEqual(ContentComposerPolicy.validationMessage(for: request), "请输入帖子标题。")

        request.title = "标题"
        XCTAssertNil(ContentComposerPolicy.validationMessage(for: request))

        request.body = ""
        XCTAssertEqual(ContentComposerPolicy.validationMessage(for: request), "请输入正文或添加图片。")
    }

    func testValidationRejectsNonImageMIMEType() {
        let request = ContentSubmissionRequest(
            target: makeTarget(kind: .threadReply),
            title: "",
            body: "正文",
            images: [ContentSubmissionImage(
                data: Data([0x01]),
                pixelWidth: 1,
                pixelHeight: 1,
                mimeType: "text/plain"
            )]
        )

        XCTAssertEqual(ContentComposerPolicy.validationMessage(for: request), "所选图片无法读取，请重新选择。")
    }

    func testValidationInspectsBytesInsteadOfTrustingClaimedMetadata() throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let metadata = try ContentSubmissionImageInspector.inspect(data)
        XCTAssertEqual(metadata.pixelWidth, 1)
        XCTAssertEqual(metadata.pixelHeight, 1)
        XCTAssertEqual(metadata.mimeType, "image/png")

        let reply = ContentSubmissionRequest(
            target: makeTarget(kind: .threadReply),
            title: "",
            body: "正文",
            images: [ContentSubmissionImage(
                data: data,
                pixelWidth: 99_999,
                pixelHeight: 99_999,
                mimeType: "image/jpeg"
            )]
        )
        XCTAssertNoThrow(try ContentSubmissionPolicy.validateForNetwork(reply))

        var corrupt = reply
        corrupt.images[0].data = Data([0xff, 0xd8, 0xff])
        XCTAssertThrowsError(try ContentSubmissionPolicy.validateForNetwork(corrupt)) { error in
            XCTAssertEqual(error as? ContentSubmissionValidationError, .invalidImage)
        }
    }

    func testNewThreadRejectsImagesBeforeAnyNetworkWrite() throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let request = ContentSubmissionRequest(
            target: makeTarget(kind: .newThread),
            title: "标题",
            body: "正文",
            images: [ContentSubmissionImage(
                data: data,
                pixelWidth: 1,
                pixelHeight: 1,
                mimeType: "image/png"
            )]
        )
        XCTAssertEqual(
            ContentComposerPolicy.validationMessage(for: request),
            "当前发布新主题仅支持文字和贴吧表情。"
        )
    }

    func testRiskAcknowledgementIsExplicitAndPersistent() throws {
        let suiteName = "com.tiebax.composer-risk-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ContentSubmissionRiskPolicy.reset(defaults: defaults)
        XCTAssertFalse(ContentSubmissionRiskPolicy.hasAcknowledged(defaults: defaults))

        ContentSubmissionRiskPolicy.acknowledge(defaults: defaults)
        XCTAssertTrue(ContentSubmissionRiskPolicy.hasAcknowledged(defaults: defaults))

        ContentSubmissionRiskPolicy.reset(defaults: defaults)
        XCTAssertFalse(ContentSubmissionRiskPolicy.hasAcknowledged(defaults: defaults))
    }

    func testLegacyRiskAcknowledgementDoesNotSuppressCurrentWarning() throws {
        let suiteName = "com.tiebax.composer-risk-legacy-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Legacy key from the pre-TieBa-X build must not suppress the new
        // product's explicit risk acknowledgement.
        defaults.set(true, forKey: "TiebaPure.contentSubmissionRiskAcknowledged.v1")

        XCTAssertFalse(ContentSubmissionRiskPolicy.hasAcknowledged(defaults: defaults))
    }

    func testImageDimensionsFollowEXIFOrientation() {
        let upright = ContentSubmissionImageInspector.displayPixelDimensions(
            width: 4_032,
            height: 3_024,
            orientation: 1
        )
        XCTAssertEqual(upright.width, 4_032)
        XCTAssertEqual(upright.height, 3_024)

        let rotated = ContentSubmissionImageInspector.displayPixelDimensions(
            width: 4_032,
            height: 3_024,
            orientation: 6
        )
        XCTAssertEqual(rotated.width, 3_024)
        XCTAssertEqual(rotated.height, 4_032)

        XCTAssertEqual(
            ContentSubmissionImageInspector.displayPixelDimensions(
                width: 4_032,
                height: 3_024,
                orientation: 8
            ).height,
            4_032
        )
    }

    func testSelectedImageBytesStripEXIFGPSAndNormalizeOrientationBeforeDrafting() throws {
        let sourceImage = try Self.makeCGImage(width: 2, height: 1, includesAlpha: false)
        let sourceData = try Self.makeImageData(
            image: sourceImage,
            typeIdentifier: UTType.jpeg.identifier,
            properties: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 22.5431,
                    kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 114.0579,
                    kCGImagePropertyGPSLongitudeRef: "E"
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2026:08:08 12:34:56",
                    kCGImagePropertyExifUserComment: "fixture-private-metadata"
                ]
            ]
        )
        let sourceProperties = try Self.imageProperties(sourceData)
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(sourceProperties[kCGImagePropertyExifDictionary])

        let image = try ContentComposerImageDecoder.decode(sourceData)
        let sanitizedProperties = try Self.imageProperties(image.data)

        XCTAssertNil(sanitizedProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(sanitizedProperties[kCGImagePropertyIPTCDictionary])
        let sanitizedEXIF = sanitizedProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(sanitizedEXIF?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(sanitizedEXIF?[kCGImagePropertyExifUserComment])
        XCTAssertEqual((sanitizedProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual(image.pixelWidth, 1)
        XCTAssertEqual(image.pixelHeight, 2)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertNil(image.data.range(of: Data("fixture-private-metadata".utf8)))

        let draftBlob = try ContentDraftImageBlobCodec.encode([image])
        let restoredDraftImage = try XCTUnwrap(ContentDraftImageBlobCodec.decode(draftBlob).first)
        XCTAssertEqual(restoredDraftImage.data, image.data)
        XCTAssertNil(draftBlob.range(of: Data("fixture-private-metadata".utf8)))

        // The upload contract base64-encodes `ContentSubmissionImage.data`
        // without substituting the original PhotosPicker payload.
        let uploadBytes = try XCTUnwrap(Data(base64Encoded: image.data.base64EncodedString()))
        XCTAssertEqual(uploadBytes, image.data)
        XCTAssertNil(uploadBytes.range(of: Data("fixture-private-metadata".utf8)))
    }

    func testSelectedTransparentPNGKeepsAlphaAfterMetadataSanitization() throws {
        let sourceImage = try Self.makeCGImage(width: 2, height: 2, includesAlpha: true)
        let sourceData = try Self.makeImageData(
            image: sourceImage,
            typeIdentifier: UTType.png.identifier,
            properties: [:]
        )

        let image = try ContentComposerImageDecoder.decode(sourceData)
        let sanitizedSource = try XCTUnwrap(CGImageSourceCreateWithData(image.data as CFData, nil))
        let sanitizedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sanitizedSource, 0, nil))

        XCTAssertEqual(image.mimeType, "image/png")
        switch sanitizedImage.alphaInfo {
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
            break
        case .none, .noneSkipFirst, .noneSkipLast:
            XCTFail("Sanitization must preserve transparency")
        @unknown default:
            XCTFail("Unexpected alpha representation")
        }
    }

    private func makeTarget(kind: ContentSubmissionKind) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: kind,
            forumID: 1,
            forumName: "fixture",
            forumDisplayName: "测试吧",
            threadID: kind == .newThread ? nil : 2,
            threadTitle: "测试帖子",
            parentPostID: nil,
            parentFloor: nil,
            subpostID: nil,
            replyUserID: nil,
            replyUserDisplayName: nil
        )
    }

    private static func makeCGImage(
        width: Int,
        height: Int,
        includesAlpha: Bool
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = includesAlpha ? .premultipliedLast : .noneSkipLast
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: alphaInfo.rawValue)
        )
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ))
        if includesAlpha {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private static func makeImageData(
        image: CGImage,
        typeIdentifier: String,
        properties: [CFString: Any]
    ) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            typeIdentifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func imageProperties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }
}
