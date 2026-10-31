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
        if name.contains("testImmersiveCurlAndLandscapeSpread") { app.launchArguments.append("--long-reader-fixture") }
        app.launch()
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
        surface.swipeLeft()
        XCTAssertTrue(pageNumber.waitForExistence(timeout: 5))
        XCTAssertNotEqual(pageNumber.label, before, "左右轻扫应翻到下一页")
        capture("13-原生仿真翻页")
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
        XCTAssertTrue(app.staticTexts["连接账号服务后，可读取今日状态并签到。"].exists, "未连接账号服务时不能假装已读取签到状态")
        XCTAssertFalse(app.buttons["sign-in-submit"].exists, "未连接时不应显示可提交的签到操作")
        capture("09-会员与签到未连接")
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
