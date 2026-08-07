import XCTest
@testable import TiebaPure

/// Covers the two caches that make a row scrolling back into view cheap:
/// paragraph heights are shared between views, and the text views themselves
/// are recycled.
final class InlineTextReuseTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        InlineContentTextMeasurementCache.drain()
        InlineContentTextViewPool.drain()
    }

    @MainActor
    override func tearDown() {
        InlineContentTextMeasurementCache.drain()
        InlineContentTextViewPool.drain()
        super.tearDown()
    }

    private func paragraph(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .callout)]
        )
    }

    @MainActor
    func testHeightMeasuredOnceIsReusedByAnotherView() {
        let text = paragraph("回到这一行时不应该重新排版的合成回复内容。")
        let first = InlineContentTextView()
        let firstSize = first.fittingSize(
            width: 320,
            attributedText: text,
            maximumNumberOfLines: 0,
            lineBreakMode: .byWordWrapping
        )
        XCTAssertGreaterThan(firstSize.height, 0)
        XCTAssertEqual(InlineContentTextMeasurementCache.cachedHeightCount, 1)

        // A different view is what scrolling back actually produces.
        let second = InlineContentTextView()
        let secondSize = second.fittingSize(
            width: 320,
            attributedText: paragraph("回到这一行时不应该重新排版的合成回复内容。"),
            maximumNumberOfLines: 0,
            lineBreakMode: .byWordWrapping
        )

        XCTAssertEqual(secondSize, firstSize)
        XCTAssertEqual(
            InlineContentTextMeasurementCache.cachedHeightCount,
            1,
            "同一段文字在同一宽度下只应测量一次"
        )
        // The cached height must not skip applying the run: the view still has
        // to be able to draw it.
        XCTAssertEqual(second.textStorage.string, text.string)
    }

    @MainActor
    func testWidthChangeIsMeasuredSeparately() {
        let text = paragraph("换宽度必须重新测量。")
        let view = InlineContentTextView()
        let narrow = view.fittingSize(
            width: 200,
            attributedText: text,
            maximumNumberOfLines: 0,
            lineBreakMode: .byWordWrapping
        )
        let wide = view.fittingSize(
            width: 400,
            attributedText: text,
            maximumNumberOfLines: 0,
            lineBreakMode: .byWordWrapping
        )

        XCTAssertEqual(InlineContentTextMeasurementCache.cachedHeightCount, 2)
        XCTAssertGreaterThanOrEqual(narrow.height, wide.height)
    }

    @MainActor
    func testMeasurementCacheStaysBounded() {
        for index in 0..<(InlineContentTextMeasurementCache.capacity + 32) {
            InlineContentTextMeasurementCache.store(
                height: CGFloat(index),
                for: InlineContentTextMeasurementCache.Key(
                    attributedText: paragraph("回复\(index)"),
                    width: 320,
                    maximumNumberOfLines: 0,
                    lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
                    displayScale: 3,
                    contentSizeCategory: UIContentSizeCategory.large.rawValue,
                    legibilityWeight: UILegibilityWeight.regular.rawValue
                )
            )
        }

        XCTAssertLessThanOrEqual(
            InlineContentTextMeasurementCache.cachedHeightCount,
            InlineContentTextMeasurementCache.capacity
        )
        XCTAssertGreaterThan(InlineContentTextMeasurementCache.cachedHeightCount, 0)
    }

    @MainActor
    func testDetachedViewIsRecycledBlankAndReused() async {
        let view = InlineContentTextView()
        view.accessibilityIdentifier = "thread-reply-text"
        view.allowsTextSelection = true
        view.apply(
            attributedText: paragraph("上一行回复"),
            renderID: 1,
            maximumNumberOfLines: 2,
            lineBreakMode: .byTruncatingTail
        )

        InlineContentTextViewPool.recycle(view)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(InlineContentTextViewPool.pooledViewCount, 1)

        let reused = InlineContentTextViewPool.dequeue()
        XCTAssertTrue(reused === view, "回收的文本视图应被下一行复用")
        XCTAssertEqual(reused.textStorage.string, "")
        XCTAssertNil(reused.accessibilityIdentifier)
        XCTAssertFalse(reused.allowsTextSelection)
        XCTAssertEqual(reused.textContainer.maximumNumberOfLines, 0)

        // A fresh coordinator restarts render IDs at 1, so a recycled view must
        // not mistake the next row's first run for one it already applied.
        reused.apply(
            attributedText: paragraph("下一行回复"),
            renderID: 1,
            maximumNumberOfLines: 0,
            lineBreakMode: .byWordWrapping
        )
        XCTAssertEqual(reused.textStorage.string, "下一行回复")
    }

    @MainActor
    func testViewStillInAHierarchyIsNotReclaimed() async {
        let container = UIView()
        let view = InlineContentTextView()
        container.addSubview(view)

        InlineContentTextViewPool.recycle(view)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(
            InlineContentTextViewPool.pooledViewCount,
            0,
            "SwiftUI 还持有的视图不能回收，否则下一行会和上一行抢同一个视图"
        )
    }

    @MainActor
    func testPoolStopsGrowingAtCapacity() async {
        for _ in 0..<(InlineContentTextViewPool.capacity + 4) {
            InlineContentTextViewPool.recycle(InlineContentTextView())
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            InlineContentTextViewPool.pooledViewCount,
            InlineContentTextViewPool.capacity
        )
    }
}
