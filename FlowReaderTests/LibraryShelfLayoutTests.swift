import SwiftUI
import XCTest
@testable import FlowReader

final class LibraryShelfLayoutTests: XCTestCase {
    func testStandardPhoneAndNarrowRailViewportUseThreeReadableColumns() {
        for width: CGFloat in [320, 350, 375, 393, 402, 420] {
            let layout = LibraryShelfLayout(availableWidth: width, dynamicTypeSize: .large)
            XCTAssertEqual(layout.columnCount, 3, "A \(width) pt book area should show three covers")
            XCTAssertGreaterThanOrEqual(layout.cardWidth, 88)
            XCTAssertEqual(layout.cardWidth / layout.coverHeight, 0.7, accuracy: 0.001)
            assertFits(layout, availableWidth: width)
        }
    }

    func testWideShelfAddsColumnsWithoutOversizedCovers() {
        let phone = LibraryShelfLayout(availableWidth: 390, dynamicTypeSize: .large)
        let medium = LibraryShelfLayout(availableWidth: 600, dynamicTypeSize: .large)
        let wide = LibraryShelfLayout(availableWidth: 900, dynamicTypeSize: .large)
        let maximum = LibraryShelfLayout(availableWidth: 1040, dynamicTypeSize: .large)
        let veryWide = LibraryShelfLayout(availableWidth: 1600, dynamicTypeSize: .large)
        XCTAssertGreaterThan(medium.columnCount, phone.columnCount)
        XCTAssertGreaterThan(wide.columnCount, medium.columnCount)
        XCTAssertLessThan(wide.cardWidth, 150)
        XCTAssertEqual(veryWide.columnCount, maximum.columnCount)
        XCTAssertEqual(veryWide.cardWidth, maximum.cardWidth)
        assertFits(medium, availableWidth: 600)
        assertFits(wide, availableWidth: 900)
        assertFits(veryWide, availableWidth: 1600)
    }

    func testAccessibilitySizesReduceColumnsAndPreserveTextSpace() {
        let regular = LibraryShelfLayout(availableWidth: 350, dynamicTypeSize: .large)
        let largeText = LibraryShelfLayout(availableWidth: 350, dynamicTypeSize: .accessibility1)
        let largestText = LibraryShelfLayout(availableWidth: 350, dynamicTypeSize: .accessibility5)
        XCTAssertEqual(largeText.columnCount, 2)
        XCTAssertEqual(largestText.columnCount, 1)
        XCTAssertGreaterThan(largeText.cardWidth, regular.cardWidth)
        XCTAssertGreaterThan(largestText.cardWidth, largeText.cardWidth)
        assertFits(largeText, availableWidth: 350)
        assertFits(largestText, availableWidth: 350)
    }

    func testRecommendationGridKeepsThreeColumnsAcrossPhoneAndDuoWidths() {
        for width: CGFloat in [320, 350, 393, 402, 678, 760] {
            let layout = LibraryShelfLayout(availableWidth: width, dynamicTypeSize: .large, maximumColumns: 3)
            XCTAssertEqual(layout.columnCount, 3)
            XCTAssertGreaterThanOrEqual(layout.cardWidth, 88)
            assertFits(layout, availableWidth: width)
        }
        let largeText = LibraryShelfLayout(availableWidth: 350, dynamicTypeSize: .accessibility1, maximumColumns: 3)
        XCTAssertEqual(largeText.columnCount, 2)
        let largestText = LibraryShelfLayout(availableWidth: 350, dynamicTypeSize: .accessibility5, maximumColumns: 3)
        XCTAssertEqual(largestText.columnCount, 1)
    }

    func testRotationAndTransientWidthsKeepFiniteGeometry() {
        for width: CGFloat in [0, -1, .nan, .infinity, 240, 350, 780] {
            let layout = LibraryShelfLayout(availableWidth: width, dynamicTypeSize: .large)
            XCTAssertGreaterThanOrEqual(layout.columnCount, 1)
            XCTAssertTrue(layout.cardWidth.isFinite && layout.cardWidth > 0)
            XCTAssertTrue(layout.coverHeight.isFinite && layout.coverHeight > 0)
            if width >= 240 && width.isFinite { assertFits(layout, availableWidth: width) }
        }
    }

    private func assertFits(_ layout: LibraryShelfLayout, availableWidth: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let occupied = CGFloat(layout.columnCount) * layout.cardWidth
            + CGFloat(layout.columnCount - 1) * layout.columnSpacing + 2 * layout.horizontalPadding
        XCTAssertEqual(occupied, min(availableWidth, LibraryShelfLayout.maximumWidth), accuracy: 0.01, file: file, line: line)
    }
}
