import SwiftUI

/// Uses the space left by system navigation, including Duo's native tab rail.
struct LibraryShelfLayout {
    static let maximumWidth: CGFloat = 1040
    let horizontalPadding: CGFloat = 16
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let columnCount: Int
    let cardWidth: CGFloat
    var coverHeight: CGFloat { cardWidth / 0.7 }

    init(availableWidth: CGFloat, dynamicTypeSize: DynamicTypeSize) {
        let width = availableWidth.isFinite ? max(1, min(availableWidth, Self.maximumWidth)) : 1
        let contentWidth = max(1, width - horizontalPadding * 2)
        let minimum: CGFloat
        let compact: Bool
        switch dynamicTypeSize {
        case .accessibility5: minimum = 300; compact = false
        case .accessibility4: minimum = 260; compact = false
        case .accessibility3: minimum = 216; compact = false
        case .accessibility2: minimum = 176; compact = false
        case .accessibility1: minimum = 144; compact = false
        case .xxxLarge: minimum = 136; compact = false
        default: minimum = 112; compact = true
        }
        columnSpacing = dynamicTypeSize.isAccessibilitySize ? 16 : 12
        rowSpacing = dynamicTypeSize.isAccessibilitySize ? 28 : 24
        let fitting = max(1, Int(floor((contentWidth + columnSpacing) / (minimum + columnSpacing))))
        // Three covers remain legible down to 88 pt each. Standard phone widths use
        // three columns; larger windows grow the shelf without oversized covers.
        if compact && contentWidth >= 88 * 3 + columnSpacing * 2 {
            columnCount = max(3, fitting)
        } else {
            columnCount = fitting
        }
        cardWidth = max(1, (contentWidth - CGFloat(columnCount - 1) * columnSpacing) / CGFloat(columnCount))
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: columnSpacing, alignment: .topLeading), count: columnCount)
    }
}
