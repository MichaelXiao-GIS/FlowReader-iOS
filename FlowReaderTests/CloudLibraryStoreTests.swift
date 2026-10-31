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

    func testExpiredOptionalWebSessionDoesNotBlockAppLibrary() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.useConnectionSnapshot = true
        fixture.connectionSnapshot = AccountConnectionSnapshot(generation: fixture.generation, usesAppAccount: true,
            appAccount: AccountProfile(id: 41, name: "测试主账号", accountName: "test_primary"),
            webError: "网页授权已过期", webNeedsLogin: true)
        let store = CloudLibraryStore(client: fixture.client)
        await store.refresh()
        XCTAssertEqual(store.account?.id, 41)
        XCTAssertTrue(store.appConnected)
        XCTAssertFalse(store.webConnected)
        XCTAssertTrue(store.webNeedsLogin)
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.books.map(\.id), [1])
        XCTAssertNil(store.accountError)
    }

    func testExpiredPrimaryAccountDoesNotSilentlySwitchToSecondaryWebAccount() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.useConnectionSnapshot = true
        fixture.connectionSnapshot = AccountConnectionSnapshot(generation: fixture.generation, usesAppAccount: true,
            webAccount: AccountProfile(id: 99, name: "网页测试账号", accountName: "secondary"),
            appError: "账号登录已失效", appNeedsLogin: true)
        let store = CloudLibraryStore(client: fixture.client)
        await store.refresh()
        XCTAssertNil(store.account)
        XCTAssertFalse(store.appConnected)
        XCTAssertTrue(store.appNeedsLogin)
        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(fixture.shelfCalls, 0)
    }

    func testCancelledRefreshAfterLocalAppExpiryPreservesPrimaryAccountScope() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.webConnected = true
        fixture.useConnectionSnapshot = true
        fixture.connectionSnapshot = AccountConnectionSnapshot(generation: fixture.generation, usesAppAccount: true,
            appAccount: AccountProfile(id: 41, name: "App 测试账号", accountName: "primary_a"),
            webAccount: AccountProfile(id: 99, name: "网页测试账号", accountName: "secondary_b"))
        let store = CloudLibraryStore(client: fixture.client)
        await store.refresh()
        XCTAssertTrue(store.usesAppAccount)
        XCTAssertEqual(store.account?.id, 41)
        XCTAssertEqual(store.webAccount?.id, 99)
        XCTAssertEqual(store.books.map(\.id), [1])

        // Local cookie expiry does not change the saved primary login or its generation.
        // A cancelled verification must leave the previous verified scope intact.
        fixture.appConnected = false
        fixture.connectionError = CancellationError()
        await store.refreshAccount()

        XCTAssertEqual(fixture.connectionCalls, 2)
        XCTAssertTrue(store.usesAppAccount, "Cancellation must not promote the independent Web account")
        XCTAssertTrue(store.hasSavedConnection)
        XCTAssertEqual(store.account?.id, 41)
        XCTAssertEqual(store.webAccount?.id, 99)
        XCTAssertEqual(store.sessionGeneration, fixture.generation)
        XCTAssertEqual(store.books.map(\.id), [1])
        XCTAssertEqual(fixture.shelfCalls, 1)
        XCTAssertNil(store.accountError)
        XCTAssertFalse(store.accountLoading)
    }

    func testUnknownConnectionsAreNeverDisplayedAsVerified() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.useConnectionSnapshot = true
        fixture.connectionSnapshot = AccountConnectionSnapshot(generation: fixture.generation, usesAppAccount: true,
            appError: "网络暂不可读", webError: "网络暂不可读")
        let store = CloudLibraryStore(client: fixture.client)
        await store.refreshAccount()
        XCTAssertFalse(store.appConnected)
        XCTAssertFalse(store.webConnected)
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(store.hasSavedConnection)
        XCTAssertFalse(store.accountLoading)
    }

    func testIdentityAfterTransientFailureCannotMergePreviousPartialShelf() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.useConnectionSnapshot = true
        fixture.connectionSnapshot = AccountConnectionSnapshot(generation: fixture.generation, usesAppAccount: true,
            appAccount: AccountProfile(id: 41, name: "甲", accountName: "account_a"))
        let store = CloudLibraryStore(client: fixture.client)
        await store.refresh()
        fixture.connectionSnapshot = AccountConnectionSnapshot(generation: fixture.generation, usesAppAccount: true,
            appError: "暂不可读")
        await store.refreshAccount()
        XCTAssertNil(store.account)
        fixture.connectionSnapshot = AccountConnectionSnapshot(generation: fixture.generation, usesAppAccount: true,
            appAccount: AccountProfile(id: 42, name: "乙", accountName: "account_b"))
        fixture.shelfResult = .success(BookshelfSyncResult(books: [Book(id: 2, title: "新账号藏书", author: "测试")], failedSectionCount: 1))
        await store.refresh()
        XCTAssertEqual(store.books.map(\.id), [2])
        XCTAssertEqual(store.account?.id, 42)
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

    func testAppOnlyLoginCanWriteOpenedChapterProgress() async throws {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.webConnected = false
        let store = CloudLibraryStore(client: fixture.client)
        await store.checkSessionGeneration()
        let book = Book(id: 1, title: "原创测试", author: "测试作者")
        let chapter = Chapter(id: 10, bookID: 1, volumeID: 1, volumeTitle: "正文", title: "测试章", order: 0)

        let recorded = try await store.recordOpenedChapter(book: book, chapter: chapter, expectedGeneration: fixture.generation)
        XCTAssertTrue(recorded)
        XCTAssertEqual(fixture.writeCalls, 1, "A valid App login must reach the progress writer without a Web login")

        fixture.appConnected = false
        let disconnected = try await store.recordOpenedChapter(book: book, chapter: chapter, expectedGeneration: fixture.generation)
        XCTAssertFalse(disconnected)
        XCTAssertEqual(fixture.writeCalls, 1, "No login must not dispatch a second progress write")
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

    func testHistoryTTLRefreshesAndroidChangesAndFailurePreservesSnapshot() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 10, updatedAt: fixture.now)]
        let store = CloudLibraryStore(client: fixture.client)
        await store.loadIfNeeded()
        fixture.now.addTimeInterval(59)
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 11, updatedAt: fixture.now)]
        await store.loadIfNeeded()
        XCTAssertEqual(fixture.historyCalls, 1)
        XCTAssertEqual(store.readingProgress(bookID: 1)?.chapterID, 10)
        fixture.now.addTimeInterval(2)
        await store.loadIfNeeded()
        XCTAssertEqual(fixture.historyCalls, 2)
        XCTAssertEqual(store.readingProgress(bookID: 1)?.chapterID, 11)
        fixture.historyError = SFAPIError.server("原创测试网络错误")
        await store.refreshHistory()
        XCTAssertEqual(fixture.historyCalls, 3, "Explicit refresh bypasses TTL")
        XCTAssertEqual(store.readingProgress(bookID: 1)?.chapterID, 11)
        XCTAssertNotNil(store.historyError)
        await store.loadHistoryIfNeeded()
        XCTAssertEqual(fixture.historyCalls, 3, "Failure must not cause an immediate request loop")
    }

    func testShelfSortUsesRecentTimeAndStableUnknownOrderWithoutPrefetchingCatalogs() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        let books = [8, 3, 9, 2].map { Book(id: $0, title: "原创测试\($0)", author: "测试") }
        fixture.shelfResult = .success(BookshelfSyncResult(books: books, failedSectionCount: 0))
        fixture.historyRecords = [
            CloudReadingProgress(bookID: 3, chapterID: 30, updatedAt: fixture.now),
            CloudReadingProgress(bookID: 2, chapterID: 20, updatedAt: fixture.now.addingTimeInterval(100))
        ]
        let store = CloudLibraryStore(client: fixture.client)
        await store.loadIfNeeded()
        XCTAssertEqual(store.sortedBooks.map(\.id), [2, 3, 8, 9])
        XCTAssertEqual(fixture.catalogCalls, 0, "Loading a 200-book shelf must not fetch 200 catalogs")
        XCTAssertNil(store.readingFraction(bookID: 3), "Unknown chapter total is not 0%")
    }

    func testVisibleCatalogsShareCacheAndLimitConcurrencyToTwo() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.catalogDelayNanoseconds = 20_000_000
        let books = (1...6).map { Book(id: $0, title: "原创测试\($0)", author: "测试") }
        fixture.historyRecords = books.map { CloudReadingProgress(bookID: $0.id, chapterID: $0.id * 10 + 1, updatedAt: fixture.now) }
        let store = CloudLibraryStore(client: fixture.client)
        await store.refreshHistory()
        await withTaskGroup(of: Void.self) { group in
            for book in books { group.addTask { await store.loadReadingFractionIfNeeded(for: book) } }
        }
        XCTAssertEqual(fixture.catalogCalls, 6)
        XCTAssertEqual(fixture.maximumActiveCatalogs, 2)
        XCTAssertEqual(store.readingFraction(bookID: 1), 1.0 / 3.0)
        for book in books { await store.loadReadingFractionIfNeeded(for: book) }
        XCTAssertEqual(fixture.catalogCalls, 6, "Visible cards reuse the full catalog cache")
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 12, updatedAt: fixture.now)]
        await store.refreshHistory()
        await store.loadReadingFractionIfNeeded(for: books[0])
        XCTAssertEqual(store.readingFraction(bookID: 1), 2.0 / 3.0)
        XCTAssertEqual(fixture.catalogCalls, 6, "A new chapter already in the catalog needs no request")
    }

    func testCancelledVisibleRequestCanImmediatelyRestartWithoutStickingAtNil() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.catalogDelayNanoseconds = 50_000_000
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 11, updatedAt: nil)]
        let store = CloudLibraryStore(client: fixture.client)
        await store.refreshHistory()
        let book = Book(id: 1, title: "原创取消测试", author: "测试")
        let old = Task { await store.loadReadingFractionIfNeeded(for: book) }
        for _ in 0..<1000 { if fixture.catalogCalls > 0 { break }; await Task.yield() }
        XCTAssertEqual(fixture.catalogCalls, 1)
        old.cancel()
        await store.loadReadingFractionIfNeeded(for: book)
        await old.value
        XCTAssertEqual(store.readingFraction(bookID: 1), 1.0 / 3.0)
        XCTAssertEqual(fixture.catalogCalls, 2)
    }

    func testHistoryRefreshInvalidatesVisibleTaskAndExpiredCatalogIsNotDisplayed() async {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        var book = Book(id: 1, title: "原创目录更新测试", author: "测试", updatedAt: "revision-a")
        fixture.shelfResult = .success(BookshelfSyncResult(books: [book], failedSectionCount: 0))
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 11, updatedAt: nil)]
        let store = CloudLibraryStore(client: fixture.client)
        await store.loadIfNeeded()
        await store.loadReadingFractionIfNeeded(for: book)
        XCTAssertNotNil(store.readingFraction(bookID: 1))
        fixture.now.addTimeInterval(601)
        XCTAssertNil(store.readingFraction(bookID: 1), "Expired catalog must not continue supplying a stale denominator")
        let revision = store.readingFractionRevision
        await store.refreshHistory()
        XCTAssertGreaterThan(store.readingFractionRevision, revision, "Visible tasks must be invalidated even when chapterID is unchanged")
        await store.loadReadingFractionIfNeeded(for: book)
        XCTAssertEqual(fixture.catalogCalls, 2)
        XCTAssertNotNil(store.readingFraction(bookID: 1))

        book.updatedAt = "revision-b"
        fixture.shelfResult = .success(BookshelfSyncResult(books: [book], failedSectionCount: 0))
        await store.refresh()
        XCTAssertNil(store.readingFraction(bookID: 1), "A changed official book revision invalidates the old catalog immediately")
        await store.loadReadingFractionIfNeeded(for: book)
        XCTAssertEqual(fixture.catalogCalls, 3)
        XCTAssertNotNil(store.readingFraction(bookID: 1))
    }

    func testAccountChangeDiscardsLateCatalogAndSameGenerationIdentityClearsCache() async throws {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 11, updatedAt: nil)]
        fixture.suspendCatalog = true
        let store = CloudLibraryStore(client: fixture.client)
        await store.loadIfNeeded()
        let book = Book(id: 1, title: "原创隔离测试", author: "测试")
        let request = Task { await store.loadReadingFractionIfNeeded(for: book) }
        for _ in 0..<1000 { if fixture.pendingCatalog != nil { break }; await Task.yield() }
        let pending = try XCTUnwrap(fixture.pendingCatalog)
        fixture.generation = UUID()
        await store.checkSessionGeneration()
        pending.resume(returning: fixture.chapters(bookID: 1))
        fixture.pendingCatalog = nil
        await request.value
        XCTAssertNil(store.readingFraction(bookID: 1))
        XCTAssertTrue(store.readingHistory.isEmpty)

        fixture.suspendCatalog = false
        await store.loadIfNeeded()
        await store.loadReadingFractionIfNeeded(for: book)
        XCTAssertNotNil(store.readingFraction(bookID: 1))
        fixture.profileResult = .success(AccountProfile(id: 2, name: "另一个原创测试账号", accountName: "different_account"))
        await store.refreshAccount()
        XCTAssertTrue(store.readingHistory.isEmpty)
        XCTAssertNil(store.readingFraction(bookID: 1))
    }

    func testOldHistoryCannotUndoNewReceiptButNextFreshReadWinsRegardlessOfClock() async throws {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.suspendHistory = true
        let store = CloudLibraryStore(client: fixture.client)
        let request = Task { await store.refreshHistory() }
        for _ in 0..<1000 { if fixture.pendingHistory != nil { break }; await Task.yield() }
        let pending = try XCTUnwrap(fixture.pendingHistory)
        let book = Book(id: 1, title: "原创顺序测试", author: "测试")
        let chapter = fixture.chapters(bookID: 1)[1]
        _ = try await store.recordOpenedChapter(book: book, chapter: chapter, expectedGeneration: fixture.generation)
        pending.resume(returning: CloudReadingSnapshot(records: [CloudReadingProgress(bookID: 1, chapterID: 10, updatedAt: nil)], generation: fixture.generation))
        fixture.pendingHistory = nil
        await request.value
        XCTAssertEqual(store.readingProgress(bookID: 1)?.chapterID, 11)
        XCTAssertNotNil(store.readingProgress(bookID: 1)?.locallyConfirmedAt)
        XCTAssertNil(store.readingProgress(bookID: 1)?.updatedAt)

        fixture.suspendHistory = false
        // A slow device/server clock must not make the newer, fresh server read lose forever.
        fixture.historyRecords = [CloudReadingProgress(bookID: 1, chapterID: 12, updatedAt: fixture.now.addingTimeInterval(-86_400))]
        await store.refreshHistory()
        XCTAssertEqual(store.readingProgress(bookID: 1)?.chapterID, 12)
        XCTAssertNil(store.readingProgress(bookID: 1)?.locallyConfirmedAt)
    }

    func testLateWriteReceiptCannotEnterDifferentIdentityEvenWhenGenerationIsUnchanged() async throws {
        let fixture = CloudClientFixture()
        fixture.appConnected = true
        fixture.suspendWrite = true
        let store = CloudLibraryStore(client: fixture.client)
        await store.loadIfNeeded()
        let book = Book(id: 1, title: "原创回执隔离测试", author: "测试")
        let write = Task { try await store.recordOpenedChapter(book: book, chapter: fixture.chapters(bookID: 1)[1], expectedGeneration: fixture.generation) }
        for _ in 0..<1000 { if fixture.pendingWrite != nil { break }; await Task.yield() }
        let pending = try XCTUnwrap(fixture.pendingWrite)
        let generation = fixture.generation
        fixture.profileResult = .success(AccountProfile(id: 2, name: "新的测试身份", accountName: "another_identity"))
        await store.refreshAccount()
        XCTAssertEqual(store.sessionGeneration, generation)
        XCTAssertEqual(store.account?.id, 2)
        pending.resume(returning: CloudProgressReceipt(bookID: 1, chapterID: 11, confirmedAt: fixture.now))
        fixture.pendingWrite = nil
        let accepted = try await write.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(store.readingHistory.isEmpty, "An old identity's receipt must not repopulate the cleared cloud history")
    }
}

