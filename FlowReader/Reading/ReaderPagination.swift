import Foundation
import CoreText
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct ReaderTextPosition: Codable, Hashable, Sendable {
    var paragraph: Int
    var utf16Offset: Int
}

/// The attributed string is an immutable, independently drawable page. `range` is in
/// the complete chapter's UTF-16 text, including the newline between paragraphs.
struct ReaderPage: @unchecked Sendable {
    let attributedText: NSAttributedString
    let range: NSRange
    let startPosition: ReaderTextPosition
}

/// Only immutable text leaves the initializer. Core Text layout objects remain on
/// the calling work queue; the page renderer creates its own frames on its queue.
struct ReaderPagination: @unchecked Sendable {
    let id = UUID()
    let pages: [ReaderPage]
    let textSize: CGSize
    private let chapterText: NSString
    private let paragraphStarts: [Int]
    private let paragraphLengths: [Int]

    init(paragraphs: [String], fontSize: CGFloat, lineSpacing: CGFloat, serif: Bool, textSize: CGSize) {
        let pointSize = fontSize.isFinite && fontSize > 0 ? min(fontSize, 256) : 21
        let spacing = lineSpacing.isFinite ? min(max(0, lineSpacing), 256) : 0
        #if canImport(UIKit)
        let baseFont = UIFont.systemFont(ofSize: pointSize)
        let chineseSerif = ["SongtiSC-Regular", "STSongti-SC-Regular", "STSong"].lazy.compactMap { UIFont(name: $0, size: pointSize) }.first
        let font = serif ? chineseSerif ?? UIFont(descriptor: baseFont.fontDescriptor.withDesign(.serif) ?? baseFont.fontDescriptor, size: pointSize) : baseFont
        let fontHeight = font.lineHeight
        #else
        let baseFont = NSFont.systemFont(ofSize: pointSize, weight: .regular)
        let chineseSerif = ["SongtiSC-Regular", "STSongti-SC-Regular", "STSong"].lazy.compactMap { NSFont(name: $0, size: pointSize) }.first
        let font = serif ? chineseSerif ?? NSFont(descriptor: baseFont.fontDescriptor.withDesign(.serif) ?? baseFont.fontDescriptor, size: pointSize) ?? baseFont : baseFont
        let fontHeight = font.ascender - font.descender + font.leading
        #endif
        // Geometry can briefly be zero during rotation. Positive dimensions stay
        // exact so large accessibility fonts never enlarge the drawing rectangle.
        let minimumWidth = ceil(pointSize * 4)
        let minimumHeight = ceil(max(fontHeight, pointSize * 1.6) + spacing)
        func dimension(_ requested: CGFloat, minimum: CGFloat) -> CGFloat {
            requested.isFinite && requested > 0 ? min(requested, 100_000) : minimum
        }
        let size = CGSize(width: dimension(textSize.width, minimum: minimumWidth), height: dimension(textSize.height, minimum: minimumHeight))
        self.textSize = size

        var starts: [Int] = []
        var lengths: [Int] = []
        var location = 0
        for paragraph in paragraphs {
            starts.append(location)
            let length = (paragraph as NSString).length
            lengths.append(length)
            location += length + 1
        }
        paragraphStarts = starts
        paragraphLengths = lengths
        let text = paragraphs.joined(separator: "\n")
        let source = text as NSString
        chapterText = source
        guard source.length > 0, !Task.isCancelled else { pages = []; return }

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = min(pointSize * 2, max(0, size.width - pointSize * 2))
        style.headIndent = 0
        style.lineSpacing = spacing
        style.paragraphSpacing = max(6, pointSize * 0.45)
        style.alignment = .justified
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        let normalStyle = style.copy() as! NSParagraphStyle
        style.firstLineHeadIndent = 0
        let continuationStyle = style.copy() as! NSParagraphStyle
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: normalStyle,
            NSAttributedString.Key(kCTLanguageAttributeName as String): "zh-Hans",
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var result: [ReaderPage] = []
        var cursor = 0
        paginationLoop: while cursor < source.length {
            if Task.isCancelled { break }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: cursor, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            var end = min(source.length, cursor + max(0, visible.length))
            if end < source.length {
                let cluster = source.rangeOfComposedCharacterSequence(at: end)
                if cluster.location < end { end = cluster.location }
            }
            if end <= cursor {
                // Never split a grapheme or loop indefinitely if a pathological
                // glyph is taller/wider than the requested text rectangle.
                end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: cursor))
            }
            let isContinuation = source.paragraphRange(for: NSRange(location: cursor, length: 0)).location < cursor
            func pageText(endingAt end: Int) -> NSAttributedString {
                let page = NSMutableAttributedString(attributedString: attributed.attributedSubstring(from: NSRange(location: cursor, length: end - cursor)))
                if isContinuation {
                    let firstParagraph = (page.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                    page.addAttribute(.paragraphStyle, value: continuationStyle, range: firstParagraph)
                }
                return NSAttributedString(attributedString: page)
            }
            var page = pageText(endingAt: end)
            // Ending a standalone attributed string can change Core Text's final
            // paragraph metrics. Validate the exact string that the UI will draw.
            while true {
                if Task.isCancelled { break paginationLoop }
                let pageSetter = CTFramesetterCreateWithAttributedString(page)
                let pageFrame = CTFramesetterCreateFrame(pageSetter, CFRange(location: 0, length: 0), path, nil)
                let drawnLength = CTFrameGetVisibleStringRange(pageFrame).length
                if drawnLength >= page.length { break }
                var adjustedEnd = cursor + max(0, drawnLength)
                if adjustedEnd < source.length {
                    adjustedEnd = source.rangeOfComposedCharacterSequence(at: adjustedEnd).location
                }
                if adjustedEnd <= cursor { adjustedEnd = NSMaxRange(source.rangeOfComposedCharacterSequence(at: cursor)) }
                guard adjustedEnd < end else { break }
                end = adjustedEnd
                page = pageText(endingAt: end)
            }
            let range = NSRange(location: cursor, length: end - cursor)
            let paragraph = Self.paragraphIndex(at: cursor, starts: starts)
            result.append(ReaderPage(
                attributedText: page,
                range: range,
                startPosition: ReaderTextPosition(paragraph: paragraph, utf16Offset: cursor - starts[paragraph])
            ))
            cursor = end
        }
        pages = result
    }

    /// An out-of-range paragraph (including Int.max) resolves to the chapter end.
    func pageIndex(for position: ReaderTextPosition) -> Int {
        guard !pages.isEmpty, !paragraphStarts.isEmpty else { return 0 }
        if position.paragraph >= paragraphStarts.count { return pages.count - 1 }
        let paragraph = max(0, position.paragraph)
        let localOffset = min(max(0, position.utf16Offset), paragraphLengths[paragraph])
        var target = paragraphStarts[paragraph] + localOffset
        if target < chapterText.length {
            target = chapterText.rangeOfComposedCharacterSequence(at: target).location
        }
        var lower = 0
        var upper = pages.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].range.location <= target { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }

    private static func paragraphIndex(at location: Int, starts: [Int]) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= location { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }
}
