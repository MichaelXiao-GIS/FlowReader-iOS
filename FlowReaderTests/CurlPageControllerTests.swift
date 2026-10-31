import XCTest
import SwiftUI
import UIKit
@testable import FlowReader

@MainActor
final class CurlPageControllerTests: XCTestCase {
    func testDoublePageUsesNativeCurlWithTwoDistinctPages() throws {
        try withReader(doublePage: true, reduceMotion: false) { pager, pagination in
            XCTAssertEqual(pager.transitionStyle, .pageCurl)
            XCTAssertEqual(pager.spineLocation, .mid)
            XCTAssertTrue(pager.isDoubleSided)
            let visible = try XCTUnwrap(pager.viewControllers)
            XCTAssertEqual(visible.count, 2)
            guard visible.count == 2 else { return }
            XCTAssertFalse(visible[0] === visible[1])
            XCTAssertEqual(pageTexts(in: visible[0]), [pagination.pages[0].attributedText.string])
            XCTAssertEqual(pageTexts(in: visible[1]), [pagination.pages[1].attributedText.string])
            XCTAssertNotEqual(pageTexts(in: visible[0]), pageTexts(in: visible[1]))
        }
    }

    func testReducedMotionDoublePageScrollsTwoRealPagesAsOneSpread() throws {
        try withReader(doublePage: true, reduceMotion: true) { pager, pagination in
            XCTAssertEqual(pager.transitionStyle, .scroll)
            let visible = try XCTUnwrap(pager.viewControllers)
            XCTAssertEqual(visible.count, 1)
            let spread = try XCTUnwrap(visible.first)
            spread.loadViewIfNeeded()
            XCTAssertEqual(spread.children.count, 2)
            guard spread.children.count == 2 else { return }
            XCTAssertFalse(spread.children[0] === spread.children[1])
            XCTAssertEqual(pageTexts(in: spread), Array(pagination.pages.prefix(2)).map { $0.attributedText.string })
            XCTAssertNotEqual(pageTexts(in: spread.children[0]), pageTexts(in: spread.children[1]))

            // The next scroll item must advance a complete spread, not repeat its right page.
            let source = try XCTUnwrap(pager.dataSource)
            XCTAssertNil(source.pageViewController(pager, viewControllerBefore: spread))
            let next = try XCTUnwrap(source.pageViewController(pager, viewControllerAfter: spread))
            next.loadViewIfNeeded()
            XCTAssertEqual(next.children.count, 2)
            XCTAssertEqual(pageTexts(in: next), Array(pagination.pages[2..<4]).map { $0.attributedText.string })
        }
    }

    func testReducedMotionSinglePageUsesOneScrollLeaf() throws {
        try withReader(doublePage: false, reduceMotion: true) { pager, pagination in
            XCTAssertEqual(pager.transitionStyle, .scroll)
            let visible = try XCTUnwrap(pager.viewControllers)
            XCTAssertEqual(visible.count, 1)
            let leaf = try XCTUnwrap(visible.first)
            leaf.loadViewIfNeeded()
            XCTAssertTrue(leaf.children.isEmpty)
            XCTAssertEqual(pageTexts(in: leaf), [pagination.pages[0].attributedText.string])
        }
    }

    private func withReader(doublePage: Bool, reduceMotion: Bool,
                            verify: (UIPageViewController, ReaderPagination) throws -> Void) throws {
        let size = CGSize(width: doublePage ? 1200 : 600, height: 800)
        let paragraphs = (0..<60).map { index in
            "第\(index)段原创试读。海边的小书店刚刚开门，送信人把一封蓝色的信放在窗边。" +
            "店主记下今天的潮汐，然后翻到地图上第\(index)座灯塔，准备继续这段从未走过的旅程。"
        }
        let pagination = ReaderPagination(paragraphs: paragraphs, fontSize: 23, lineSpacing: 9, serif: false,
                                          textSize: CurlPageReader.textSize(for: size, doublePage: doublePage))
        XCTAssertGreaterThanOrEqual(pagination.pages.count, 4)
        guard pagination.pages.count >= 4 else { return }
        let reader = CurlPageReader(pagination: pagination,
                                    currentPosition: .constant(ReaderTextPosition(paragraph: 0, utf16Offset: 0)),
                                    doublePage: doublePage, background: .white, foreground: .black,
                                    bookTitle: "海边书店", chapterTitle: "蓝色的信",
                                    onToggleChrome: { XCTFail("Installing or querying pages must not toggle reader chrome") },
                                    onChapterBoundary: { _ in XCTFail("Querying the data source must not navigate chapters") },
                                    reduceMotion: reduceMotion)
        let host = CurlPageReader.ContainerController()
        let coordinator = reader.makeCoordinator()
        coordinator.attach(to: host)
        host.view.frame = CGRect(origin: .zero, size: size)
        defer {
            coordinator.detach()
            XCTAssertTrue(host.children.isEmpty, "Dismantling must remove the native page controller")
        }
        coordinator.update(reader)
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.children.count, 1)
        let pager = try XCTUnwrap(host.children.first as? UIPageViewController)
        try verify(pager, pagination)
    }

    private func pageTexts(in controller: UIViewController) -> [String] {
        controller.loadViewIfNeeded()
        return pageTexts(in: controller.view)
    }

    private func pageTexts(in view: UIView) -> [String] {
        if view.accessibilityIdentifier == "reader-page-text" {
            return [view.accessibilityLabel ?? ""]
        }
        return view.subviews.flatMap { pageTexts(in: $0) }
    }
}
