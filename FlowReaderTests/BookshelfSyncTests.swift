import XCTest
@testable import FlowReader

final class BookshelfSyncTests: XCTestCase {
    private static let catalog = "<a href='/p/10/'>有声收藏</a><a href='/p/20/'>小说收藏</a>"
    private static let bookPage = "<ul class='pocket-item'><li><a href='https://book.sfacg.com/Novel/42/'><img src='//rss.sfacg.com/cover.jpg'></a></li><li><b><a href='https://book.sfacg.com/Novel/42/'>测试小说</a></b>作者：测试作者</li></ul>"

    func testOneUnavailableSectionDoesNotBlockReadableBooksAndReportsPartialSync() async throws {
        let result = try await WebBookshelfLoader.load(accountName: "reader_1") { url, referer in
            switch url.path {
            case "/u/content/reader_1-0-1":
                XCTAssertEqual(referer.absoluteString, "https://p.sfacg.com/u/reader_1/")
                return Self.catalog
            case "/p/10": throw SFAPIError.httpStatus(500)
            case "/p/20":
                XCTAssertEqual(referer.path, "/u/reader_1")
                return Self.bookPage
            default: XCTFail("Unexpected URL: \(url.path)"); throw SFAPIError.invalidResponse
            }
        }
        XCTAssertEqual(result.books.map(\.id), [42])
        XCTAssertEqual(result.books.first?.title, "测试小说")
        XCTAssertEqual(result.books.first?.author, "测试作者")
        XCTAssertEqual(result.books.first?.shelfName, "小说收藏")
        XCTAssertEqual(result.failedSectionCount, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.notice)
    }

    func testAllFailedSectionsThrowInsteadOfLookingLikeAnEmptyShelf() async {
        do {
            _ = try await WebBookshelfLoader.load(accountName: "reader_1") { url, _ in
                if url.path.hasPrefix("/u/content/") { return Self.catalog }
                throw SFAPIError.httpStatus(500)
            }
            XCTFail("All failed categories must not be reported as an empty shelf")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("2 个分类均未能读取"))
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    func testLaterPageFailurePreservesLoadedPagesAndContinuesOtherSections() async throws {
        let result = try await WebBookshelfLoader.load(accountName: "reader_1") { url, referer in
            switch url.path {
            case "/u/content/reader_1-0-1": return Self.catalog
            case "/p/10": return Self.bookPage + "<a href='/p/10/2/'>下一页</a>"
            case "/p/10/2":
                XCTAssertEqual(referer.path, "/p/10")
                throw SFAPIError.httpStatus(500)
            case "/p/20": return Self.bookPage.replacingOccurrences(of: "/42/", with: "/43/")
            default: throw SFAPIError.invalidResponse
            }
        }
        XCTAssertEqual(result.books.map(\.id), [42, 43])
        XCTAssertEqual(result.failedSectionCount, 1)
    }

    func testAuthorizationFailureIsNeverConvertedIntoPartialSuccess() async {
        for status in [401, 403] {
            do {
                _ = try await WebBookshelfLoader.load(accountName: "reader_1") { url, _ in
                    if url.path.hasPrefix("/u/content/") { return Self.catalog }
                    if url.path == "/p/10" { throw SFAPIError.httpStatus(status) }
                    return Self.bookPage
                }
                XCTFail("HTTP \(status) must propagate")
            } catch {
                guard case SFAPIError.httpStatus(let received) = error else { XCTFail("Wrong failure: \(error)"); continue }
                XCTAssertEqual(received, status)
            }
        }
        do {
            _ = try await WebBookshelfLoader.load(accountName: "reader_1") { _, _ in throw SFAPIError.loginRequired }
            XCTFail("Expired login must propagate")
        } catch {
            guard case SFAPIError.loginRequired = error else { return XCTFail("Wrong failure: \(error)") }
        }
    }

    func testSwiftAndURLSessionCancellationStopSync() async {
        for usesURLCancellation in [false, true] {
            do {
                _ = try await WebBookshelfLoader.load(accountName: "reader_1") { url, _ in
                    if url.path.hasPrefix("/u/content/") { return Self.catalog }
                    if usesURLCancellation { throw URLError(.cancelled) }
                    throw CancellationError()
                }
                XCTFail("Cancellation must propagate")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
            }
        }
    }

    func testSuccessfulNonNovelSectionIsNotAServiceFailure() async throws {
        let result = try await WebBookshelfLoader.load(accountName: "reader_1") { url, _ in
            if url.path.hasPrefix("/u/content/") { return "<a href='/p/10/'>有声收藏</a>" }
            return "<ul data-media-type='audio'><li><a href='https://m.sfacg.com/audio/1/'>有声专辑</a></li></ul>"
        }
        XCTAssertTrue(result.books.isEmpty)
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.notice)
    }

