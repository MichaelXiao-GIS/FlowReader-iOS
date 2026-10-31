import XCTest
@testable import FlowReader

final class DiscoverLoadStateTests: XCTestCase {
    func testRefreshCancellationKeepsExistingBooksWithoutError() throws {
        let cancellations: [Error] = [CancellationError(), URLError(.cancelled), NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)]
        for cancellation in cancellations {
            var state = loadedState()
            let request = try XCTUnwrap(state.begin(query: "", reset: true))
            state.fail(cancellation, for: request)
            XCTAssertEqual(state.books.map(\.id), [1])
            XCTAssertNil(state.error)
            XCTAssertFalse(state.loading)
        }
    }

    func testRealRefreshFailureKeepsContentAndShowsError() throws {
        var state = loadedState()
        let request = try XCTUnwrap(state.begin(query: "", reset: true))
        state.fail(SFAPIError.server("服务暂时不可用"), for: request)
        XCTAssertEqual(state.books.map(\.id), [1])
        XCTAssertEqual(state.error, "服务暂时不可用")
        XCTAssertFalse(state.loading)
    }

    func testSupersededSearchCannotOverwriteResultsOrFinishCurrentLoading() throws {
        var state = loadedState()
        let old = try XCTUnwrap(state.begin(query: "旧搜索", reset: true))
        let current = try XCTUnwrap(state.begin(query: "新搜索", reset: true))
        state.complete([Book(id: 2, title: "旧结果", author: "测试")], for: old)
        state.fail(URLError(.timedOut), for: old)
        XCTAssertTrue(state.loading)
        XCTAssertTrue(state.books.isEmpty)
        XCTAssertNil(state.error)
        state.complete([Book(id: 3, title: "新结果", author: "测试")], for: current)
        state.complete([Book(id: 2, title: "迟到结果", author: "测试")], for: old)
        XCTAssertEqual(state.books.map(\.id), [3])
        XCTAssertEqual(state.query, "新搜索")
    }

    func testPaginationFailurePreservesPageAndRetryCanContinue() throws {
        var state = DiscoverLoadState()
        let first = try XCTUnwrap(state.begin(query: "小说", reset: true))
        state.complete([Book(id: 1, title: "第一本", author: "测试")], for: first)
        let failedPage = try XCTUnwrap(state.begin(query: "小说", reset: false))
        state.fail(URLError(.notConnectedToInternet), for: failedPage)
        XCTAssertEqual(state.page, 0)
        XCTAssertEqual(state.books.count, 1)
        XCTAssertNotNil(state.error)
        let retry = try XCTUnwrap(state.begin(query: "小说", reset: false))
        XCTAssertEqual(retry.page, 1)
        state.complete([Book(id: 1, title: "重复", author: "测试"), Book(id: 2, title: "第二本", author: "测试")], for: retry)
        XCTAssertEqual(state.books.map(\.id), [1, 2])
        XCTAssertEqual(state.page, 1)
        XCTAssertNil(state.error)
    }

    func testCancelledTaskDoesNotPublishErrorAndCanRefreshAgain() throws {
        var state = loadedState()
        let cancelled = try XCTUnwrap(state.begin(query: "", reset: true))
        state.fail(URLError(.networkConnectionLost), for: cancelled, taskIsCancelled: true)
        XCTAssertNil(state.error)
        let retry = try XCTUnwrap(state.begin(query: "", reset: true))
        state.complete([Book(id: 4, title: "刷新结果", author: "测试")], for: retry)
        XCTAssertEqual(state.books.map(\.id), [4])
        XCTAssertFalse(state.loading)
    }

    private func loadedState() -> DiscoverLoadState {
        var state = DiscoverLoadState()
        let request = state.begin(query: "", reset: true)!
        state.complete([Book(id: 1, title: "已显示的作品", author: "测试")], for: request)
        return state
    }
}