@MainActor
private final class CloudClientFixture {
    var generation = UUID()
    var profileResult: Result<AccountProfile, Error> = .success(AccountProfile(id: 0, name: "测试账号", accountName: "test_account"))
    var shelfResult: Result<BookshelfSyncResult, Error> = .success(BookshelfSyncResult(books: [Book(id: 1, title: "测试藏书", author: "测试")], failedSectionCount: 0))
    var shelfCalls = 0
    var writeCalls = 0
    var suspendWrite = false
    var pendingWrite: CheckedContinuation<CloudProgressReceipt, Error>?
    var appConnected = false
    var webConnected = true
    var useConnectionSnapshot = false
    var connectionSnapshot: AccountConnectionSnapshot?
    var connectionError: Error?
    var connectionCalls = 0
    var historyCalls = 0
    var historyError: Error?
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var historyRecords: [CloudReadingProgress] = []
    var suspendHistory = false
    var pendingHistory: CheckedContinuation<CloudReadingSnapshot, Error>?
    var suspendShelf = false
    var pendingShelf: CheckedContinuation<BookshelfSyncResult, Error>?
    var catalogCalls = 0
    var activeCatalogs = 0
    var maximumActiveCatalogs = 0
    var catalogDelayNanoseconds: UInt64 = 0
    var suspendCatalog = false
    var pendingCatalog: CheckedContinuation<[Chapter], Error>?

