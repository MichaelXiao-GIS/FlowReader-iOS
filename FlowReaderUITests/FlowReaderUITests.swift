import XCTest

@MainActor
final class FlowReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Normalize the test runner and the app scene before synthesizing taps on Duo.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if name.contains("testImmersiveCurlAndLandscapeSpread") || name.contains("testBooksControlsBookmarksAndProgress") || name.contains("testHomeAndColdLaunchRestoreReading") { app.launchArguments.append("--long-reader-fixture") }
        if name.contains("testOfflineWalletAndSingleChapterConfirmation") { app.launchArguments.append("--chapter-purchase-fixture") }
        if name.contains("testRecommendationsUseThreeColumnsAndScrollVertically") { app.launchArguments.append("--discover-grid-fixture") }
        if name.contains("testLongContentsLocateReverseAndKeepNaturalChapterNavigation") { app.launchArguments.append("--long-catalog-fixture") }
        app.launch()
    }

    func testLongContentsLocateReverseAndKeepNaturalChapterNavigation() throws {
        // All IDs are negative and all visited text is pre-cached original fixture content.
        // No scrolling is used to find the initial chapter, the latest chapter or the locate target.
        let book = app.buttons["book--100"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        let start = app.buttons["start-reading"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(start.label, "继续阅读")
        start.tap()
        assertLongCatalogChapter(876)
        toggleReaderTools()
        app.buttons["reader-contents"].tap()

        let order = app.segmentedControls["reader-contents-order"]
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        XCTAssertTrue(order.buttons["正序"].isSelected)
        assertVisibleWithoutScrolling(longCatalogRow(876), message: "打开1200章目录应自动定位第876章，无须手动滚动")
        XCTAssertTrue(longCatalogRow(876).isSelected, "当前章节应向辅助功能明确标记为正在阅读")
        capture("41-长目录自动定位当前")

        order.buttons["倒序"].tap()
        assertVisibleWithoutScrolling(longCatalogRow(1_200), message: "切换倒序应直接显示最新第1200章")
        assertVisibleWithoutScrolling(longCatalogRow(1_199), message: "倒序应保留相邻章节顺序")
        XCTAssertLessThan(longCatalogRow(1_200).frame.minY, longCatalogRow(1_199).frame.minY)
        capture("42-倒序最新章在顶")

        // Reversing back must target the original first chapter, not an inferred numeric ID order.
        order.buttons["正序"].tap()
        assertVisibleWithoutScrolling(longCatalogRow(1), message: "切回正序应显示原目录第一章")
        order.buttons["倒序"].tap()
        assertVisibleWithoutScrolling(longCatalogRow(1_200), message: "再次倒序仍应回到最新章")
        app.buttons["reader-contents-locate"].tap()
        assertVisibleWithoutScrolling(longCatalogRow(876), message: "定位按钮应从最新章直接回当前章")
        assertVisibleWithoutScrolling(longCatalogRow(877), message: "当前章前一行应显示下一卷首章")
        XCTAssertLessThan(longCatalogRow(877).frame.minY, longCatalogRow(876).frame.minY,
                          "倒序必须同时反转卷序与卷内顺序：卷6第877章在卷5第876章上方")
        capture("43-倒序跨卷定位")

        app.buttons["reader-contents-done"].tap()
        XCTAssertTrue(order.waitForNonExistence(timeout: 5))
        app.buttons["reader-contents"].tap()
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        XCTAssertTrue(order.buttons["倒序"].isSelected, "关闭再打开目录应保留选择的排列方式")
        assertVisibleWithoutScrolling(longCatalogRow(876), message: "重新打开目录仍定位当前章，不跳回倒序顶端")
        longCatalogRow(877).tap()
        assertLongCatalogChapter(877)

        // Presentation order must never replace the canonical chapter sequence used by the reader.
        toggleReaderTools()
        app.buttons["reader-next-chapter"].tap()
        assertLongCatalogChapter(878)
        toggleReaderTools()
        app.buttons["reader-previous-chapter"].tap()
        assertLongCatalogChapter(877)
        toggleReaderTools()
        app.buttons["reader-previous-chapter"].tap()
        assertLongCatalogChapter(876)

        toggleReaderTools()
        app.buttons["reader-close"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        assertLongCatalogChapter(876)
        toggleReaderTools()
        app.buttons["reader-contents"].tap()
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        XCTAssertTrue(order.buttons["倒序"].isSelected, "重建阅读器后仍记住目录排序")
        assertVisibleWithoutScrolling(longCatalogRow(876), message: "重建阅读器后目录仍自动定位保存的阅读章节")
    }

    private func longCatalogRow(_ number: Int) -> XCUIElement {
        let id = -20_000 - ((number - 1) * 53 % 1_200)
        return app.buttons["reader-chapter-\(id)"]
    }

    private func assertLongCatalogChapter(_ number: Int, file: StaticString = #filePath, line: UInt = #line) {
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "这是长目录离线样书的第\(number)章。")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10), "应读取本机第\(number)章正文", file: file, line: line)
    }

    private func assertVisibleWithoutScrolling(_ element: XCUIElement, message: String, file: StaticString = #filePath, line: UInt = #line) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.exists && element.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, message, file: file, line: line)
    }

    func testRecommendationsUseThreeColumnsAndScrollVertically() throws {
        let first = app.buttons["book--100"]
        let second = app.buttons["book--201"]
        let third = app.buttons["book--202"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.exists && third.exists)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 3)
        XCTAssertEqual(first.frame.minY, third.frame.minY, accuracy: 3)
        XCTAssertLessThan(first.frame.midX, second.frame.midX)
        XCTAssertLessThan(second.frame.midX, third.frame.midX)
        XCTAssertGreaterThanOrEqual(first.frame.minX, app.windows.firstMatch.frame.minX)
        XCTAssertLessThanOrEqual(third.frame.maxX, app.windows.firstMatch.frame.maxX)
        capture("34-纵向三列推荐")
        let fourth = app.buttons["book--203"]
        if !fourth.exists || !fourth.isHittable { app.swipeUp() }
        XCTAssertTrue(fourth.waitForExistence(timeout: 5))
        XCTAssertTrue(fourth.isHittable, "下一行推荐应通过纵向滚动访问")
    }

    func testOfflineWalletAndSingleChapterConfirmation() throws {
        // This explicit fixture replaces every wallet/quote/order closure. It cannot call the live API.
        selectTab("我的")
        let fireMoney = app.descendants(matching: .any)["wallet-fire-money"].firstMatch
        reveal(fireMoney)
        XCTAssertTrue(fireMoney.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wallet-coupons"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["wallet-gold-coins"].firstMatch.exists)
        capture("31-离线账号余额")
        selectTab("发现")
        let book = app.buttons["book--100"]
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        let start = app.buttons["start-reading"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let review = app.buttons["purchase-review"]
        XCTAssertTrue(app.descendants(matching: .any)["purchase-price"].firstMatch.waitForExistence(timeout: 5))
        capture("32-单章价格确认前")
        reveal(review)
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["离线测试读者"].exists)
        review.tap()
        let confirm = app.buttons.matching(identifier: "purchase-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("33-原生购买确认")
        dismissPurchaseConfirmation()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["purchase-read"].exists, "取消确认不能解锁章节")
        review.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let read = app.buttons["purchase-read"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        XCTAssertFalse(review.exists, "已确认可读后不再出现重复购买入口")
        read.tap()
        XCTAssertTrue(app.staticTexts["reader-paragraph-0"].waitForExistence(timeout: 10))
    }

    private func dismissPurchaseConfirmation() {
        let cancel = app.buttons.matching(identifier: "purchase-cancel").firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap(); return }
        let labelledCancel = app.buttons.matching(NSPredicate(format: "label == %@", "取消")).firstMatch
        if labelledCancel.exists && labelledCancel.isHittable { labelledCancel.tap(); return }

        // The native popover form of confirmationDialog omits its cancel action.
        // Dismiss through its backdrop, choosing a point outside the actual popover.
        let popover = app.popovers.firstMatch
        let regions = app.otherElements.matching(identifier: "PopoverDismissRegion").allElementsBoundByIndex
        guard popover.exists, let region = regions.last else { return XCTFail("应有原生取消按钮或浮层关闭区域") }
        let bounds = app.windows.firstMatch.frame
        let safeBounds = bounds.insetBy(dx: 24, dy: 24)
        // Side midpoints avoid status/Dynamic Island touches being consumed by the system.
        let candidates = [CGPoint(x: safeBounds.minX + 1, y: safeBounds.midY),
                          CGPoint(x: safeBounds.maxX - 1, y: safeBounds.midY),
                          CGPoint(x: safeBounds.midX, y: safeBounds.minY + max(72, safeBounds.height * 0.12)),
                          CGPoint(x: safeBounds.midX, y: safeBounds.maxY - 48)]
        guard let point = candidates.first(where: { safeBounds.contains($0) && region.frame.contains($0) && !popover.frame.insetBy(dx: -12, dy: -12).contains($0) }) else {
            return XCTFail("未找到确认浮层之外的原生关闭区域")
        }
        region.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - region.frame.minX, dy: point.y - region.frame.minY)).tap()
    }

    func testReadChangeTypographyAndChapterThenReturnToLibrary() throws {
        let book = app.buttons["book--100"]
        XCTAssertTrue(book.waitForExistence(timeout: 15), "原创样书应在离线测试模式下出现")
        capture("01-发现")
        book.tap()

        let startReading = app.buttons["start-reading"]
        XCTAssertTrue(startReading.waitForExistence(timeout: 10))
        capture("02-作品详情")
        app.buttons["download-chapters"].tap()
        let selectAll = app.buttons["download-select-all"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        let confirmDownload = app.buttons["download-selection-confirm"]
        XCTAssertTrue(confirmDownload.isEnabled)
        confirmDownload.tap()
        XCTAssertTrue(confirmDownload.waitForNonExistence(timeout: 5), "下载确认应关闭章节选择面板")
        XCTAssertTrue(startReading.waitForExistence(timeout: 5))
        XCTAssertTrue(startReading.isHittable, "下载完成后应能从详情页继续阅读")
        startReading.tap()

        let firstParagraph = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "海风穿过街角时，书店的铜铃轻轻响了一声。")).firstMatch
        XCTAssertTrue(firstParagraph.waitForExistence(timeout: 10), "应从本地样书加载第一章正文")
        capture("03-阅读")

        let settings = app.buttons["reader-settings"]
        XCTAssertFalse(settings.exists, "进入正文应默认隐藏阅读工具")
        toggleReaderTools()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let fontSize = app.sliders["reader-font-size"]
        reveal(fontSize)
        XCTAssertTrue(fontSize.waitForExistence(timeout: 5))
        fontSize.adjust(toNormalizedSliderPosition: 0.15)
        let initialValue = fontSize.value as? String
        fontSize.adjust(toNormalizedSliderPosition: 0.72)
        XCTAssertNotEqual(fontSize.value as? String, initialValue, "字号应响应调整")
        capture("04-阅读设置")
        fontSize.adjust(toNormalizedSliderPosition: 0.3)
        app.buttons["reader-settings-done"].tap()

        app.buttons["reader-contents"].tap()
        let secondChapter = app.buttons["reader-chapter--1001"]
        XCTAssertTrue(secondChapter.waitForExistence(timeout: 5))
        capture("05-章节目录")
        secondChapter.tap()
        let secondParagraph = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第二天清晨，林夏在书店门口发现了一个纸包。")).firstMatch
        XCTAssertTrue(secondParagraph.waitForExistence(timeout: 5), "目录选择应实际切换到第二章正文")
        capture("06-第二章")

        toggleReaderTools()
        app.buttons["reader-close"].tap()
        XCTAssertTrue(startReading.waitForExistence(timeout: 5))
        XCTAssertEqual(startReading.label, "继续阅读")
        navigateBack(until: book, labels: ["现在就读", "返回", "Back"])
        selectTab("书库")
        selectLibraryScope("本机书籍")
        XCTAssertTrue(app.staticTexts["我的藏书"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第二章 风从远方来"].exists, "书库应保留刚才的阅读位置")
        capture("07-书库与续读")
        selectTab("下载")
        XCTAssertTrue(app.staticTexts["已保存到书库"].waitForExistence(timeout: 5), "已缓存的原创样书应完成下载任务")
    }

    func testImmersiveCurlAndLandscapeSpread() throws {
        let book = app.buttons["book--100"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        let start = app.buttons["start-reading"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["reader-paragraph-0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["reader-close"].exists)
        XCTAssertFalse(app.buttons["reader-settings"].exists)
        capture("11-沉浸式阅读")
        toggleReaderTools()
        let settings = app.buttons["reader-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        capture("12-轻点显示玻璃工具")
        settings.tap()
        let mode = app.segmentedControls["reader-turn-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons["仿真翻页"].tap()
        let fontControl = app.sliders["reader-font-size"]
        reveal(fontControl)
        fontControl.adjust(toNormalizedSliderPosition: 0.6)
        app.buttons["reader-settings-done"].tap()
        toggleReaderTools()
        let pageNumber = app.staticTexts["reader-page-number"].firstMatch
        XCTAssertTrue(pageNumber.waitForExistence(timeout: 10))
        let surface = app.otherElements["reader-content"].firstMatch
        let window = app.windows.firstMatch
        XCTAssertEqual(surface.frame.minY, window.frame.minY, accuracy: 1, "卷页纸张应覆盖顶部安全区")
        XCTAssertEqual(surface.frame.maxY, window.frame.maxY, accuracy: 1, "卷页纸张应覆盖底部安全区")
        if surface.frame.height > surface.frame.width {
            XCTAssertGreaterThan(app.staticTexts["reader-page-text"].firstMatch.frame.width, surface.frame.width * 0.8,
                                 "单页正文不应为角落摄像头保留整条宽侧栏")
        }
        let before = pageNumber.label
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "reader-flexible-curl").firstMatch.exists, "普通翻页应使用二维跟手纸面")
        let grab = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
        let smallDrag = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.59))
        grab.press(forDuration: 0.05, thenDragTo: smallDrag, withVelocity: .slow, thenHoldForDuration: 0.25)
        XCTAssertEqual(pageNumber.label, before, "短拖动松手应取消翻页并保持位置")
        let corner = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
        let diagonal = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.35))
        corner.press(forDuration: 0.05, thenDragTo: diagonal, withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(pageNumber.waitForExistence(timeout: 5))
        XCTAssertNotEqual(pageNumber.label, before, "斜向拖动应翻到下一页")
        let after = pageNumber.label
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(pageNumber.waitForExistence(timeout: 10))
        XCTAssertEqual(pageNumber.label, after, "卷页阅读返回前台应保持当前页")
        capture("13-跟手仿真翻页")
        let anchor = String(app.staticTexts["reader-page-text"].firstMatch.label.prefix(12))

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeWindow = NSPredicate { _, _ in
            let frame = self.app.windows.firstMatch.frame
            return frame.width > frame.height
        }
        // Device Hub's Duo posture can be independent of XCUIDevice.orientation.
        // Run this case with the active Duo display physically horizontal when needed.
        let rotated = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscapeWindow, object: nil)], timeout: 3)
        try XCTSkipIf(rotated != .completed, "模拟器未应用横屏姿态；请在 Device Hub 将当前 Duo 屏幕旋转为横屏后重跑此用例。")
        let pages = app.staticTexts.matching(identifier: "reader-page-number")
        let spread = NSPredicate { _, _ in pages.count == 2 }
        expectation(for: spread, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertNotEqual(pages.element(boundBy: 0).label, pages.element(boundBy: 1).label)
        XCTAssertTrue(app.staticTexts.matching(identifier: "reader-page-text").allElementsBoundByIndex.map(\.label).joined().contains(anchor), "横屏重排应保留当前文字位置")
        capture("14-横屏双页")
        toggleReaderTools()
        settings.tap()
        let spreadToggle = app.switches["reader-landscape-spread"]
        XCTAssertTrue(spreadToggle.waitForExistence(timeout: 5))
        let switchControl = spreadToggle.switches.firstMatch
        if switchControl.exists { switchControl.tap() } else { spreadToggle.tap() }
        XCTAssertEqual(spreadToggle.value as? String, "0", "双栏开关应关闭")
        app.buttons["reader-settings-done"].tap()
        expectation(for: NSPredicate { _, _ in pages.count == 1 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        capture("15-横屏单页")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["reader-close"].waitForExistence(timeout: 5))
        app.buttons["reader-close"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["reader-page-number"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["reader-settings"].exists, "重新进入阅读仍默认沉浸")
    }

    func testBooksControlsBookmarksAndProgress() throws {
        let book = app.buttons["book--100"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        let start = app.buttons["start-reading"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["reader-paragraph-0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["reader-bookmark"].exists)
        toggleReaderTools()
        let bookmark = app.buttons["reader-bookmark"]
        let settings = app.buttons["reader-settings"]
        let contents = app.buttons["reader-contents"]
        let progress = app.sliders["reader-progress"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(settings.frame.midX, bookmark.frame.midX + 80)
        XCTAssertEqual(settings.frame.midX, contents.frame.midX, accuracy: 8, "阅读设置应沿右侧竖排")
        XCTAssertGreaterThan(settings.frame.midY, contents.frame.midY)
        XCTAssertFalse(app.descendants(matching: .any)["reader-chrome-title"].exists, "工具栏不应再次显示正文已有的书名与章节")
        capture("20-Books式阅读工具")
        bookmark.tap()
        XCTAssertEqual(bookmark.label, "移除此处书签")
        let initialProgress = progress.value as? String
        progress.adjust(toNormalizedSliderPosition: 0.65)
        XCTAssertNotEqual(progress.value as? String, initialProgress, "底部滑条必须改变当前章节的真实位置")
        XCTAssertEqual(bookmark.label, "添加此处书签", "跳转后应离开原书签位置")
        capture("21-拖动章节进度")
        app.buttons["reader-more"].tap()
        let bookmarkList = app.buttons["reader-bookmarks-menu"]
        XCTAssertTrue(bookmarkList.waitForExistence(timeout: 5))
        bookmarkList.tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reader-bookmark-")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        capture("22-本机书签")
        saved.tap()
        XCTAssertTrue(app.staticTexts["reader-paragraph-0"].waitForExistence(timeout: 5))
        toggleReaderTools()
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertEqual(bookmark.label, "移除此处书签", "选择书签应回到保存的段落")
        app.buttons["reader-close"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["reader-paragraph-0"].waitForExistence(timeout: 10))
        toggleReaderTools()
        XCTAssertEqual(bookmark.label, "移除此处书签", "关闭阅读后书签仍然保留")
    }

    func testHomeAndColdLaunchRestoreReading() throws {
        let book = app.buttons["book--100"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        let start = app.buttons["start-reading"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["reader-paragraph-0"].waitForExistence(timeout: 10))
        toggleReaderTools()
        let progress = app.sliders["reader-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        progress.adjust(toNormalizedSliderPosition: 0.65)
        let savedValue = progress.value as? String
        let savedDescription = app.staticTexts["reader-progress-label"].label

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(progress.waitForExistence(timeout: 10), "立即返回应保持已打开的阅读工具，不能重新建立阅读页面")
        XCTAssertEqual(progress.value as? String, savedValue)
        XCTAssertEqual(app.staticTexts["reader-progress-label"].label, savedDescription)
        capture("30-返回前台保留阅读")

        app.terminate()
        app.launchArguments.append("--uitesting-preserve-state")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "reader-content").firstMatch.waitForExistence(timeout: 15), "进程重新启动后应自动恢复阅读页面")
        XCTAssertFalse(app.buttons["reader-close"].exists, "冷启动恢复仍默认沉浸")
        toggleReaderTools()
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.value as? String, savedValue)
        XCTAssertEqual(app.staticTexts["reader-progress-label"].label, savedDescription)
        capture("31-冷启动恢复段落位置")

        app.buttons["reader-close"].tap()
        selectTab("书库")
        XCTAssertTrue(app.segmentedControls["library-scope"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.segmentedControls["library-scope"].waitForExistence(timeout: 10), "退出阅读后冷启动应恢复书库页签")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "reader-content").firstMatch.exists, "明确关闭的阅读页面不能再次弹出")
    }

    private func toggleReaderTools() {
        // Resolve the visible reading surface so XCTest retains its display/hit-point context.
        // An application-root coordinate can target Duo's inactive primary display.
        let surface = app.descendants(matching: .any).matching(identifier: "reader-content").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        surface.tap()
    }

    func testNativeTabsAndAccountEntry() throws {
        XCTAssertTrue(app.buttons["book--100"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(app.buttons["book--100"].waitForExistence(timeout: 5), "下拉刷新后应保留书架内容")
        XCTAssertFalse(app.staticTexts["暂时无法加载"].exists, "刷新取消不应变成错误页面")
        selectTab("下载")
        XCTAssertTrue(app.staticTexts["把故事带在身边"].waitForExistence(timeout: 5), "每次独立测试启动后下载队列应为空")
        capture("08-下载")

        selectTab("书库")
        selectLibraryScope("云端书架")
        XCTAssertTrue(app.buttons["cloud-library-login"].waitForExistence(timeout: 5), "未连接时云端书架应提供登录入口")
        capture("08-云端书架未连接")
        selectLibraryScope("本机书籍")
        XCTAssertTrue(app.buttons["library-local--100"].waitForExistence(timeout: 5), "切换来源后本机样书应保留")

        selectTab("我的")
        XCTAssertFalse(app.staticTexts["账号书架"].exists, "我的页面不应再容纳云端书籍列表")
        let benefits = app.buttons["account-benefits"]
        reveal(benefits)
        benefits.tap()
        let connect = app.buttons["benefits-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        let signInHint = app.staticTexts["连接账号服务后，可读取今日状态并签到。"]
        reveal(signInHint)
        XCTAssertTrue(signInHint.exists, "未连接账号服务时不能假装已读取签到状态")
        XCTAssertFalse(app.buttons["sign-in-submit"].exists, "未连接时不应显示可提交的签到操作")
        capture("09-会员与签到未连接")
        for _ in 0..<6 {
            if connect.exists && connect.isHittable { break }
            app.swipeDown()
        }
        connect.tap()
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["连接账号服务"].exists)
        app.navigationBars.buttons["取消"].tap()
        navigateBack(until: benefits, labels: ["我的", "返回", "Back"])

        let about = app.buttons["关于菠萝阅"]
        reveal(about)
        capture("09-账户")
        about.tap()
        XCTAssertTrue(app.staticTexts["FLOW READER"].waitForExistence(timeout: 5))
        capture("10-关于")
        app.navigationBars.buttons["完成"].tap()

        selectTab("发现")
        XCTAssertTrue(app.buttons["book--100"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields.firstMatch.exists, "发现页应显示原生搜索入口")
    }

    func testWelfareEntriesRequireLoginWithoutClaimActions() throws {
        XCTAssertTrue(app.buttons["book--100"].waitForExistence(timeout: 15))
        selectTab("我的")
        let benefits = app.buttons["account-benefits"]
        reveal(benefits)
        benefits.tap()
        XCTAssertTrue(app.buttons["benefits-connect"].waitForExistence(timeout: 5))

        let destinations = [
            (entry: "benefits-daily-welfare", login: "welfare-connect", actionPrefix: "welfare-task-", title: "日常福利"),
            (entry: "benefits-member-gifts", login: "member-gifts-connect", actionPrefix: "member-gift-", title: "会员礼包")
        ]
        for destination in destinations {
            let entry = app.buttons[destination.entry]
            reveal(entry)
            entry.tap()
            let login = app.buttons[destination.login]
            XCTAssertTrue(login.waitForExistence(timeout: 10), "\(destination.title)未登录时应提供登录入口")
            XCTAssertEqual(login.label, "登录菠萝包")
            let taskActions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", destination.actionPrefix))
            XCTAssertEqual(taskActions.count, 0, "未确认账号身份时不得展示匿名目录中的领取操作")
            for title in ["领取任务", "领取奖励", "领取礼包"] {
                XCTAssertFalse(app.buttons[title].exists, "未登录时不应出现\(title)按钮")
            }
            capture("16-\(destination.title)未登录")

            login.tap()
            let password = app.secureTextFields.firstMatch
            XCTAssertTrue(password.waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["连接账号服务"].exists)
            let submit = app.buttons["连接"]
            XCTAssertTrue(submit.waitForExistence(timeout: 5))
            XCTAssertFalse(submit.isEnabled, "空白登录表单不能提交")
            app.navigationBars.buttons["取消"].tap()
            XCTAssertTrue(password.waitForNonExistence(timeout: 5), "取消应关闭登录面板")
            XCTAssertTrue(login.waitForExistence(timeout: 5))
            XCTAssertEqual(taskActions.count, 0, "取消登录后仍不得出现领取操作")
            navigateBack(until: entry, labels: ["会员与签到", "返回", "Back"])
        }
        navigateBack(until: benefits, labels: ["我的", "返回", "Back"])
        XCTAssertTrue(benefits.waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "滚动后应能找到账号页入口")
    }

    private func selectLibraryScope(_ label: String) {
        let picker = app.segmentedControls["library-scope"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let option = picker.buttons[label]
        XCTAssertTrue(option.exists)
        if !option.isSelected { option.tap() }
    }

    private func selectTab(_ label: String) {
        let candidates = [app.tabBars.buttons[label], app.buttons[label], app.cells.containing(.staticText, identifier: label).firstMatch, app.staticTexts[label]]
        if let target = candidates.first(where: { $0.exists && $0.isHittable }) {
            target.tap()
            return
        }
        // Returning from a sheet can leave the native bar minimized after scrolling.
        app.swipeDown()
        if let target = candidates.first(where: { $0.exists && $0.isHittable }) {
            target.tap()
            return
        }
        // On the expanded Duo inner display the system may collapse the native sidebar.
        let sidebar = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sidebar' OR label CONTAINS '边栏' OR label CONTAINS '側邊欄'"))
        if let toggle = sidebar.allElementsBoundByIndex.first(where: \.isHittable) { toggle.tap() }
        if let target = candidates.first(where: { $0.exists && $0.isHittable }) { target.tap() }
        else { XCTFail("无法找到原生标签入口：\(label)") }
    }

    private func navigateBack(until destination: XCUIElement, labels: [String]) {
        if destination.exists && destination.isHittable { return }
        let railBack = app.buttons["BackButton"]
        if railBack.exists && railBack.isHittable {
            railBack.tap()
            if destination.waitForExistence(timeout: 3) { return }
        }
        for label in labels {
            let button = app.navigationBars.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                if destination.waitForExistence(timeout: 3) { return }
            }
        }
        // The edge gesture exercises the native navigation transition when a rail hides its label.
        app.swipeRight()
        XCTAssertTrue(destination.waitForExistence(timeout: 5), "原生返回导航应恢复上一页")
    }

    private func capture(_ name: String) {
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let attachment = XCTAttachment(screenshot: screen.screenshot())
            attachment.name = "\(name)-screen-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
