import XCTest
@testable import FlowReader

final class CloudProgressTests: XCTestCase {
    func testReadingHistoryRequiresCorrectAccountAndActualChapter() throws {
        let rows: [[String: Any]] = [
            ["accountId": 10, "novelId": 30, "chapterId": 300, "lastViewTime": "2026-10-31T12:30:00+08:00"],
            ["accountId": 10, "novelId": 31, "chapterId": 0],
            ["accountId": 10, "novelId": 32, "chapterId": 320, "lastViewTime": "2026-10-31T12:30:00"]
        ]
        let result = try CloudProgressParser.readingHistory(rows, accountID: 10)
        XCTAssertEqual(result.map(\.bookID), [30, 32])
        XCTAssertEqual(result.first?.chapterID, 300)
        XCTAssertNotNil(result.first?.updatedAt)
        XCTAssertEqual(result.last?.updatedAt, result.first?.updatedAt, "Android explicitly treats the unzoned service date as GMT+8")
        XCTAssertThrowsError(try CloudProgressParser.readingHistory(rows, accountID: 11))
        XCTAssertThrowsError(try CloudProgressParser.readingHistory(["userID": 10, "nickName": "Profile"], accountID: 10), "A profile proxy response is not reading history")
    }

    func testExplicitTimezonesCompareEqualAndNewerDuplicateWins() throws {
        XCTAssertEqual(CloudProgressParser.parseTimestamp("2026-10-31T12:30:00+08:00"), CloudProgressParser.parseTimestamp("2026-10-31T04:30:00Z"))
        XCTAssertNotNil(CloudProgressParser.parseTimestamp("2026-10-31T04:30:00.123Z"))
        let rows: [[String: Any]] = [
            ["accountId": 10, "novelId": 30, "chapterId": 300, "lastViewTime": "2026-10-31T04:30:00Z"],
            ["accountId": 10, "novelId": 30, "chapterId": 301, "lastViewTime": "2026-10-31T05:30:00Z"]
        ]
        XCTAssertEqual(try CloudProgressParser.readingHistory(rows, accountID: 10).first?.chapterID, 301)
        XCTAssertThrowsError(try CloudProgressParser.readingHistory([["accountId": true, "novelId": 30, "chapterId": 300]], accountID: 1))
    }

    func testOfficialUnzonedTimestampUsesFixedBeijingTimeAndRejectsInvalidDates() {
        let expected = CloudProgressParser.parseTimestamp("2026-10-31T04:30:00Z")
        XCTAssertEqual(CloudProgressParser.parseTimestamp("2026-10-31T12:30:00"), expected)
        XCTAssertEqual(CloudProgressParser.parseTimestamp("2026-10-31T12:30:00+0800"), expected)
        // GMT+8 has no daylight-saving transition; device settings never enter this calculation.
        XCTAssertEqual(CloudProgressParser.parseTimestamp("2026-07-01T12:00:00"), CloudProgressParser.parseTimestamp("2026-07-01T04:00:00Z"))
        for value in ["null", "", "2026-02-30T12:30:00", "2026-10-31T25:00:00", "2026-10-31", "2026-10-31T12:30:00junk"] {
            XCTAssertNil(CloudProgressParser.parseTimestamp(value), value)
        }
    }

    func testHistorySortsKnownDatesAndKeepsUnknownStableWithoutUsingIDs() throws {
        let rows: [[String: Any]] = [
            ["accountId": 10, "novelId": 900, "chapterId": 99, "unreadChapCount": -1],
            ["accountId": 10, "novelId": 800, "chapterId": 88, "lastViewTime": "2026-10-31T12:00:00", "unreadChapCount": 4],
            ["accountId": 10, "novelId": 2, "chapterId": 22, "lastViewTime": "2026-10-31T13:00:00", "unreadChapCount": 0],
            ["accountId": 10, "novelId": 1, "chapterId": 11],
            ["accountId": 10, "novelId": 900, "chapterId": 100, "lastViewTime": "2026-10-31T11:00:00"],
            ["accountId": 10, "novelId": 2, "chapterId": 23, "lastViewTime": "invalid"]
        ]
        let history = try CloudProgressParser.readingHistory(rows, accountID: 10)
        XCTAssertEqual(history.map(\.bookID), [2, 800, 900, 1])
        XCTAssertEqual(history.first?.chapterID, 22, "An unknown duplicate date must not erase a known newer chapter")
        XCTAssertEqual(history.first?.unreadChapterCount, 0)
        XCTAssertEqual(history[1].unreadChapterCount, 4)
        XCTAssertEqual(history[2].chapterID, 100, "A real date supersedes the earlier unknown-date duplicate")
        XCTAssertNil(history.last?.unreadChapterCount)
    }

