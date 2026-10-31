import XCTest
@testable import FlowReader

@MainActor
final class LibraryTests: XCTestCase {
    func testLegacyReadingProgressDecodesWithoutParagraphOffset() throws {
        let data = Data(#"{"chapterID":104,"paragraph":7,"updatedAt":12345}"#.utf8)
        let progress = try JSONDecoder().decode(ReadingProgress.self, from: data)
        XCTAssertEqual(progress.chapterID, 104)
        XCTAssertEqual(progress.paragraph, 7)
        XCTAssertEqual(progress.updatedAt, Date(timeIntervalSinceReferenceDate: 12345))
        XCTAssertNil(progress.paragraphUTF16Offset)
    }

    func testParagraphUTF16PositionPersistsAndLegacyUpdatesRemainParagraphOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let book = Book(id: -20, title: "段内位置测试", author: "原创测试")
        let chapter = Chapter(id: -101, bookID: -20, volumeID: 1, volumeTitle: "正文", title: "第一章", order: 0)
        library.recordProgress(book: book, chapters: [chapter], chapterID: chapter.id, paragraph: 7, paragraphUTF16Offset: 127)
        let original = try XCTUnwrap(library.localBook(id: book.id)?.progress)

        let reopened = LibraryStore(directory: root)
        let restored = try XCTUnwrap(reopened.localBook(id: book.id)?.progress)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.chapterID, chapter.id)
        XCTAssertEqual(restored.paragraph, 7)
        XCTAssertEqual(restored.paragraphUTF16Offset, 127)

