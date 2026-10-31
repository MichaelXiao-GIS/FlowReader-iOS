import XCTest
@testable import FlowReader

@MainActor
final class ReadingSessionTests: XCTestCase {
    func testProcessRestartRestoresSelectedChapterAndExistingTextPosition() throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        fixture.library.save(book: fixture.book, chapters: fixture.chapters)
        let session = ReadingSession(defaults: fixture.defaults)
        session.open(fixture.route)
        fixture.library.recordProgress(book: fixture.book, chapters: fixture.chapters,
                                       chapterID: 12, paragraph: 7, paragraphUTF16Offset: 19)
        session.checkpoint(bookID: fixture.book.id, chapterID: 12)

        let restartedLibrary = LibraryStore(directory: fixture.directory)
        let restartedSession = ReadingSession(defaults: fixture.defaults)
        restartedSession.restoreIfNeeded(from: restartedLibrary)

        XCTAssertEqual(restartedSession.route?.book.id, fixture.book.id)
        XCTAssertEqual(restartedSession.route?.initialChapter.id, 12)
        XCTAssertEqual(restartedSession.route?.chapters.map(\.id), [11, 12])
        XCTAssertEqual(restartedLibrary.localBook(id: fixture.book.id)?.progress?.paragraph, 7)
        XCTAssertEqual(restartedLibrary.localBook(id: fixture.book.id)?.progress?.paragraphUTF16Offset, 19)
    }

    func testCheckpointAndForegroundDoNotReplacePresentedRoute() throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        fixture.library.save(book: fixture.book, chapters: fixture.chapters)
        let session = ReadingSession(defaults: fixture.defaults)
        session.open(fixture.route)
        let presentedID = session.route?.id

        session.checkpoint(bookID: fixture.book.id, chapterID: 12)
        session.restoreIfNeeded(from: fixture.library)
        session.restoreIfNeeded(from: fixture.library)

        XCTAssertEqual(session.route?.id, presentedID, "Saving a page or returning to the foreground must not recreate the reader")
        XCTAssertEqual(session.route?.initialChapter.id, 11, "The live ReaderView owns its selected chapter")
        let restarted = ReadingSession(defaults: fixture.defaults)
        restarted.restoreIfNeeded(from: fixture.library)
        XCTAssertEqual(restarted.route?.initialChapter.id, 12)
    }

    func testExplicitCloseCannotBeUndoneByLateDisappearCheckpoint() throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        fixture.library.save(book: fixture.book, chapters: fixture.chapters)
        let session = ReadingSession(defaults: fixture.defaults)
        session.open(fixture.route)
        session.close()
        session.checkpoint(bookID: fixture.book.id, chapterID: 12)
        session.restoreIfNeeded(from: fixture.library)
        XCTAssertNil(session.route)

        let restarted = ReadingSession(defaults: fixture.defaults)
        restarted.restoreIfNeeded(from: fixture.library)
        XCTAssertNil(restarted.route, "A reader explicitly closed by the user must stay closed after relaunch")
    }

    func testPresentationBindingDismissalClearsSavedSession() throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        fixture.library.save(book: fixture.book, chapters: fixture.chapters)
        let session = ReadingSession(defaults: fixture.defaults)
        session.open(fixture.route)
        session.route = nil
        let restarted = ReadingSession(defaults: fixture.defaults)
        restarted.restoreIfNeeded(from: fixture.library)
        XCTAssertNil(restarted.route)
    }

    func testDeletedBookAndMalformedCheckpointDoNotReopenAnInvalidReader() throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        let session = ReadingSession(defaults: fixture.defaults)
        session.open(fixture.route)
        // The book is absent from the persisted library, as after deletion.
        let restarted = ReadingSession(defaults: fixture.defaults)
        restarted.restoreIfNeeded(from: fixture.library)
        XCTAssertNil(restarted.route)
        XCTAssertNil(fixture.defaults.data(forKey: "navigation.activeReadingSession"))

        fixture.defaults.set(Data("{broken".utf8), forKey: "navigation.activeReadingSession")
        let malformed = ReadingSession(defaults: fixture.defaults)
        malformed.restoreIfNeeded(from: fixture.library)
        XCTAssertNil(malformed.route)
        XCTAssertNil(fixture.defaults.data(forKey: "navigation.activeReadingSession"))
    }

    func testCheckpointRejectsAnotherBookAndPersistsOnlyNavigationIDs() throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        let session = ReadingSession(defaults: fixture.defaults)
        session.open(fixture.route)
        session.checkpoint(bookID: 999, chapterID: 12)
        session.checkpoint(bookID: fixture.book.id, chapterID: 999)
        let data = try XCTUnwrap(fixture.defaults.data(forKey: "navigation.activeReadingSession"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(saved, ["bookID": fixture.book.id, "chapterID": 11], "Restoration must not duplicate content, account identity, or purchase authorization")
    }
}

@MainActor
private final class SessionFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let library: LibraryStore
    let book = Book(id: 1, title: "会话恢复原创测试", author: "测试作者")
    let chapters = [
        Chapter(id: 11, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "第一章", order: 0),
        Chapter(id: 12, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "第二章", order: 1)
    ]
    var route: ReadingRoute { ReadingRoute(book: book, chapters: chapters, initialChapter: chapters[0]) }

    init() throws {
        suite = "FlowReader.ReadingSessionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        library = LibraryStore(directory: directory)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