    func testCatalogProgressUsesActualSequenceAndDoesNotClaimFinalChapterIsFinished() throws {
        let chapters = [(99, 2), (400, 0), (3, 1)].map { id, order in
            Chapter(id: id, bookID: 7, volumeID: 1, volumeTitle: "正文", title: "原创测试", order: order)
        }
        let catalog = try CloudReadingCatalog(bookID: 7, chapters: chapters)
        XCTAssertEqual(catalog.fraction(chapterID: 400), 0)
        XCTAssertEqual(catalog.fraction(chapterID: 3), 1.0 / 3.0)
        XCTAssertEqual(catalog.fraction(chapterID: 99), 2.0 / 3.0)
        XCTAssertNil(catalog.fraction(chapterID: 404))
        XCTAssertThrowsError(try CloudReadingCatalog(bookID: 7, chapters: []))
        XCTAssertThrowsError(try CloudReadingCatalog(bookID: 8, chapters: chapters))
        XCTAssertThrowsError(try CloudReadingCatalog(bookID: 7, chapters: chapters + [chapters[0]]))
    }

    func testCatalogDenominatorRejectsPartialMalformedOrDuplicateDirectory() throws {
        let valid: [String: Any] = ["volumeList": [["volumeId": 4, "chapterList": [["chapId": 99], ["chapId": 3], ["chapId": 20]]]]]
        let chapters = try CloudReadingCatalog.parseChapters(valid, bookID: 7)
        XCTAssertEqual(chapters.map(\.id), [99, 3, 20])
        XCTAssertEqual(try CloudReadingCatalog(bookID: 7, chapters: chapters).fraction(chapterID: 20), 2.0 / 3.0)
        let malformed: [[String: Any]] = [
            ["volumeList": [["volumeId": 4, "chapterList": [["chapId": 99], [:], ["chapId": 20]]]]],
            ["volumeList": [["volumeId": 4, "chapterList": [["chapId": 99]]], ["volumeId": 5]]],
            ["volumeList": [["volumeId": false, "chapterList": [["chapId": 99]]]]],
            ["volumeList": [["volumeId": 4, "chapterList": [["chapId": 99], ["chapId": 99]]]]],
            ["volumeList": [["volumeId": 4, "chapterList": [["chapId": 99, "novelId": 8]]]]]
        ]
        for payload in malformed { XCTAssertThrowsError(try CloudReadingCatalog.parseChapters(payload, bookID: 7)) }
    }

    func testOnlyExplicitSuccessAcknowledgesReadingPosition() throws {
        try CloudProgressParser.requireAcknowledgment(Data(#"{"status":200}"#.utf8))
        for response in [#"{}"#, #"{"status":true}"#, #"{"status":200.5}"#, #"{"status":{"httpCode":200}}"#, #"{"status":500,"msg":"未完成"}"#, "<html>请登录</html>"] {
            XCTAssertThrowsError(try CloudProgressParser.requireAcknowledgment(Data(response.utf8)))
        }
    }

    func testExpiredWebSessionRemainsAuthenticationFailure() {
        XCTAssertThrowsError(try CloudProgressParser.requireAcknowledgment(Data(#"{"status":502,"msg":"用户没登陆"}"#.utf8))) { error in
            guard case SFAPIError.authenticationRequired(let message) = error else { return XCTFail("Expected authentication error") }
            XCTAssertEqual(message, "用户没登陆")
        }
    }
}
