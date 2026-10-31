import XCTest
@testable import FlowReader

@MainActor
final class CloudLibraryStoreTests: XCTestCase {
    func testAccountPageRefreshDoesNotFetchBooksAndLibraryRetainsSnapshot() async {
        let fixture = CloudClientFixture()
        let store = CloudLibraryStore(client: fixture.client)
        await store.refreshAccount()
        XCTAssertEqual(fixture.shelfCalls, 0)
        await store.loadIfNeeded()
        XCTAssertEqual(fixture.shelfCalls, 1)
        await store.loadIfNeeded()
        XCTAssertEqual(fixture.shelfCalls, 1, "Switching tabs must reuse the shared shelf snapshot")
        XCTAssertEqual(store.books.map(\.id), [1])
    }

    func testNewGenerationCannotMergePreviousAccountAfterProfileFailure() async {
        let fixture = CloudClientFixture()
        let store = CloudLibraryStore(client: fixture.client)
        await store.refresh()
        XCTAssertEqual(store.books.map(\.id), [1])

        fixture.generation = UUID()
        fixture.profileResult = .failure(SFAPIError.server("测试身份暂不可读"))
        fixture.shelfResult = .success(BookshelfSyncResult(books: [Book(id: 2, title: "第二个测试账号", author: "测试")], failedSectionCount: 1))
        await store.refresh()
        XCTAssertNil(store.account)
        XCTAssertNotNil(store.accountError)
        XCTAssertEqual(store.books.map(\.id), [2], "A partial result for account B must not retain account A's books")
        XCTAssertNotNil(store.shelf.notice)
    }

    func testInFlightOldGenerationIsDiscarded() async throws {
        let fixture = CloudClientFixture()
        fixture.suspendShelf = true
        let store = CloudLibraryStore(client: fixture.client)
        let oldRequest = Task { await store.refresh() }
        for _ in 0..<100 {
            if fixture.pendingShelf != nil { break }
            await Task.yield()
        }
        let pending = try XCTUnwrap(fixture.pendingShelf)
        fixture.generation = UUID()
        fixture.profileResult = .failure(SFAPIError.server("测试账号已切换"))
        await store.refreshAccount()
        pending.resume(returning: BookshelfSyncResult(books: [Book(id: 99, title: "过期响应", author: "测试")], failedSectionCount: 0))
        fixture.pendingShelf = nil
        await oldRequest.value
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertFalse(store.shelf.hasSnapshot)
        XCTAssertFalse(store.shelf.isConfirmedEmpty)
        XCTAssertNil(store.account)
    }

    func testProgressWriteRequiresMatchingBookAndCurrentSession() async throws {
        let fixture = CloudClientFixture()
        let store = CloudLibraryStore(client: fixture.client)
        await store.checkSessionGeneration()
        let book = Book(id: 1, title: "测试", author: "测试")
        let chapter = Chapter(id: 10, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "测试章", order: 0)
        var otherBookChapter = chapter
        otherBookChapter.bookID = 2
        let mismatched = try await store.recordOpenedChapter(book: book, chapter: otherBookChapter, expectedGeneration: fixture.generation)
        XCTAssertFalse(mismatched)
        XCTAssertEqual(fixture.writeCalls, 0)
        let confirmed = try await store.recordOpenedChapter(book: book, chapter: chapter, expectedGeneration: fixture.generation)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(fixture.writeCalls, 1)
        let oldGeneration = fixture.generation
        fixture.generation = UUID()
        let stale = try await store.recordOpenedChapter(book: book, chapter: chapter, expectedGeneration: oldGeneration)
        XCTAssertFalse(stale)
        XCTAssertEqual(fixture.writeCalls, 1, "Changing accounts must prevent the previous account's pending reading position from being sent")
    }

