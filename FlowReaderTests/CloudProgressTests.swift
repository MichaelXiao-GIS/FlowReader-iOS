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
        XCTAssertNil(result.last?.updatedAt, "An unspecified server timezone must not become a guessed date")
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
