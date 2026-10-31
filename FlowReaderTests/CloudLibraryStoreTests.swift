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
}

@MainActor
private final class CloudClientFixture {
    var generation = UUID()
    var profileResult: Result<AccountProfile, Error> = .success(AccountProfile(id: 0, name: "测试账号", accountName: "test_account"))
    var shelfResult: Result<BookshelfSyncResult, Error> = .success(BookshelfSyncResult(books: [Book(id: 1, title: "测试藏书", author: "测试")], failedSectionCount: 0))
    var shelfCalls = 0
    var writeCalls = 0
    var appConnected = false
    var webConnected = true
    var useConnectionSnapshot = false
    var connectionSnapshot: AccountConnectionSnapshot?
    var connectionError: Error?
    var connectionCalls = 0
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
            hasWebSession: { self.webConnected },
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
            },
            connections: useConnectionSnapshot ? {
                self.connectionCalls += 1
                if let error = self.connectionError { throw error }
                guard let snapshot = self.connectionSnapshot else { throw SFAPIError.invalidResponse }
                return snapshot
            } : nil
        )
    }
}