        reopened.recordProgress(book: book, chapters: [chapter], chapterID: chapter.id, paragraph: 8)
        let legacyUpdate = LibraryStore(directory: root).localBook(id: book.id)?.progress
        XCTAssertEqual(legacyUpdate?.paragraph, 8)
        XCTAssertNil(legacyUpdate?.paragraphUTF16Offset, "A paragraph-only update must not keep a stale offset from another position")
        XCTAssertNil(reopened.errorMessage)
    }

    func testOldContentRemainsDecodableAndCurrentVIPCacheReadsOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let book = Book(id: 20, title: "缓存版本测试", author: "原创测试")
        let chapter = Chapter(id: 101, bookID: 20, volumeID: 1, volumeTitle: "正文", title: "第一章", order: 0, isVIP: true)
        let old = ChapterContent(chapter: chapter, text: "旧格式")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "sourceFormatVersion")
        let decoded = try JSONDecoder().decode(ChapterContent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sourceFormatVersion)
        library.save(book: book, chapters: [chapter])
        try library.store(content: ChapterContent(chapter: chapter, text: "已经校正的原创测试文字", sourceFormatVersion: 2), book: book)
        let content = try await library.content(chapter: chapter)
        XCTAssertEqual(content.sourceFormatVersion, 2)
        XCTAssertEqual(content.text, "已经校正的原创测试文字")
    }

    func testFailedVIPRefreshPreservesOriginalUntilSuccessfulReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(id: 20, title: "缓存恢复测试", author: "原创测试")
        let chapter = Chapter(id: 101, bookID: 20, volumeID: 1, volumeTitle: "正文", title: "第一章", order: 0, isVIP: true)
        let offline = LibraryStore(directory: root, fetchContent: { _ in throw URLError(.notConnectedToInternet) })
        offline.save(book: book, chapters: [chapter])
        try offline.store(content: ChapterContent(chapter: chapter, text: "需要更新的原创测试文字"), book: book)
        do {
            _ = try await offline.content(chapter: chapter)
            XCTFail("Old OCR must not silently return as corrected text")
        } catch LibraryError.outdatedVIPCache { }
        XCTAssertNil(offline.cachedContent(chapter: chapter), "An obsolete OCR cache must not bypass validation through the offline accessor")
        let preserved = try JSONDecoder().decode(ChapterContent.self, from: Data(contentsOf: root.appendingPathComponent("20/101.json")))
        XCTAssertEqual(preserved.text, "需要更新的原创测试文字")
        let online = LibraryStore(directory: root, fetchContent: { chapter in
            ChapterContent(chapter: chapter, text: "已更新的原创测试文字", sourceFormatVersion: 2)
        })
        _ = try await online.content(chapter: chapter)
        let reopened = LibraryStore(directory: root)
        XCTAssertEqual(reopened.cachedContent(chapter: chapter)?.sourceFormatVersion, 2)
        XCTAssertEqual(reopened.cachedContent(chapter: chapter)?.text, "已更新的原创测试文字")
    }

    func testAppV3CacheMigratesFreeAndVIPExactlyOnceOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root, fetchContent: { _ in
            XCTFail("Repairing saved transport text must not require authentication or download")
            throw URLError(.notConnectedToInternet)
        })
        let book = Book(id: 20, title: "缓存转换原创测试", author: "原创测试")
        let chapters = [false, true].enumerated().map { Chapter(id: 101 + $0.offset, bookID: 20, volumeID: 1, volumeTitle: "正文", title: "测试章节", order: $0.offset, isVIP: $0.element) }
        library.save(book: book, chapters: chapters)
        for chapter in chapters {
            try library.store(content: ChapterContent(chapter: chapter, text: "宦。\n宦🌊", sourceFormatVersion: 3), book: book)
            let repaired = try await library.content(chapter: chapter)
            XCTAssertEqual(repaired.text, "啊。\n啊🌊")
            XCTAssertEqual(repaired.sourceFormatVersion, 4)
            let reopened = LibraryStore(directory: root)
            let readAgain = try await reopened.content(chapter: chapter)
            XCTAssertEqual(readAgain.text, repaired.text, "The character permutation is not idempotent and must never run twice")
            XCTAssertEqual(readAgain.sourceFormatVersion, 4)
        }
    }

    func testCacheRepairDoesNotTransformOCRLocalOrAlreadyDecodedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root, fetchContent: { _ in throw URLError(.notConnectedToInternet) })
        let cases: [(Int, Int?, Bool)] = [(20, 2, true), (21, 4, true), (22, nil, false), (-23, 3, true)]
        for (bookID, version, isVIP) in cases {
            let book = Book(id: bookID, title: "来源保护测试", author: "原创测试")
            let chapter = Chapter(id: bookID * 10, bookID: bookID, volumeID: 1, volumeTitle: "正文", title: "章节", order: 0, isVIP: isVIP)
            library.save(book: book, chapters: [chapter])
            try library.store(content: ChapterContent(chapter: chapter, text: "宦。啊。🌊", sourceFormatVersion: version), book: book)
            let content = try await library.content(chapter: chapter)
            XCTAssertEqual(content.text, "宦。啊。🌊")
            XCTAssertEqual(content.sourceFormatVersion, version)
        }
    }

    func testPreviouslyCompletedDownloadRevalidatesAndRepairsCachedChapters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(id: 20, title: "下载恢复测试", author: "原创测试")
        let chapter = Chapter(id: 101, bookID: 20, volumeID: 1, volumeTitle: "正文", title: "章节", order: 0)
        let original = LibraryStore(directory: root)
        original.save(book: book, chapters: [chapter])
        try original.store(content: ChapterContent(chapter: chapter, text: "宦🌊", sourceFormatVersion: 3), book: book)
        let completed = DownloadJob(book: book, chapters: [chapter], completedIDs: [chapter.id], status: .complete)
        try JSONEncoder().encode([completed]).write(to: root.appendingPathComponent("downloads.json"))
        let reopened = LibraryStore(directory: root, fetchContent: { _ in
            XCTFail("An already downloaded v3 chapter repairs locally")
            throw URLError(.notConnectedToInternet)
        })
        reopened.download(book: book, chapters: [chapter])
        for _ in 0..<100 where reopened.jobs.first?.status != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reopened.jobs.first?.status, .complete)
        XCTAssertEqual(reopened.jobs.first?.completedIDs, [chapter.id])
        let stored = try JSONDecoder().decode(ChapterContent.self, from: Data(contentsOf: root.appendingPathComponent("20/101.json")))
        XCTAssertEqual(stored.sourceFormatVersion, 4)
        XCTAssertEqual(stored.text, "啊🌊")
    }

    func testEveryExportRepairsV3AndDoesNotSilentlyOmitMissingDownloadedChapters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let book = Book(id: 20, title: "导出来源测试", author: "原创测试")
        let chapter = Chapter(id: 101, bookID: 20, volumeID: 1, volumeTitle: "正文", title: "章节", order: 0, isVIP: true)
        library.save(book: book, chapters: [chapter])
        for format in ExportFormat.allCases {
            try library.store(content: ChapterContent(chapter: chapter, text: "宦🌊", sourceFormatVersion: 3), book: book)
            let url = try BookExporter.export(book: book, chapters: library.downloadedContent(bookID: book.id), format: format)
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try Data(contentsOf: url)
            XCTAssertNotNil(data.range(of: Data("啊🌊".utf8)))
            XCTAssertNil(data.range(of: Data("宦🌊".utf8)))
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("20/101.json"))
        XCTAssertThrowsError(try library.downloadedContent(bookID: book.id)) { error in
            guard case LibraryError.unavailableDownloadedChapter = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRepairWriteFailurePreservesV3FileUntilRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("20")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        let library = LibraryStore(directory: root)
        let book = Book(id: 20, title: "原子修复测试", author: "原创测试")
        let chapter = Chapter(id: 101, bookID: 20, volumeID: 1, volumeTitle: "正文", title: "章节", order: 0)
        library.save(book: book, chapters: [chapter])
        try library.store(content: ChapterContent(chapter: chapter, text: "宦🌊", sourceFormatVersion: 3), book: book)
        let url = folder.appendingPathComponent("101.json")
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        do {
            _ = try await library.content(chapter: chapter)
            XCTFail("A failed atomic migration must not publish corrected text as a saved v4 cache")
        } catch LibraryError.cacheRepairFailed { }
        XCTAssertEqual(try Data(contentsOf: url), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let repaired = try await library.content(chapter: chapter)
        XCTAssertEqual(repaired.text, "啊🌊")
        XCTAssertEqual(repaired.sourceFormatVersion, 4)
    }

    func testCachedIdentityAndVIPProvenanceCannotBeBypassedByCatalogMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root, fetchContent: { _ in throw URLError(.notConnectedToInternet) })
        let book = Book(id: 20, title: "目录一致性测试", author: "原创测试")
        let chapter = Chapter(id: 101, bookID: 20, volumeID: 1, volumeTitle: "正文", title: "章节", order: 0)
        var oldVIP = chapter; oldVIP.isVIP = true
        library.save(book: book, chapters: [chapter])
        try library.store(content: ChapterContent(chapter: oldVIP, text: "旧版图片识别文字"), book: book)
        do { _ = try await library.content(chapter: chapter); XCTFail("Cached VIP provenance must survive a stale free catalog flag") }
        catch LibraryError.outdatedVIPCache { }
        XCTAssertThrowsError(try library.downloadedContent(bookID: book.id))
        var anotherChapter = chapter; anotherChapter.id = 999
        let unrelated = try JSONEncoder().encode(ChapterContent(chapter: anotherChapter, text: "宦🌊", sourceFormatVersion: 3))
        let url = root.appendingPathComponent("20/101.json")
        try unrelated.write(to: url)
        do { _ = try await library.content(chapter: chapter); XCTFail("A file with another chapter's identity must not render") }
        catch LibraryError.invalidCachedContent { }
        XCTAssertThrowsError(try library.downloadedContent(bookID: book.id))
        XCTAssertEqual(try Data(contentsOf: url), unrelated)
    }

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
