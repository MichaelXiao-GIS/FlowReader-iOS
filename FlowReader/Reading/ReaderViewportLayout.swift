import UIKit

/// Text and overlay controls share full-window coordinates. A local camera cutout
/// must never turn the system's conservative side inset into a full-height blank column.
struct ReaderViewportLayout {
    let contentFrame: CGRect
    let bookmarkFrame: CGRect
    let closeFrame: CGRect
    let toolsFrame: CGRect
    let progressFrame: CGRect

    init(size: CGSize, safeAreaInsets: UIEdgeInsets = .zero, occlusions: [CGRect] = []) {
        let width = size.width.isFinite && size.width > 0 ? size.width : 1
        let height = size.height.isFinite && size.height > 0 ? size.height : 1
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let regions = occlusions.filter { !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 }
            .map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        contentFrame = CurlPageLayout(size: CGSize(width: width, height: height), doublePage: false,
                                      safeAreaInsets: safeAreaInsets, occlusions: regions).textFrame
        let left = regions.isEmpty ? max(12, safeAreaInsets.left) : 12
        let right = regions.isEmpty ? max(12, safeAreaInsets.right) : 12
        let top = regions.isEmpty ? max(10, safeAreaInsets.top + 8) : 12
        let bottom = max(12, safeAreaInsets.bottom + 8)
        let usable = CGRect(x: left, y: top, width: max(1, width - left - right), height: max(1, height - top - bottom))
        let bookmark = CGRect(x: usable.minX + 4, y: usable.minY, width: 44, height: 44)
        bookmarkFrame = Self.place(bookmark, within: usable, avoiding: regions, horizontalCost: 3)
        let close = CGRect(x: usable.maxX - 48, y: usable.minY, width: 44, height: 44)
        closeFrame = Self.place(close, within: usable, avoiding: regions + [bookmarkFrame], horizontalCost: 3)
        let toolHeight: CGFloat = 184
        let tools = CGRect(x: usable.maxX - 52, y: min(max(closeFrame.maxY + 18, height * 0.16), usable.maxY - toolHeight),
                           width: 52, height: toolHeight)
        toolsFrame = Self.place(tools, within: usable, avoiding: regions + [bookmarkFrame, closeFrame], horizontalCost: 4)
        let progressWidth = min(620, max(1, usable.width - (height < 500 ? 136 : 8)))
        let progress = CGRect(x: width / 2 - progressWidth / 2, y: usable.maxY - 68, width: progressWidth, height: 68)
        progressFrame = Self.place(progress, within: usable, avoiding: regions + [bookmarkFrame, closeFrame, toolsFrame], horizontalCost: 2)
    }

    private static func place(_ preferred: CGRect, within bounds: CGRect, avoiding regions: [CGRect], horizontalCost: CGFloat) -> CGRect {
        let width = min(preferred.width, bounds.width), height = min(preferred.height, bounds.height)
        let initial = CGRect(x: min(max(preferred.minX, bounds.minX), bounds.maxX - width),
                             y: min(max(preferred.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
        let blocked = regions.map { $0.insetBy(dx: -8, dy: -8) }
        guard blocked.contains(where: { $0.intersects(initial) }) else { return initial }
        let xs = [initial.minX, bounds.minX, bounds.maxX - width] + blocked.flatMap { [$0.maxX, $0.minX - width] }
        let ys = [initial.minY, bounds.minY, bounds.maxY - height] + blocked.flatMap { [$0.maxY, $0.minY - height] }
        var best: CGRect?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for x in xs { for y in ys {
            let candidate = CGRect(x: x, y: y, width: width, height: height)
            guard bounds.contains(candidate), !blocked.contains(where: { $0.intersects(candidate) }) else { continue }
            let distance = abs(x - initial.minX) * horizontalCost + abs(y - initial.minY)
            if distance < bestDistance { best = candidate; bestDistance = distance }
        } }
        return best ?? initial
    }
}

enum ReaderProgressNavigation {
    static func fraction(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return Double(min(max(0, index), count - 1)) / Double(count - 1)
    }

    static func index(fraction: Double, count: Int) -> Int {
        guard count > 1, fraction.isFinite else { return 0 }
        return Int((min(max(0, fraction), 1) * Double(count - 1)).rounded())
    }

    static func bounded(_ position: ReaderTextPosition, paragraphs: [String]) -> ReaderTextPosition {
        guard !paragraphs.isEmpty else { return ReaderTextPosition(paragraph: 0, utf16Offset: 0) }
        let index = min(max(0, position.paragraph), paragraphs.count - 1)
        let text = paragraphs[index] as NSString
        let offset = min(max(0, position.utf16Offset), text.length)
        let safeOffset = offset < text.length ? text.rangeOfComposedCharacterSequence(at: offset).location : offset
        return ReaderTextPosition(paragraph: index, utf16Offset: safeOffset)
    }
}
