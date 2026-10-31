import XCTest
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import FlowReader

final class ReaderPaginationTests: XCTestCase {
    func testSerifUsesAvailableChineseFontOrSystemFallback() {
        let layout = ReaderPagination(paragraphs: ["宋体排版的原创示例。"], fontSize: 21, lineSpacing: 8, serif: true, textSize: CGSize(width: 300, height: 400))
        #if canImport(UIKit)
        let chinese = ["SongtiSC-Regular", "STSongti-SC-Regular", "STSong"].compactMap { UIFont(name: $0, size: 21) }.first
        let base = UIFont.systemFont(ofSize: 21)
        let fallback = UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 21)
        let font = layout.pages.first?.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #else
        let chinese = ["SongtiSC-Regular", "STSongti-SC-Regular", "STSong"].compactMap { NSFont(name: $0, size: 21) }.first
        let base = NSFont.systemFont(ofSize: 21, weight: .regular)
        let fallback = NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 21) ?? base
        let font = layout.pages.first?.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #endif
        XCTAssertNotNil(font)
        XCTAssertEqual(font?.fontName, (chinese ?? fallback).fontName,
                       "Optional system fonts may be absent; use the native serif fallback without downloading a font")
        XCTAssertEqual(font?.pointSize, 21)
    }

    func testLongChineseParagraphPagesRebuildWithoutLosingText() {
        let paragraphs = [String(repeating: "海风穿过书店的窗，桌上的信还没有寄出。“明天会晴吗？”她轻声问。", count: 120), "第二段，故事仍在继续。", String(repeating: "下一段保留自己的首行缩进。", count: 30)]
        let layout = ReaderPagination(paragraphs: paragraphs, fontSize: 21, lineSpacing: 9, serif: true, textSize: CGSize(width: 280, height: 410))
        XCTAssertGreaterThan(layout.pages.count, 3)
        assertCoverageAndDrawing(layout, paragraphs: paragraphs)
        let firstStyle = layout.pages[0].attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(firstStyle?.firstLineHeadIndent, 42)
        let continuation = layout.pages.first { $0.startPosition.paragraph == 0 && $0.startPosition.utf16Offset > 0 }
        let continuationStyle = continuation?.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(continuationStyle?.firstLineHeadIndent, 0)
        let nextParagraphStart = (paragraphs[0] as NSString).length + 1
        if let page = layout.pages.first(where: { NSLocationInRange(nextParagraphStart, $0.range) }) {
            let style = page.attributedText.attribute(.paragraphStyle, at: nextParagraphStart - page.range.location, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(style?.firstLineHeadIndent, 42, "A continued page must not remove the next paragraph's indentation")
        } else { XCTFail("Second paragraph must appear exactly once") }
    }

    func testEmojiCombiningMarksAndCRLFPreserveComposedBoundaries() {
        let paragraphs = [String(repeating: "风👨‍👩‍👧‍👦🇨🇳👩🏽‍🚀e\u{301}🏳️‍🌈，你好！", count: 100), "段中\r\n换行，尾声。", "", "最后一页"]
        let layout = ReaderPagination(paragraphs: paragraphs, fontSize: 23, lineSpacing: 7, serif: false, textSize: CGSize(width: 220, height: 275))
        assertCoverageAndDrawing(layout, paragraphs: paragraphs)
        let source = paragraphs.joined(separator: "\n") as NSString
        let emoji = source.range(of: "👨‍👩‍👧‍👦")
        XCTAssertEqual(layout.pageIndex(for: ReaderTextPosition(paragraph: 0, utf16Offset: emoji.location)), layout.pageIndex(for: ReaderTextPosition(paragraph: 0, utf16Offset: emoji.location + 3)))
    }

    func testReflowKeepsParagraphAndUTF16Anchor() {
        let paragraphs = (0..<8).map { "第\($0)段。" + String(repeating: "晨光照在书页上，故事沿着海岸展开。", count: 24) }
        let compact = ReaderPagination(paragraphs: paragraphs, fontSize: 20, lineSpacing: 8, serif: true, textSize: CGSize(width: 270, height: 420))
        let anchor = compact.pages[compact.pages.count / 2].startPosition
        let wide = ReaderPagination(paragraphs: paragraphs, fontSize: 30, lineSpacing: 12, serif: false, textSize: CGSize(width: 430, height: 330))
        let page = wide.pages[wide.pageIndex(for: anchor)]
        let globalOffset = paragraphs.prefix(anchor.paragraph).reduce(0) { $0 + ($1 as NSString).length + 1 } + anchor.utf16Offset
        XCTAssertTrue(NSLocationInRange(globalOffset, page.range))
        XCTAssertEqual(wide.pageIndex(for: ReaderTextPosition(paragraph: Int.max, utf16Offset: 0)), wide.pages.count - 1)
        XCTAssertEqual(wide.pageIndex(for: ReaderTextPosition(paragraph: -1, utf16Offset: -1)), 0)
        assertCoverageAndDrawing(wide, paragraphs: paragraphs)
    }

    func testAccessibilityFontDoesNotEnlargeActualPageWidth() {
        let paragraphs = [String(repeating: "春风翻动书页，明天继续旅行。", count: 16), "👩🏽‍🚀还有新的故事。"]
        let layout = ReaderPagination(paragraphs: paragraphs, fontSize: 100, lineSpacing: 12, serif: true, textSize: CGSize(width: 300, height: 450))
        XCTAssertEqual(layout.textSize, CGSize(width: 300, height: 450))
        assertCoverageAndDrawing(layout, paragraphs: paragraphs)
    }

    func testEmptyAndDegenerateGeometryDoNotLoopOrDropText() {
        for paragraphs in [[String](), [""]] {
            let empty = ReaderPagination(paragraphs: paragraphs, fontSize: 21, lineSpacing: 8, serif: true, textSize: .zero)
            XCTAssertTrue(empty.pages.isEmpty)
            XCTAssertEqual(empty.pageIndex(for: ReaderTextPosition(paragraph: Int.max, utf16Offset: Int.max)), 0)
        }
        let paragraphs = ["", "一👨‍👩‍👧‍👦二", "", "结束"]
        for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: -.infinity, height: .nan)] {
            let layout = ReaderPagination(paragraphs: paragraphs, fontSize: 21, lineSpacing: 8, serif: false, textSize: size)
            XCTAssertEqual(layout.pages.map(\.attributedText.string).joined(), paragraphs.joined(separator: "\n"))
            XCTAssertLessThanOrEqual(layout.pages.count, paragraphs.joined(separator: "\n").count)
            XCTAssertTrue(layout.textSize.width.isFinite && layout.textSize.height.isFinite)
        }
    }

    func testCancelledBackgroundLayoutStopsBeforePagination() async {
        let worker = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return ReaderPagination(paragraphs: [String(repeating: "可取消的原创测试文字。", count: 10_000)], fontSize: 21, lineSpacing: 8, serif: true, textSize: CGSize(width: 280, height: 420))
        }
        worker.cancel()
        let result = await worker.value
        XCTAssertTrue(result.pages.isEmpty)
    }

    private func assertCoverageAndDrawing(_ layout: ReaderPagination, paragraphs: [String], file: StaticString = #filePath, line: UInt = #line) {
        let source = paragraphs.joined(separator: "\n") as NSString
        XCTAssertEqual(layout.pages.map(\.attributedText.string).joined(), source as String, file: file, line: line)
        var next = 0
        for (index, page) in layout.pages.enumerated() {
            XCTAssertEqual(page.range.location, next, file: file, line: line)
            XCTAssertGreaterThan(page.range.length, 0, file: file, line: line)
            XCTAssertEqual(source.rangeOfComposedCharacterSequence(at: next).location, next, file: file, line: line)
            next = NSMaxRange(page.range)
            if next < source.length { XCTAssertEqual(source.rangeOfComposedCharacterSequence(at: next).location, next, file: file, line: line) }
            XCTAssertEqual(page.attributedText.string, source.substring(with: page.range), file: file, line: line)
            XCTAssertEqual(layout.pageIndex(for: page.startPosition), index, file: file, line: line)
            let setter = CTFramesetterCreateWithAttributedString(page.attributedText)
            let path = CGPath(rect: CGRect(origin: .zero, size: layout.textSize), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            XCTAssertEqual(CTFrameGetVisibleStringRange(frame).length, page.attributedText.length, "The independently drawn page must display every character assigned by pagination", file: file, line: line)
        }
        XCTAssertEqual(next, source.length, file: file, line: line)
    }
}
