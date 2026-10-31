import XCTest
import UIKit
@testable import FlowReader

final class ReaderViewportLayoutTests: XCTestCase {
    func testDuoCornerCameraDoesNotCreateAFullHeightSideColumn() {
        let size = CGSize(width: 620, height: 940)
        let camera = CGRect(x: 528, y: 0, width: 92, height: 76)
        let layout = ReaderViewportLayout(size: size,
                                          safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 100),
                                          occlusions: [camera])
        XCTAssertEqual(layout.contentFrame.minX, 20)
        XCTAssertEqual(layout.contentFrame.maxX, 600)
        XCTAssertEqual(layout.contentFrame.width, size.width - 40)
        XCTAssertFalse(layout.contentFrame.intersects(camera))
        for frame in [layout.bookmarkFrame, layout.closeFrame, layout.headingFrame, layout.toolsFrame, layout.progressFrame] {
            XCTAssertFalse(frame.intersects(camera))
        }
    }

    func testBothLandscapeRotationsAvoidTheLocalizedCamera() {
        let size = CGSize(width: 940, height: 620)
        for camera in [CGRect(x: 0, y: 0, width: 92, height: 76), CGRect(x: 848, y: 544, width: 92, height: 76)] {
            let layout = ReaderViewportLayout(size: size,
                                              safeAreaInsets: UIEdgeInsets(top: 0, left: 100, bottom: 24, right: 100),
                                              occlusions: [camera])
            XCTAssertEqual(layout.contentFrame.width, size.width - 40)
            XCTAssertFalse(layout.contentFrame.intersects(camera))
            for frame in [layout.bookmarkFrame, layout.closeFrame, layout.headingFrame, layout.toolsFrame, layout.progressFrame] {
                XCTAssertFalse(frame.intersects(camera))
            }
            let controls = [layout.bookmarkFrame, layout.closeFrame, layout.headingFrame, layout.toolsFrame, layout.progressFrame]
            for (index, first) in controls.enumerated() {
                for second in controls.dropFirst(index + 1) { XCTAssertFalse(first.intersects(second)) }
            }
        }
    }

    func testPhoneKeepsSafeInsetsAndChromeDoesNotShrinkTextColumn() {
        let size = CGSize(width: 393, height: 852)
        let safe = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let layout = ReaderViewportLayout(size: size, safeAreaInsets: safe)
        XCTAssertEqual(layout.contentFrame.width, 353)
        XCTAssertEqual(layout.contentFrame, CurlPageLayout(size: size, doublePage: false, safeAreaInsets: safe).textFrame)
        XCTAssertGreaterThanOrEqual(layout.closeFrame.minY, safe.top)
        XCTAssertLessThanOrEqual(layout.progressFrame.maxY, size.height - safe.bottom)
        XCTAssertFalse(layout.toolsFrame.intersects(layout.progressFrame))
        XCTAssertFalse(layout.closeFrame.intersects(layout.toolsFrame))
    }

    func testProgressMapsExactlyToActualParagraphOrPageIndices() {
        XCTAssertEqual(ReaderProgressNavigation.index(fraction: 0, count: 120), 0)
        XCTAssertEqual(ReaderProgressNavigation.index(fraction: 1, count: 120), 119)
        XCTAssertEqual(ReaderProgressNavigation.fraction(index: 119, count: 120), 1)
        XCTAssertEqual(ReaderProgressNavigation.index(fraction: 0.5, count: 11), 5)
        XCTAssertEqual(ReaderProgressNavigation.index(fraction: .nan, count: 20), 0)
        XCTAssertEqual(ReaderProgressNavigation.index(fraction: 1, count: 0), 0)
        XCTAssertEqual(ReaderProgressNavigation.fraction(index: 0, count: 1), 0)
    }

    func testRestoredPositionIsClampedWithoutSplittingEmoji() {
        let paragraphs = ["甲👩🏽‍🚀乙", "最后一段"]
        let withinEmoji = ReaderProgressNavigation.bounded(.init(paragraph: 0, utf16Offset: 3), paragraphs: paragraphs)
        XCTAssertEqual(withinEmoji, ReaderTextPosition(paragraph: 0, utf16Offset: 1))
        let pastEnd = ReaderProgressNavigation.bounded(.init(paragraph: 999, utf16Offset: 999), paragraphs: paragraphs)
        XCTAssertEqual(pastEnd, ReaderTextPosition(paragraph: 1, utf16Offset: 4))
        XCTAssertEqual(ReaderProgressNavigation.bounded(.init(paragraph: -1, utf16Offset: -1), paragraphs: []),
                       ReaderTextPosition(paragraph: 0, utf16Offset: 0))
    }
}