    func testHistoryLoadsOnceAndConfirmedWriteUpdatesOnlyVerifiedScope() async throws {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 10, updatedAt: nil)]
        let store = CloudLibraryStore(client: fixture.client)
        await store.loadIfNeeded()
        await store.loadIfNeeded()
        XCTAssertEqual(fixture.historyCalls, 1)
        XCTAssertEqual(store.readingProgress(bookID: 1)?.chapterID, 10)
        let book = Book(id: 1, title: "测试", author: "原创测试")
        let next = Chapter(id: 11, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "下一章", order: 1)
        _ = try await store.recordOpenedChapter(book: book, chapter: next, expectedGeneration: fixture.generation)
        XCTAssertEqual(store.readingProgress(bookID: 1)?.chapterID, 11)
        XCTAssertNil(store.readingProgress(bookID: 1)?.updatedAt, "A client receipt must not invent a server timestamp")
    }

    func testLateHistoryFromPreviousAccountCannotEnterNewSnapshot() async throws {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.suspendHistory = true
        let oldGeneration = fixture.generation
        let store = CloudLibraryStore(client: fixture.client)
        let request = Task { await store.refreshHistory() }
        for _ in 0..<100 {
            if fixture.pendingHistory != nil { break }
            await Task.yield()
        }
        let pending = try XCTUnwrap(fixture.pendingHistory)
        fixture.generation = UUID()
        await store.checkSessionGeneration()
        pending.resume(returning: CloudReadingSnapshot(records: [CloudReadingProgress(bookID: 1, chapterID: 10, updatedAt: nil)], generation: oldGeneration))
        fixture.pendingHistory = nil
        await request.value
        XCTAssertTrue(store.readingHistory.isEmpty)
        XCTAssertFalse(store.historyHasSnapshot)
        XCTAssertFalse(store.historyLoading)
    }

    func testReadableChapterMergePreservesOtherOwnershipAndRejectsOldSessions() async {
        let fixture = CloudClientFixture()
        let store = CloudLibraryStore(client: fixture.client)
        await store.checkSessionGeneration()
        let original = Chapter(id: 10, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "原创测试", order: 0, isVIP: true)
        var purchased = original
        purchased.id = 11
        store.applyPurchaseSnapshot(ChapterPurchaseSnapshot(states: [10: .unknown, 11: .purchased], generation: fixture.generation), bookID: 1)
        var readable = original
        readable.confirmedPurchaseState = .available
        readable.purchaseSessionGeneration = fixture.generation
        await store.applyChapterAccess(readable)
        XCTAssertEqual(store.purchaseState(for: original), .available)
        XCTAssertEqual(store.purchaseState(for: purchased), .purchased, "Single chapter updates must preserve other chapters")
        readable.id = 11
        await store.applyChapterAccess(readable)
        XCTAssertEqual(store.purchaseState(for: purchased), .purchased, "Readable access must not erase an existing purchase confirmation")
        fixture.generation = UUID()
        await store.applyChapterAccess(readable)
        XCTAssertEqual(store.purchaseState(for: purchased), .unknown, "A successful response from a previous account is not current access")
        var cached = original
        cached.isOwned = true
        await store.applyChapterAccess(cached)
        XCTAssertEqual(store.purchaseState(for: cached), .unknown, "Downloaded content without a current permission fact must remain unknown")
    }
}

@MainActor
private final class CloudClientFixture {
    var generation = UUID()
    var profileResult: Result<AccountProfile, Error> = .success(AccountProfile(id: 0, name: "测试账号", accountName: "test_account"))
    var shelfResult: Result<BookshelfSyncResult, Error> = .success(BookshelfSyncResult(books: [Book(id: 1, title: "测试藏书", author: "测试")], failedSectionCount: 0))
    var shelfCalls = 0
    var writeCalls = 0
    var appConnected = false
    var historyCalls = 0
    var historyRecords: [CloudReadingProgress] = []
    var suspendHistory = false
    var pendingHistory: CheckedContinuation<CloudReadingSnapshot, Error>?
    var suspendShelf = false
    var pendingShelf: CheckedContinuation<BookshelfSyncResult, Error>?

    var client: CloudLibraryStore.Client {
        CloudLibraryStore.Client(
            generation: { self.generation },
            hasAppSession: { self.appConnected },
            hasWebSession: { true },
            profile: { try self.profileResult.get() },
            bookshelf: {
                self.shelfCalls += 1
                if self.suspendShelf { return try await withCheckedThrowingContinuation { self.pendingShelf = $0 } }
                return try self.shelfResult.get()
            },
            recordProgress: { bookID, chapterID, _ in
                self.writeCalls += 1
                return CloudProgressReceipt(bookID: bookID, chapterID: chapterID, confirmedAt: Date())
            },
            readingHistory: {
                self.historyCalls += 1
                if self.suspendHistory { return try await withCheckedThrowingContinuation { self.pendingHistory = $0 } }
                return CloudReadingSnapshot(records: self.historyRecords, generation: self.generation)
            }
        )
    }
}
