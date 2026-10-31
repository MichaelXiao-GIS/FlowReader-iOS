import Foundation
import Observation

@MainActor @Observable
final class CloudLibraryStore {
    struct Client {
        var generation: @MainActor () async -> UUID
        var hasAppSession: @MainActor () async -> Bool
        var hasWebSession: @MainActor () async -> Bool
        var profile: @MainActor () async throws -> AccountProfile
        var bookshelf: @MainActor () async throws -> BookshelfSyncResult
        var recordProgress: (@MainActor (Int, Int, UUID) async throws -> CloudProgressReceipt)? = nil
        var readingHistory: (@MainActor () async throws -> CloudReadingSnapshot)? = nil

        static let live = Client(
            generation: { await SFAPI.shared.sessionGeneration() },
            hasAppSession: { await SFAPI.shared.hasAppSession() },
            hasWebSession: { await SFAPI.shared.hasWebSession() },
            profile: { try await SFAPI.shared.profile() },
            bookshelf: { try await SFAPI.shared.bookshelfSync() },
            recordProgress: { try await SFAPI.shared.recordCloudProgress(bookID: $0, chapterID: $1, expectedGeneration: $2) },
            readingHistory: { try await SFAPI.shared.cloudReadingHistory() }
        )
    }

    private(set) var shelf = AccountShelfState()
    private(set) var account: AccountProfile?
    private(set) var accountError: String?
    private(set) var appConnected = false
    private(set) var webConnected = false
    private(set) var webNeedsLogin = false
    private(set) var hasCheckedAccount = false
    private(set) var accountLoading = false
    private(set) var sessionGeneration: UUID?
    private(set) var readingHistory: [CloudReadingProgress] = []
    private(set) var historyHasSnapshot = false
    private(set) var historyLoading = false
    private(set) var historyError: String?
    private var purchaseStatesByBook: [Int: [Int: ChapterPurchaseState]] = [:]
    @ObservationIgnored private let client: Client
    @ObservationIgnored private var accountRequest = UUID()
    @ObservationIgnored private var historyRequest = UUID()

    var isConnected: Bool { appConnected || webConnected }
    var books: [Book] { shelf.books }

    init(client: Client = .live) { self.client = client }

    /// Initializes permission scope without fetching a profile or the user's shelf.
    func checkSessionGeneration() async { _ = await synchronizeGeneration() }

    func readingProgress(bookID: Int) -> CloudReadingProgress? { readingHistory.first { $0.bookID == bookID } }

    func loadHistoryIfNeeded() async {
        _ = await synchronizeGeneration()
        guard !historyHasSnapshot, !historyLoading else { return }
        await refreshHistory()
    }

    func refreshHistory() async {
        let generation = await synchronizeGeneration()
        guard let read = client.readingHistory, await client.hasAppSession(), await isCurrent(generation) else { return }
        let request = UUID()
        historyRequest = request
        historyLoading = true
        historyError = nil
        defer { if historyRequest == request { historyLoading = false } }
        do {
            let snapshot = try await read()
            guard await isCurrent(generation), snapshot.generation == generation,
                  historyRequest == request, !Task.isCancelled else { return }
            readingHistory = snapshot.records
            historyHasSnapshot = true
        } catch {
            guard await isCurrent(generation), historyRequest == request,
                  !Task.isCancelled, !AccountShelfState.isCancellation(error) else { return }
            historyError = error.localizedDescription
        }
    }

    func purchaseState(for chapter: Chapter) -> ChapterPurchaseState {
        purchaseStatesByBook[chapter.bookID]?[chapter.id] ?? chapter.purchaseState(for: sessionGeneration)
    }

    func applyPurchaseSnapshot(_ snapshot: ChapterPurchaseSnapshot, bookID: Int) {
        guard snapshot.generation == sessionGeneration else { return }
        purchaseStatesByBook[bookID] = snapshot.states
    }

    func applyChapterAccess(_ chapter: Chapter) async {
        guard chapter.isVIP, chapter.bookID > 0, chapter.id > 0 else { return }
        let generation = await synchronizeGeneration()
        guard !Task.isCancelled else { return }
        let state = chapter.purchaseState(for: generation)
        guard state == .available || state == .purchased else { return }
        guard purchaseStatesByBook[chapter.bookID]?[chapter.id] != .purchased else { return }
        purchaseStatesByBook[chapter.bookID, default: [:]][chapter.id] = state
    }

