import XCTest
@testable import FlowReader

final class AccountShelfStateTests: XCTestCase {
    func testWebAccountsWithoutNumericIDRemainDistinct() {
        let first = AccountProfile(id: 0, name: "测试一", accountName: "first_account")
        let same = AccountProfile(id: 0, name: "更名", accountName: "first_account")
        let second = AccountProfile(id: 0, name: "测试二", accountName: "second_account")
        XCTAssertTrue(first.matchesAccountIdentity(same))
        XCTAssertFalse(first.matchesAccountIdentity(second))
        XCTAssertFalse(AccountProfile(id: 0, name: "未知", accountName: "").matchesAccountIdentity(AccountProfile(id: 0, name: "未知", accountName: "")))
    }

    func testInitialFailureIsNotPresentedAsAnEmptyShelf() {
        var state = AccountShelfState()
        let request = UUID()
        state.begin(request)
        state.fail(SFAPIError.server("服务暂时不可用"), for: request)
        XCTAssertEqual(state.error, "服务暂时不可用")
        XCTAssertFalse(state.hasSnapshot)
        XCTAssertFalse(state.isConfirmedEmpty)
        XCTAssertFalse(state.loading)
    }

    func testOnlyCompleteSuccessCanConfirmEmptyShelf() {
        var state = AccountShelfState()
        let partial = UUID()
        state.begin(partial)
        state.complete(BookshelfSyncResult(books: [], failedSectionCount: 1), for: partial)
        XCTAssertFalse(state.isConfirmedEmpty)
        XCTAssertNotNil(state.notice)
        let retry = UUID()
        state.begin(retry)
        state.complete(BookshelfSyncResult(books: [], failedSectionCount: 0), for: retry)
        XCTAssertTrue(state.isConfirmedEmpty)
        XCTAssertNil(state.notice)
    }

    func testFailureAndCancellationKeepPreviouslyReadBooks() {
        let errors: [Error] = [SFAPIError.server("服务暂时不可用"), CancellationError(), URLError(.cancelled)]
        for error in errors {
            var state = loadedState()
            let request = UUID()
            state.begin(request)
            state.fail(error, for: request)
            XCTAssertEqual(state.books.map(\.id), [1])
            XCTAssertFalse(state.loading)
            XCTAssertFalse(state.isConfirmedEmpty)
            if AccountShelfState.isCancellation(error) { XCTAssertNil(state.error) }
            else { XCTAssertNotNil(state.error) }
        }
    }

    func testPartialSyncPreservesUnavailableSectionsAndCompleteSyncReplacesThem() {
        var state = loadedState()
        let partial = UUID()
        state.begin(partial)
        state.complete(BookshelfSyncResult(books: [book(2)], failedSectionCount: 1), for: partial)
        XCTAssertEqual(state.books.map(\.id), [2, 1])
        XCTAssertFalse(state.isComplete)
        XCTAssertNotNil(state.notice)

        let complete = UUID()
        state.begin(complete)
        state.complete(BookshelfSyncResult(books: [book(2)], failedSectionCount: 0), for: complete)
        XCTAssertEqual(state.books.map(\.id), [2])
        XCTAssertTrue(state.isComplete)
        XCTAssertNil(state.notice)
    }

    func testRefreshReplacesUnknownAuthorForAnExistingBook() {
        var state = AccountShelfState()
        let first = UUID()
        state.begin(first)
        state.complete(BookshelfSyncResult(books: [Book(id: 1, title: "测试作品", author: "未知作者")], failedSectionCount: 0), for: first)
        let retry = UUID()
        state.begin(retry)
        state.complete(BookshelfSyncResult(books: [Book(id: 1, title: "测试作品", author: "已解析的作者")], failedSectionCount: 1), for: retry)
        XCTAssertEqual(state.books.count, 1)
        XCTAssertEqual(state.books.first?.author, "已解析的作者", "A partial refresh must replace stale metadata for the same book")
    }

    func testOlderResponsesCannotReplaceNewerRequest() {
        var state = loadedState()
        let old = UUID(), latest = UUID()
        state.begin(old)
        state.begin(latest)
        state.complete(BookshelfSyncResult(books: [book(2)], failedSectionCount: 0), for: old)
        state.fail(URLError(.timedOut), for: old)
        XCTAssertEqual(state.books.map(\.id), [1])
        XCTAssertTrue(state.loading)
        XCTAssertNil(state.error)
        state.complete(BookshelfSyncResult(books: [book(3)], failedSectionCount: 0), for: latest)
        state.complete(BookshelfSyncResult(books: [book(2)], failedSectionCount: 0), for: old)
        XCTAssertEqual(state.books.map(\.id), [3])
    }

    func testAccountResetRejectsInFlightResponse() {
        var state = loadedState()
        let request = UUID()
        state.begin(request)
        state.reset()
        state.complete(BookshelfSyncResult(books: [book(2)], failedSectionCount: 0), for: request)
        XCTAssertTrue(state.books.isEmpty)
        XCTAssertFalse(state.hasSnapshot)
        XCTAssertFalse(state.isConfirmedEmpty)
    }

    private func loadedState() -> AccountShelfState {
        var state = AccountShelfState()
        let request = UUID()
        state.begin(request)
        state.complete(BookshelfSyncResult(books: [book(1)], failedSectionCount: 0), for: request)
        return state
    }

    private func book(_ id: Int) -> Book { Book(id: id, title: "测试作品 \(id)", author: "测试") }
}
