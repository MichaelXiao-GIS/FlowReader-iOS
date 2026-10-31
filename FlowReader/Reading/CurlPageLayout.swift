import UIKit

/// One geometry definition for pagination, page drawing and chrome labels.
/// Occlusions use the full reader viewport's coordinates, including in a spread.
struct CurlPageLayout {
    let pageSize: CGSize
    let textFrame: CGRect
    let columnCount: Int
    private let safeInsets: UIEdgeInsets
    private let occlusions: [CGRect]
    private let hasLocalizedOcclusions: Bool

    var textSize: CGSize { textFrame.size }

    init(size: CGSize, doublePage: Bool, safeAreaInsets: UIEdgeInsets = .zero, occlusions: [CGRect] = []) {
        let width = size.width.isFinite && size.width > 0 ? size.width : 1
        let height = size.height.isFinite && size.height > 0 ? size.height : 1
        columnCount = doublePage ? 2 : 1
        pageSize = CGSize(width: floor(width / CGFloat(columnCount)), height: floor(height))
        func inset(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
        let safe = UIEdgeInsets(top: inset(safeAreaInsets.top), left: inset(safeAreaInsets.left),
                                bottom: inset(safeAreaInsets.bottom), right: inset(safeAreaInsets.right))
        safeInsets = safe
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let regions = occlusions.compactMap { rect -> CGRect? in
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { return nil }
            let clipped = rect.intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        self.occlusions = regions
        hasLocalizedOcclusions = !regions.isEmpty
        let upper = regions.filter { $0.midY <= height * 0.25 }
        let lower = regions.filter { $0.midY >= height * 0.75 }
        let middle = regions.filter { $0.midY > height * 0.25 && $0.midY < height * 0.75 }

        var left: CGFloat = 20, right: CGFloat = 20
        let top: CGFloat, bottom: CGFloat
        if regions.isEmpty {
            left = max(20, safe.left)
            right = max(20, safe.right)
            top = safe.top + 32
            bottom = safe.bottom + 28
        } else {
            // Corner cameras only reserve a short band at the top/bottom. A coarse
            // left/right safe inset must not become an empty full-height column.
            top = max(36, (upper.map(\.maxY).max() ?? 28) + 8)
            bottom = max(28, max(height - (lower.map(\.minY).min() ?? height) + 8, safe.bottom + 24))
            if !middle.isEmpty {
                left = max(20, safe.left)
                right = max(20, safe.right)
                for region in middle {
                    let column = min(columnCount - 1, max(0, Int(region.midX / max(1, pageSize.width))))
                    let local = region.offsetBy(dx: -CGFloat(column) * pageSize.width, dy: 0)
                    if local.midX <= pageSize.width / 2 { left = max(left, local.maxX + 8) }
                    else { right = max(right, pageSize.width - local.minX + 8) }
                }
                // Every page must use the same Core Text width in a spread.
                if doublePage { left = max(left, right); right = left }
            }
        }
        textFrame = CGRect(x: left, y: top, width: max(1, pageSize.width - left - right),
                           height: max(1, pageSize.height - top - bottom))
    }

    func headerFrame(column: Int = 0) -> CGRect {
        let y = hasLocalizedOcclusions ? min(max(12, safeInsets.top + 10), max(12, textFrame.minY - 22)) : safeInsets.top + 10
        return labelFrame(y: y, height: 16, column: column, preferredWidth: nil)
    }

    func footerFrame(column: Int = 0) -> CGRect {
        labelFrame(y: max(0, pageSize.height - safeInsets.bottom - 22), height: 16, column: column, preferredWidth: 120)
    }

    private func labelFrame(y: CGFloat, height: CGFloat, column: Int, preferredWidth: CGFloat?) -> CGRect {
        let minX = min(textFrame.minX, max(0, pageSize.width - 1))
        let maxX = min(pageSize.width, max(minX, textFrame.maxX))
        var lanes: [ClosedRange<CGFloat>] = [minX...maxX]
        let columnX = CGFloat(min(max(0, column), columnCount - 1)) * pageSize.width
        for region in occlusions {
            let local = region.offsetBy(dx: -columnX, dy: 0)
            guard local.minY < y + height, local.maxY > y else { continue }
            let blocked = (local.minX - 8)...(local.maxX + 8)
            lanes = lanes.flatMap { lane -> [ClosedRange<CGFloat>] in
                guard blocked.lowerBound < lane.upperBound, blocked.upperBound > lane.lowerBound else { return [lane] }
                var remaining: [ClosedRange<CGFloat>] = []
                if blocked.lowerBound > lane.lowerBound { remaining.append(lane.lowerBound...min(lane.upperBound, blocked.lowerBound)) }
                if blocked.upperBound < lane.upperBound { remaining.append(max(lane.lowerBound, blocked.upperBound)...lane.upperBound) }
                return remaining
            }
        }
        lanes = lanes.filter { $0.upperBound - $0.lowerBound >= 24 }
        guard !lanes.isEmpty else { return .zero }
        if let preferredWidth {
            return lanes.map { lane -> CGRect in
                let width = min(preferredWidth, lane.upperBound - lane.lowerBound)
                let x = min(max(pageSize.width / 2 - width / 2, lane.lowerBound), lane.upperBound - width)
                return CGRect(x: x, y: y, width: width, height: height)
            }.min(by: { abs($0.midX - pageSize.width / 2) < abs($1.midX - pageSize.width / 2) })!
        }
        let widest = lanes.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound })!
        return CGRect(x: widest.lowerBound, y: y, width: widest.upperBound - widest.lowerBound, height: height)
    }
}
