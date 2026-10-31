import XCTest
@testable import FlowReader

@MainActor
final class LibraryProgressPersistenceTests: XCTestCase {
    func testPageChangesWriteOnlySmallCheckpointAndRestoreWithoutRewritingCatalogOrJobs() throws {
        let fixture = ProgressFixture()
        defer { fixture.cleanUp() }
        let library = LibraryStore(directory: fixture.root)
        library.save(book: fixture.book, chapters: fixture.chapters)
        let indexBefore = try Data(contentsOf: fixture.root.appendingPathComponent("library.json"))
        let jobsBefore = try Data(contentsOf: fixture.root.appendingPathComponent("downloads.json"))
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 11, paragraph: 2, paragraphUTF16Offset: 7)
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 12, paragraph: 9, paragraphUTF16Offset: 20)

        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("library.json")), indexBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("downloads.json")), jobsBefore)
        XCTAssertLessThan(try Data(contentsOf: fixture.checkpoint).count, 1024)
        let restored = LibraryStore(directory: fixture.root).localBook(id: fixture.book.id)?.progress
        XCTAssertEqual(restored?.chapterID, 12)
        XCTAssertEqual(restored?.paragraph, 9)
        XCTAssertEqual(restored?.paragraphUTF16Offset, 20)
        XCTAssertNil(library.errorMessage)
    }

    func testRepeatedInactiveAndBackgroundCheckpointDoesNotRewriteOrAdvanceTimestamp() throws {
        let fixture = ProgressFixture()
        defer { fixture.cleanUp() }
        let library = LibraryStore(directory: fixture.root)
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 11, paragraph: 2, paragraphUTF16Offset: 7)
        let first = library.localBook(id: fixture.book.id)?.progress
        let bytes = try Data(contentsOf: fixture.checkpoint)
        let inode = try FileManager.default.attributesOfItem(atPath: fixture.checkpoint.path)[.systemFileNumber] as? NSNumber
        for _ in 0..<3 {
            library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 11, paragraph: 2, paragraphUTF16Offset: 7)
        }
        XCTAssertEqual(library.localBook(id: fixture.book.id)?.progress, first)
        XCTAssertEqual(try Data(contentsOf: fixture.checkpoint), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.checkpoint.path)[.systemFileNumber] as? NSNumber, inode,
                       "An unchanged position must not atomically replace the checkpoint file")
    }

    func testLegacyIndexProgressLoadsAndNewCheckpointTakesPrecedence() throws {
        let fixture = ProgressFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let legacy = ReadingProgress(chapterID: 11, paragraph: 3, updatedAt: Date(timeIntervalSince1970: 100))
        let book = LocalBook(book: fixture.book, chapters: fixture.chapters, progress: legacy)
        try JSONEncoder().encode([book]).write(to: fixture.root.appendingPathComponent("library.json"))
        let library = LibraryStore(directory: fixture.root)
        XCTAssertEqual(library.localBook(id: fixture.book.id)?.progress, legacy)
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 12, paragraph: 4)
        let reopened = LibraryStore(directory: fixture.root)
        XCTAssertEqual(reopened.localBook(id: fixture.book.id)?.progress?.chapterID, 12)
        XCTAssertEqual(reopened.localBook(id: fixture.book.id)?.progress?.paragraph, 4)
        XCTAssertNil(reopened.errorMessage)
    }

    func testCorruptCheckpointPreservesLegacyPositionAndRestOfLibrary() throws {
        let fixture = ProgressFixture()
        defer { fixture.cleanUp() }
        let library = LibraryStore(directory: fixture.root)
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 11, paragraph: 3)
        library.save(book: fixture.book, chapters: fixture.chapters)
        let original = library.localBook(id: fixture.book.id)?.progress
        try Data("broken checkpoint".utf8).write(to: fixture.checkpoint)
        let reopened = LibraryStore(directory: fixture.root)
        XCTAssertEqual(reopened.books.count, 1)
        XCTAssertEqual(reopened.localBook(id: fixture.book.id)?.progress, original)
        XCTAssertNotNil(reopened.errorMessage)
    }

    func testFailedCheckpointCanRetrySamePositionAfterStorageRecovers() throws {
        let fixture = ProgressFixture()
        defer { fixture.cleanUp() }
        let library = LibraryStore(directory: fixture.root)
        library.save(book: fixture.book, chapters: fixture.chapters)
        let folder = fixture.checkpoint.deletingLastPathComponent()
        try Data("blocking file".utf8).write(to: folder)
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 11, paragraph: 8)
        XCTAssertNotNil(library.errorMessage)
        try FileManager.default.removeItem(at: folder)
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 11, paragraph: 8)
        XCTAssertEqual(LibraryStore(directory: fixture.root).localBook(id: fixture.book.id)?.progress?.paragraph, 8)
    }

    func testRemovingBookClearsCheckpointAndNewChapterCatalogPersistsOnce() throws {
        let fixture = ProgressFixture()
        defer { fixture.cleanUp() }
        let library = LibraryStore(directory: fixture.root)
        library.save(book: fixture.book, chapters: [fixture.chapters[0]])
        library.recordProgress(book: fixture.book, chapters: fixture.chapters, chapterID: 12, paragraph: 2)
        let reopened = LibraryStore(directory: fixture.root)
        XCTAssertEqual(reopened.localBook(id: fixture.book.id)?.chapters.count, 2)
        XCTAssertEqual(reopened.localBook(id: fixture.book.id)?.progress?.chapterID, 12)
        reopened.remove(bookID: fixture.book.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.checkpoint.path))
        reopened.save(book: fixture.book, chapters: fixture.chapters)
        XCTAssertNil(LibraryStore(directory: fixture.root).localBook(id: fixture.book.id)?.progress)
    }
}

private struct ProgressFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FlowProgressTests-\(UUID().uuidString)", isDirectory: true)
    let book = Book(id: 1, title: "进度持久化原创测试", author: "测试作者")
    let chapters = [
        Chapter(id: 11, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "第一章", order: 0),
        Chapter(id: 12, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "第二章", order: 1)
    ]
    var checkpoint: URL { root.appendingPathComponent("1/reading-progress.json") }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