    func chapters(bookID: Int) -> [Chapter] {
        (0..<3).map { Chapter(id: bookID * 10 + $0, bookID: bookID, volumeID: 1, volumeTitle: "正文", title: "原创测试章\($0)", order: $0) }
    }

    var client: CloudLibraryStore.Client {
        CloudLibraryStore.Client(
            generation: { self.generation },
            hasAppSession: { self.appConnected },
            hasWebSession: { self.webConnected },
            profile: { try self.profileResult.get() },
            bookshelf: {
                self.shelfCalls += 1
                if self.suspendShelf { return try await withCheckedThrowingContinuation { self.pendingShelf = $0 } }
                return try self.shelfResult.get()
            },
            recordProgress: { bookID, chapterID, _ in
                self.writeCalls += 1
                if self.suspendWrite { return try await withCheckedThrowingContinuation { self.pendingWrite = $0 } }
                return CloudProgressReceipt(bookID: bookID, chapterID: chapterID, confirmedAt: self.now)
            },
            readingHistory: {
                self.historyCalls += 1
                if let error = self.historyError { throw error }
                if self.suspendHistory { return try await withCheckedThrowingContinuation { self.pendingHistory = $0 } }
                return CloudReadingSnapshot(records: self.historyRecords, generation: self.generation)
            },
            connections: useConnectionSnapshot ? {
                self.connectionCalls += 1
                if let error = self.connectionError { throw error }
                guard let snapshot = self.connectionSnapshot else { throw SFAPIError.invalidResponse }
                return snapshot
            } : nil,
            catalog: { bookID in
                self.catalogCalls += 1
                self.activeCatalogs += 1
                self.maximumActiveCatalogs = max(self.maximumActiveCatalogs, self.activeCatalogs)
                defer { self.activeCatalogs -= 1 }
                if self.suspendCatalog { return try await withCheckedThrowingContinuation { self.pendingCatalog = $0 } }
                if self.catalogDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: self.catalogDelayNanoseconds) }
                return self.chapters(bookID: bookID)
            },
            now: { self.now }
        )
    }
}
