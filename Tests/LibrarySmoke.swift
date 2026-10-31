import Foundation

actor SFAPI {
    static let shared = SFAPI()
    func content(chapter: Chapter) async throws -> ChapterContent {
        try await Task.sleep(for: .seconds(0.2))
        try Task.checkCancellation()
        return ChapterContent(chapter: chapter, text: "网络测试章节正文")
    }
}

@main struct LibrarySmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FlowSmoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        library.seedDemoIfNeeded()
        let sample = library.localBook(id: -100)!
        precondition(sample.chapters.count == 3 && sample.downloadedIDs.count == 3)
        library.recordProgress(book: sample.book, chapters: sample.chapters, chapterID: sample.chapters[1].id, paragraph: 3)
        let restored = LibraryStore(directory: root)
        precondition(restored.localBook(id: -100)?.progress?.paragraph == 3)
        precondition(restored.cachedContent(chapter: sample.chapters[0])?.text.contains("海风") == true)
        library.save(book: sample.book, chapters: [sample.chapters[0]])
        precondition(library.localBook(id: -100)?.chapters.count == 3, "Downloading one chapter must preserve the full catalog")
        let input = root.appendingPathComponent("测试导入.txt")
        try "书前说明\n第一章 初见\n你好，世界。\n第二章 重逢\n再次相遇。".write(to: input, atomically: true, encoding: .utf8)
        let imported = try library.importText(url: input)
        precondition(library.localBook(id: imported.id)?.chapters.count == 3)
        for format in ExportFormat.allCases {
            let file = try BookExporter.export(book: sample.book, chapters: library.downloadedContent(bookID: sample.id), format: format)
            let exportedData = try Data(contentsOf: file)
            precondition(exportedData.count > 200)
            if format == .epub { print("EPUB=\(file.path)") }
        }
        let online = Book(id: 20, title: "下载状态测试", author: "测试")
        let chapters = (0..<3).map { Chapter(id: 100 + $0, bookID: 20, volumeID: 1, volumeTitle: "测试", title: "第\($0)章", order: $0) }
        library.download(book: online, chapters: chapters)
        library.pause(jobID: 20)
        try await Task.sleep(for: .seconds(0.3))
        precondition(library.jobs.first(where: { $0.id == 20 })?.status == .paused)
        precondition(library.localBook(id: 20)?.downloadedIDs.isEmpty == true)
        library.resume(jobID: 20)
        try await Task.sleep(for: .seconds(0.3))
        precondition(library.localBook(id: 20)?.downloadedIDs.count == 1)
        library.cancel(jobID: 20)
        try await Task.sleep(for: .seconds(0.3))
        precondition(library.jobs.first(where: { $0.id == 20 }) == nil)
        precondition(library.localBook(id: 20)?.downloadedIDs.count == 1)
        library.download(book: online, chapters: chapters)
        try await Task.sleep(for: .seconds(0.25))
        let reopened = LibraryStore(directory: root)
        precondition(reopened.jobs.first(where: { $0.id == 20 })?.status == .paused, "Unfinished downloads must reopen paused")
        library.remove(bookID: 20)
        try await Task.sleep(for: .seconds(0.3))
        precondition(library.localBook(id: 20) == nil && !FileManager.default.fileExists(atPath: root.appendingPathComponent("20").path), "Cancelled jobs must not recreate a deleted book")
        precondition(library.errorMessage == nil)
        print("PASS: persistence, progress, chapter merge, TXT import, TXT/Markdown/EPUB export, pause/resume/cancel/restart, delete during download")
    }
}
