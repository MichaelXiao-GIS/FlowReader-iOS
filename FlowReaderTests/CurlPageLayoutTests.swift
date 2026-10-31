import XCTest
import UIKit
@testable import FlowReader

final class CurlPageLayoutTests: XCTestCase {
    func testDefaultPageUsesCompactMarginsAndSeparateFooter() {
        let layout = CurlPageLayout(size: CGSize(width: 400, height: 800), doublePage: false)
        XCTAssertEqual(layout.textFrame, CGRect(x: 20, y: 32, width: 360, height: 740))
        XCTAssertFalse(layout.textFrame.intersects(layout.headerFrame()))
        XCTAssertFalse(layout.textFrame.intersects(layout.footerFrame()))
    }

    func testLegacySafeInsetsAreNotMirroredOrAddedToSidePadding() {
        let safe = UIEdgeInsets(top: 48, left: 60, bottom: 24, right: 0)
        let layout = CurlPageLayout(size: CGSize(width: 600, height: 900), doublePage: false, safeAreaInsets: safe)
        XCTAssertEqual(layout.textFrame.minX, 60)
        XCTAssertEqual(layout.textSize.width, 520)
        XCTAssertEqual(layout.textFrame.minY, 80)
        XCTAssertEqual(layout.textFrame.maxY, 848)
        XCTAssertFalse(layout.textFrame.intersects(layout.footerFrame()))
    }

    func testUpperCornerCameraOnlyReservesTopBand() {
        let size = CGSize(width: 600, height: 1000)
        let camera = CGRect(x: 0, y: 0, width: 92, height: 72)
        let safe = UIEdgeInsets(top: 0, left: 100, bottom: 34, right: 100)
        let layout = CurlPageLayout(size: size, doublePage: false, safeAreaInsets: safe, occlusions: [camera])
        XCTAssertEqual(layout.textSize.width, size.width - 40)
        XCTAssertEqual(layout.textFrame.minX, 20)
        XCTAssertEqual(layout.textFrame.minY, camera.maxY + 8)
        XCTAssertFalse(layout.textFrame.intersects(camera))
        XCTAssertFalse(layout.headerFrame().intersects(camera))
        XCTAssertFalse(layout.textFrame.intersects(layout.footerFrame()))
        XCTAssertEqual(layout.headerFrame().minY, 12)
    }

    func testLowerCornerCameraKeepsFullTextWidthAndFooterClear() {
        let size = CGSize(width: 600, height: 1000)
        let camera = CGRect(x: 512, y: 928, width: 88, height: 72)
        let layout = CurlPageLayout(size: size, doublePage: false,
                                   safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 96), occlusions: [camera])
        XCTAssertEqual(layout.textSize.width, size.width - 40)
        XCTAssertEqual(layout.textFrame.maxY, camera.minY - 8)
        XCTAssertFalse(layout.textFrame.intersects(camera))
        XCTAssertFalse(layout.footerFrame().intersects(camera))
        XCTAssertFalse(layout.textFrame.intersects(layout.footerFrame()))
    }

    func testMidSideCutoutRetainsNecessarySpaceOnlyOnThatSide() {
        let camera = CGRect(x: 0, y: 390, width: 74, height: 80)
        let layout = CurlPageLayout(size: CGSize(width: 600, height: 1000), doublePage: false,
                                   safeAreaInsets: UIEdgeInsets(top: 0, left: 74, bottom: 24, right: 0), occlusions: [camera])
        XCTAssertEqual(layout.textFrame.minX, 82)
        XCTAssertEqual(layout.textFrame.maxX, 580)
        XCTAssertFalse(layout.textFrame.intersects(camera))
    }

    func testSpreadHasUniformTextWidthsWithoutWastingCornerSafeInset() {
        let size = CGSize(width: 1200, height: 800)
        let camera = CGRect(x: 1108, y: 0, width: 92, height: 72)
        let layout = CurlPageLayout(size: size, doublePage: true,
                                   safeAreaInsets: UIEdgeInsets(top: 0, left: 100, bottom: 24, right: 100), occlusions: [camera])
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.textSize.width, size.width / 2 - 40)
        XCTAssertFalse(layout.textFrame.intersects(camera))
        XCTAssertFalse(layout.textFrame.offsetBy(dx: layout.pageSize.width, dy: 0).intersects(camera))
        XCTAssertFalse(layout.headerFrame(column: 1).offsetBy(dx: layout.pageSize.width, dy: 0).intersects(camera))
        XCTAssertEqual(CurlPageReader.textSize(for: size, doublePage: true,
                                             safeAreaInsets: UIEdgeInsets(top: 0, left: 100, bottom: 24, right: 100), occlusions: [camera]), layout.textSize)
    }
}
