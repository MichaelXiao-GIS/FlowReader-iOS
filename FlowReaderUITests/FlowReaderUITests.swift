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
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let fontSize = app.sliders["reader-font-size"]
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

        navigateBack(until: startReading, labels: ["作品", "返回", "Back"])
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