    func testCategoryIndexFailureIsDistinctFromAnEmptyShelf() async {
        do {
            _ = try await WebBookshelfLoader.load(accountName: "reader_1") { _, _ in throw SFAPIError.httpStatus(500) }
            XCTFail("Missing index must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("分类列表读取失败"))
        }
    }

    func testDuplicateCategoryAndBookLinksAreDeduplicated() async throws {
        let result = try await WebBookshelfLoader.load(accountName: "reader_1") { url, _ in
            if url.path.hasPrefix("/u/content/") { return "<a href='/p/20/'>小说</a><a href='/p/20/'>小说</a>" }
            return Self.bookPage + Self.bookPage
        }
        XCTAssertEqual(result.books.count, 1)
        XCTAssertTrue(result.isComplete)
    }

    func testPublicShelfAuthorLinkExcludesRatingAndDescription() {
        let markup = """
        <ul class="content_comment cover" eid="42">
        <li><a href="https://book.sfacg.com/Novel/42/"><img src="//rss.sfacg.com/cover.jpg"></a></li>
        <li><span><b><a href="https://book.sfacg.com/Novel/42/">测试小说</a></b></span><br />
        作者：<a href="#">测试&amp;作者</a> / 综合信息：<a href="#">9.0分(7人评分)</a><br />简介</li>
        </ul>
        """
        XCTAssertEqual(WebBookshelfLoader.parseBooks(markup, shelfName: "小说").first?.author, "测试&作者")
        let encoded = markup.replacingOccurrences(of: "作者：<a href=\"#\">测试&amp;作者</a>", with: "<span>作者</span>&nbsp;&#65306; 测试作者")
        XCTAssertEqual(WebBookshelfLoader.parseBooks(encoded, shelfName: "小说").first?.author, "测试作者")
        let missing = markup.replacingOccurrences(of: "作者：<a href=\"#\">测试&amp;作者</a> / 综合信息：<a href=\"#\">9.0分(7人评分)</a>", with: "简介暂缺")
        XCTAssertEqual(WebBookshelfLoader.parseBooks(missing, shelfName: "小说").first?.author, "未知作者")
    }

    func testCompactAuthenticatedCardsGetAuthorsFromMatchingPublicBooks() async throws {
        let compact = "<ul><li><b><a href='https://book.sfacg.com/Novel/42/'>账号书名</a></b><p><a>最新章节</a></p></li></ul>"
            + "<ul><li><b><a href='https://book.sfacg.com/Novel/43/'>私有作品</a></b></li></ul>"
        let result = try await WebBookshelfLoader.load(accountName: "reader_1", publicFetch: { url, _ in
            XCTAssertEqual(url.path, "/p/20")
            return "<ul><li><b><a href='https://book.sfacg.com/Novel/42/'>公开书名</a></b><br>作者：<a>正确作者</a></li></ul>"
                + "<ul><li><b><a href='https://book.sfacg.com/Novel/99/'>无关作品</a></b><br>作者：<a>其他作者</a></li></ul>"
        }) { url, _ in
            url.path.hasPrefix("/u/content/") ? "<a href='/p/20/'>收藏</a>" : compact
        }
        XCTAssertEqual(result.books.map(\.id), [42, 43])
        XCTAssertEqual(result.books.first?.title, "账号书名")
        XCTAssertEqual(result.books.first?.author, "正确作者")
        XCTAssertEqual(result.books.last?.author, "未知作者")
        XCTAssertTrue(result.isComplete)
    }

    func testOptionalPublicAuthorLookupFailureKeepsAuthenticatedBooks() async throws {
        let compact = "<ul><li><b><a href='https://book.sfacg.com/Novel/42/'>私有作品</a></b></li></ul>"
        let result = try await WebBookshelfLoader.load(accountName: "reader_1", publicFetch: { _, _ in throw SFAPIError.httpStatus(403) }) { url, _ in
            url.path.hasPrefix("/u/content/") ? "<a href='/p/20/'>收藏</a>" : compact
        }
        XCTAssertEqual(result.books.map(\.id), [42])
        XCTAssertTrue(result.isComplete)
    }
}
