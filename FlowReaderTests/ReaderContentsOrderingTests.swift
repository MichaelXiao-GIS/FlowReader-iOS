import XCTest
@testable import FlowReader

final class ReaderContentsOrderingTests: XCTestCase {
    func testEmptyCatalogHasNoSectionsOrScrollTargets() {
        XCTAssertTrue(ReaderContentsOrdering.sections(chapters: [], descending: false).isEmpty)
        XCTAssertTrue(ReaderContentsOrdering.sections(chapters: [], descending: true).isEmpty)
        XCTAssertNil(ReaderContentsOrdering.boundaryTarget(chapters: [], descending: false))
        XCTAssertNil(ReaderContentsOrdering.initialTarget(chapters: [], currentChapterID: 10))
    }

    func testIdenticalVolumeNamesAndRepeatedVolumeIDsRemainSeparateContiguousSections() {
        let chapters = [chapter(90, volume: 1, order: 5), chapter(2, volume: 1, order: 0),
                        chapter(77, volume: 2, order: 7), chapter(3, volume: 1, order: 1)]
        let sections = ReaderContentsOrdering.sections(chapters: chapters, descending: false)
        XCTAssertEqual(sections.map(\.volumeID), [1, 2, 1])
        XCTAssertEqual(sections.map(\.title), ["同名卷", "同名卷", "同名卷"])
        XCTAssertEqual(sections.map(\.id.sequence), [0, 1, 2])
        XCTAssertEqual(sections.map { $0.chapters.map(\.id) }, [[90, 2], [77], [3]])
        XCTAssertEqual(Set(sections.map(\.id)).count, 3)
        XCTAssertEqual(sections.flatMap(\.chapters), chapters, "The existing catalog array is authoritative, not IDs or a second sort of order fields")
    }

    func testDescendingReversesBothSectionAndChapterOrderWithoutMutatingInput() {
        let chapters = [chapter(90, volume: 1), chapter(2, volume: 1), chapter(77, volume: 2), chapter(3, volume: 2)]
        let original = chapters
        let ascending = ReaderContentsOrdering.sections(chapters: chapters, descending: false)
        let descending = ReaderContentsOrdering.sections(chapters: chapters, descending: true)
        XCTAssertEqual(descending.map(\.id), Array(ascending.map(\.id).reversed()), "A section keeps its identity when its presentation moves")
        XCTAssertEqual(descending.map { $0.chapters.map(\.id) }, [[3, 77], [2, 90]])
        XCTAssertEqual(descending.flatMap(\.chapters), Array(chapters.reversed()))
        XCTAssertEqual(chapters, original, "The reader's next/previous navigation must retain the original array")
    }

    func testInitialTargetIsCurrentWhileExplicitOrderChangeTargetsOriginalBoundary() {
        let chapters = [chapter(90, volume: 1), chapter(2, volume: 1), chapter(77, volume: 2)]
        XCTAssertEqual(ReaderContentsOrdering.initialTarget(chapters: chapters, currentChapterID: 2), 2)
        XCTAssertEqual(ReaderContentsOrdering.initialTarget(chapters: chapters, currentChapterID: 999), 90)
        XCTAssertEqual(ReaderContentsOrdering.boundaryTarget(chapters: chapters, descending: false), 90)
        XCTAssertEqual(ReaderContentsOrdering.boundaryTarget(chapters: chapters, descending: true), 77)
    }

    #if DEBUG
    func testLongFixtureContainsAll1200ChaptersAndCrossVolumeReverseBoundary() {
        let chapters = LongCatalogFixture.chapters
        XCTAssertEqual(chapters.count, 1_200)
        XCTAssertEqual(Set(chapters.map(\.id)).count, 1_200)
        XCTAssertTrue(chapters.allSatisfy { $0.id < 0 && $0.bookID == -100 })
        let descending = ReaderContentsOrdering.sections(chapters: chapters, descending: true)
        XCTAssertEqual(descending.map(\.volumeID), [15, 14, 13, 12, 11, 10])
        XCTAssertEqual(descending.map { $0.chapters.count }, [324, 6, 270, 200, 200, 200])
        XCTAssertEqual(descending.flatMap(\.chapters).map(\.id), Array(chapters.map(\.id).reversed()))
        XCTAssertEqual(descending[0].chapters.last?.id, LongCatalogFixture.chapterID(number: 877))
        XCTAssertEqual(descending[1].chapters.first?.id, LongCatalogFixture.chapterID(number: 876))
        XCTAssertEqual(ReaderContentsOrdering.initialTarget(chapters: chapters, currentChapterID: LongCatalogFixture.chapterID(number: 876)), LongCatalogFixture.chapterID(number: 876))
    }
    #endif

    private func chapter(_ id: Int, volume: Int, order: Int = 0) -> Chapter {
        Chapter(id: id, bookID: -1, volumeID: volume, volumeTitle: "同名卷", title: "原创章节\(id)", order: order)
    }
}

#if DEBUG
@MainActor
final class LongCatalogFixtureTests: XCTestCase {
    func testSparseOfflineFixtureRestoresCurrentChapterAndAllTestRoutesWithoutFetching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fetches = 0
        let fetch: (Chapter) async throws -> ChapterContent = { _ in
            fetches += 1
            throw URLError(.notConnectedToInternet)
        }
        let library = LibraryStore(directory: directory, fetchContent: fetch)
        let book = Book(id: -100, title: "原创长目录测试", author: "Flow 原创示例")
        try LongCatalogFixture.install(in: library, book: book)
        XCTAssertNil(library.errorMessage)
        let reopened = LibraryStore(directory: directory, fetchContent: fetch)
        let saved = try XCTUnwrap(reopened.localBook(id: -100))
        XCTAssertEqual(saved.chapters.count, 1_200)
        XCTAssertEqual(saved.progress?.chapterID, LongCatalogFixture.chapterID(number: 876))
        XCTAssertEqual(saved.downloadedIDs.count, 8, "Only chapters used by the UI tests should be written at launch")
        for number in LongCatalogFixture.cachedChapterNumbers {
            let chapter = LongCatalogFixture.chapters[number - 1]
            let content = try await reopened.content(chapter: chapter)
            XCTAssertEqual(content.text, LongCatalogFixture.text(chapterNumber: number))
        }
        XCTAssertEqual(fetches, 0, "All navigation routes in the fixture must be readable without networking")
        XCTAssertTrue(saved.chapters[875].volumeID != saved.chapters[876].volumeID)
        XCTAssertEqual(saved.chapters[876].id, LongCatalogFixture.chapterID(number: 877), "The canonical next chapter crosses volumes in natural order")
    }
}
#endif
