import XCTest
@testable import FlowReader

@MainActor
final class ReaderBookmarkTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func chapter(id: Int = 11, bookID: Int = 22) -> Chapter {
        Chapter(id: id, bookID: bookID, volumeID: 1, volumeTitle: "原创测试", title: "一枚真实书签", order: 0)
    }

    func testBookmarkPersistsExactChapterAndParagraphOffsetAcrossRestart() throws {
        let directory = try temporaryDirectory()
        let store = ReaderBookmarkStore(directory: directory)
        let position = ReaderTextPosition(paragraph: 14, utf16Offset: 36)
        try store.toggle(bookID: 22, chapter: chapter(), position: position, excerpt: "原创文字，用来确认书签保存。")
        let restored = ReaderBookmarkStore(directory: directory)
        let bookmark = try XCTUnwrap(restored.bookmark(bookID: 22, chapterID: 11, position: position))
        XCTAssertEqual(bookmark.position, position)
        XCTAssertEqual(bookmark.chapterTitle, "一枚真实书签")
        XCTAssertEqual(bookmark.excerpt, "原创文字，用来确认书签保存。")
        XCTAssertNil(restored.loadError)
    }

    func testToggleOnlyRemovesTheExactPositionAndKeepsOtherChapters() throws {
        let store = ReaderBookmarkStore(directory: try temporaryDirectory())
        let first = ReaderTextPosition(paragraph: 1, utf16Offset: 0)
        let second = ReaderTextPosition(paragraph: 2, utf16Offset: 0)
        try store.toggle(bookID: 22, chapter: chapter(), position: first, excerpt: "第一处")
        try store.toggle(bookID: 22, chapter: chapter(), position: second, excerpt: "第二处")
        try store.toggle(bookID: 22, chapter: chapter(id: 12), position: first, excerpt: "另一章")
        try store.toggle(bookID: 22, chapter: chapter(), position: first, excerpt: "第一处")
        XCTAssertEqual(store.bookmarks(bookID: 22).count, 2)
        XCTAssertNil(store.bookmark(bookID: 22, chapterID: 11, position: first))
        XCTAssertNotNil(store.bookmark(bookID: 22, chapterID: 11, position: second))
        XCTAssertNotNil(store.bookmark(bookID: 22, chapterID: 12, position: first))
        XCTAssertTrue(store.bookmarks(bookID: 99).isEmpty)
    }

    func testFailedDiskWriteNeverAppearsAsASavedBookmark() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: file)
        let store = ReaderBookmarkStore(directory: file)
        XCTAssertThrowsError(try store.toggle(bookID: 22, chapter: chapter(), position: .init(paragraph: 0, utf16Offset: 0), excerpt: "未保存"))
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "preserve")
    }

    func testDamagedFileIsPreservedAndForeignBookPositionIsRejected() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("bookmarks.json")
        let original = Data("not valid json".utf8)
        try original.write(to: file)
        let damaged = ReaderBookmarkStore(directory: root)
        XCTAssertNotNil(damaged.loadError)
        XCTAssertThrowsError(try damaged.toggle(bookID: 22, chapter: chapter(), position: .init(paragraph: 0, utf16Offset: 0), excerpt: "不应覆盖"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let fresh = ReaderBookmarkStore(directory: try temporaryDirectory())
        XCTAssertThrowsError(try fresh.toggle(bookID: 999, chapter: chapter(), position: .init(paragraph: 0, utf16Offset: 0), excerpt: "错误归属"))
        XCTAssertTrue(fresh.bookmarks.isEmpty)
    }
}
