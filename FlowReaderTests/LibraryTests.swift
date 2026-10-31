import XCTest
@testable import FlowReader

@MainActor
final class LibraryTests: XCTestCase {
    func testPersistenceImportAndExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        library.seedDemoIfNeeded()
        let sample = try XCTUnwrap(library.localBook(id: -100))
        XCTAssertEqual(sample.chapters.count, 3)
        XCTAssertEqual(sample.downloadedIDs.count, 3)
        library.recordProgress(book: sample.book, chapters: sample.chapters, chapterID: sample.chapters[1].id, paragraph: 3)
        let restored = LibraryStore(directory: root)
        XCTAssertEqual(restored.localBook(id: -100)?.progress?.paragraph, 3)
        XCTAssertTrue(restored.cachedContent(chapter: sample.chapters[0])?.text.contains("海风") == true)
        library.save(book: sample.book, chapters: [sample.chapters[0]])
        XCTAssertEqual(library.localBook(id: -100)?.chapters.count, 3, "A single chapter download preserves the catalog")
        let input = root.appendingPathComponent("测试导入.txt")
        try "书前说明\n第一章 初见\n你好，世界。\n第二章 重逢\n再次相遇。".write(to: input, atomically: true, encoding: .utf8)
        let imported = try library.importText(url: input)
        XCTAssertEqual(library.localBook(id: imported.id)?.chapters.count, 3)
        for format in ExportFormat.allCases {
            let url = try BookExporter.export(book: sample.book, chapters: library.downloadedContent(bookID: sample.id), format: format)
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(data.count, 200)
            if format == .epub {
                XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
                XCTAssertNotNil(String(data: data, encoding: .isoLatin1)?.range(of: "mimetype"))
            }
        }
        XCTAssertNil(library.errorMessage)
    }

    func testPauseResumeCancelAndDeleteCannotResurrectBook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let book = Book(id: 20, title: "状态测试", author: "测试")
        let chapters = (0..<3).map { Chapter(id: 100 + $0, bookID: 20, volumeID: 1, volumeTitle: "测试", title: "第\($0)章", order: $0) }
        library.save(book: book, chapters: chapters)
        let folder = root.appendingPathComponent("20")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for chapter in chapters {
            // Cached responses keep this test deterministic and entirely offline.
            try JSONEncoder().encode(ChapterContent(chapter: chapter, text: "离线测试正文")).write(to: folder.appendingPathComponent("\(chapter.id).json"))
        }
        library.download(book: book, chapters: chapters)
        library.pause(jobID: 20)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(library.jobs.first?.status, .paused)
        XCTAssertEqual(library.localBook(id: 20)?.downloadedIDs.count, 0)
        library.resume(jobID: 20)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(library.localBook(id: 20)?.downloadedIDs.count, 1)
        let reopened = LibraryStore(directory: root)
        XCTAssertEqual(reopened.jobs.first?.status, .paused)
        library.cancel(jobID: 20)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(library.jobs.isEmpty)
        XCTAssertEqual(library.localBook(id: 20)?.downloadedIDs.count, 1)
        library.download(book: book, chapters: chapters)
        library.remove(bookID: 20)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(library.localBook(id: 20))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(library.errorMessage)
    }
}
