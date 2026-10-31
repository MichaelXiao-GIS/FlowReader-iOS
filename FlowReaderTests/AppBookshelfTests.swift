import XCTest
@testable import FlowReader

final class AppBookshelfTests: XCTestCase {
    private func novel(_ id: Int, author: String = "原创测试作者") -> [String: Any] {
        ["novelId": id, "novelName": "测试小说 \(id)", "authorName": author,
         "novelCover": "https://rs.sfacg.com/example.jpg", "charCount": 3000, "isFinish": true,
         "expand": ["latestchapter": ["title": "测试终章"]]]
    }

    private func pocket(_ id: Int, type: Int = 2, novels: [[String: Any]] = []) -> [String: Any] {
        ["accountId": 100, "pocketId": id, "typeId": type, "name": "分类 \(id)", "expand": ["novels": novels]]
    }

    func testWholeCollectionIsNotTruncatedAtOneHundredAndKeepsAuthors() throws {
        let rows = [pocket(1, novels: (1...132).map { novel($0) }),
                    pocket(2, novels: (133...270).map { novel($0) })]
        let result = try AppBookshelfProtocol.parse(rows, accountID: 100)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.books.count, 270)
        XCTAssertEqual(result.books.first?.author, "原创测试作者")
        XCTAssertEqual(result.books.last?.shelfName, "分类 2")
        XCTAssertEqual(result.books.first?.latestChapter, "测试终章")
        XCTAssertEqual(result.books.first?.wordCount, 3000)
        XCTAssertEqual(result.books.first?.isFinished, true)
    }

    func testOnlyConfirmedNovelPocketTypeIsReadAndDuplicatesAreMerged() throws {
        let rows = [pocket(1, type: 1, novels: [novel(999)]),
                    pocket(2, novels: [novel(1, author: "")]),
                    pocket(3, type: 3, novels: [novel(888)]),
                    pocket(4, type: 4, novels: [novel(777)]),
                    pocket(5, novels: [novel(1), novel(2)])]
        let result = try AppBookshelfProtocol.parse(rows, accountID: 100)
        XCTAssertEqual(result.books.map(\.id), [1, 2])
        XCTAssertEqual(result.books.first?.author, "原创测试作者")
        XCTAssertEqual(result.books.first?.shelfName, "分类 2")
        XCTAssertTrue(result.isComplete)
    }

    func testMissingNovelExpansionIsNotAnEmptyLibrary() throws {
        var missing = pocket(1)
        missing.removeValue(forKey: "expand")
        XCTAssertThrowsError(try AppBookshelfProtocol.parse([missing], accountID: 100))
        let partial = try AppBookshelfProtocol.parse([missing, pocket(2, novels: [novel(1)])], accountID: 100)
        XCTAssertEqual(partial.books.count, 1)
        XCTAssertEqual(partial.failedSectionCount, 1)
        XCTAssertFalse(partial.isComplete)
        let empty = try AppBookshelfProtocol.parse([pocket(1)], accountID: 100)
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.books.isEmpty)
    }

    func testForeignAccountAndMalformedIdentifiersRejectTheSnapshot() {
        XCTAssertThrowsError(try AppBookshelfProtocol.parse([pocket(1)], accountID: 200))
        XCTAssertThrowsError(try AppBookshelfProtocol.parse([pocket(1), pocket(1)], accountID: 100))
        var invalid = pocket(1)
        invalid["accountId"] = true
        XCTAssertThrowsError(try AppBookshelfProtocol.parse([invalid], accountID: 100))
        invalid = pocket(1)
        invalid["typeId"] = 2.5
        XCTAssertThrowsError(try AppBookshelfProtocol.parse([invalid], accountID: 100))
        XCTAssertThrowsError(try AppBookshelfProtocol.parse(["novels": []], accountID: 100))
    }

    func testInvalidBookCreatesVisiblePartialResultRatherThanSilentCompleteness() throws {
        var invalid = novel(2)
        invalid["novelId"] = false
        let result = try AppBookshelfProtocol.parse([pocket(1, novels: [novel(1), invalid])], accountID: 100)
        XCTAssertEqual(result.books.map(\.id), [1])
        XCTAssertEqual(result.failedSectionCount, 1)
        XCTAssertFalse(result.isComplete)
    }

    func testAppShelfRequiresItsOwnVerifiedSession() async {
        let api = SFAPI(loadPersistedSessions: false)
        do {
            _ = try await api.appBookshelfSync()
            XCTFail("An App session is required before networking")
        } catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected error: \(error)") } }
        do {
            _ = try await api.appBookshelfSync(expectedGeneration: UUID())
            XCTFail("A stale account generation must be rejected")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