    @discardableResult
    func recordOpenedChapter(book: Book, chapter: Chapter, expectedGeneration: UUID) async throws -> Bool {
        guard book.id > 0, chapter.id > 0, chapter.bookID == book.id, let record = client.recordProgress,
              await client.hasWebSession(), await isCurrent(expectedGeneration), !Task.isCancelled else { return false }
        _ = try await record(book.id, chapter.id, expectedGeneration)
        guard await isCurrent(expectedGeneration), !Task.isCancelled else { return false }
        if historyHasSnapshot {
            // This snapshot already verified that Web and App belong to the same account.
            // The receipt confirms the position; only a fresh GET may supply a server timestamp.
            readingHistory.removeAll { $0.bookID == book.id }
            readingHistory.insert(CloudReadingProgress(bookID: book.id, chapterID: chapter.id, chapterTitle: chapter.title, updatedAt: nil), at: 0)
        }
        return true
    }

    /// Account/settings screens only fetch identity; the library owns shelf synchronization.
    func refreshAccount() async {
        let generation = await synchronizeGeneration()
        let request = UUID()
        accountRequest = request
        accountLoading = true
        let app = await client.hasAppSession()
        let web = await client.hasWebSession()
        guard await isCurrent(generation), accountRequest == request else { return }
        appConnected = app
        webConnected = web
        hasCheckedAccount = true
        guard app || web else {
            account = nil; accountError = nil; webNeedsLogin = false
            shelf.reset()
            accountLoading = false
            return
        }
        do {
            let profile = try await client.profile()
            guard await isCurrent(generation), accountRequest == request, !Task.isCancelled else {
                if accountRequest == request { accountLoading = false }
                return
            }
            if let previous = account, !previous.matchesAccountIdentity(profile) {
                shelf.reset()
                purchaseStatesByBook = [:]
                historyRequest = UUID()
                readingHistory = []; historyHasSnapshot = false
                historyLoading = false; historyError = nil
            }
            account = profile
            accountError = nil
            webNeedsLogin = false
        } catch {
            guard await isCurrent(generation), accountRequest == request else { return }
            if !Task.isCancelled && !AccountShelfState.isCancellation(error) {
                accountError = error.localizedDescription
                if web {
                    switch error {
                    case SFAPIError.loginRequired, SFAPIError.authenticationRequired: webNeedsLogin = true
                    default: break
                    }
                }
            }
        }
        if accountRequest == request { accountLoading = false }
    }

    func loadIfNeeded() async {
        await refreshAccount()
        guard isConnected, !Task.isCancelled else { return }
        if !shelf.hasSnapshot && !shelf.loading { await synchronizeShelf() }
        await loadHistoryIfNeeded()
    }

    func refresh() async {
        await refreshAccount()
        guard isConnected, !Task.isCancelled else { return }
        await synchronizeShelf()
        await refreshHistory()
    }

    func reset() {
        sessionGeneration = nil
        clearAccountData()
    }

    private func synchronizeShelf() async {
        guard let generation = sessionGeneration, await isCurrent(generation), isConnected else { return }
        let request = UUID()
        shelf.begin(request)
        do {
            let result = try await client.bookshelf()
            guard await isCurrent(generation) else { return }
            if Task.isCancelled { shelf.fail(CancellationError(), for: request) }
            else { shelf.complete(result, for: request) }
        } catch {
            guard await isCurrent(generation) else { return }
            shelf.fail(error, for: request, taskIsCancelled: Task.isCancelled)
            if webConnected {
                switch error {
                case SFAPIError.loginRequired, SFAPIError.authenticationRequired: webNeedsLogin = true
                default: break
                }
            }
        }
    }

    private func synchronizeGeneration() async -> UUID {
        let current = await client.generation()
        if sessionGeneration != current {
            clearAccountData()
            sessionGeneration = current
        }
        return current
    }

    private func isCurrent(_ expected: UUID) async -> Bool { await synchronizeGeneration() == expected }

    private func clearAccountData() {
        accountRequest = UUID()
        historyRequest = UUID()
        readingHistory = []; historyHasSnapshot = false
        historyLoading = false; historyError = nil
        shelf.reset()
        purchaseStatesByBook = [:]
        account = nil; accountError = nil
        appConnected = false; webConnected = false; webNeedsLogin = false
        hasCheckedAccount = false; accountLoading = false
    }
}
