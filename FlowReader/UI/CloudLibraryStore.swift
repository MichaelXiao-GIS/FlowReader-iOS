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
        var connections: (@MainActor () async throws -> AccountConnectionSnapshot)? = nil
        var catalog: (@MainActor (Int) async throws -> [Chapter])? = nil
        var now: @MainActor () -> Date = { Date() }

        static let live = Client(
            generation: { await SFAPI.shared.sessionGeneration() },
            hasAppSession: { await SFAPI.shared.hasAppSession() },
            hasWebSession: { await SFAPI.shared.hasWebSession() },
            profile: { try await SFAPI.shared.libraryProfile() },
            bookshelf: { try await SFAPI.shared.bookshelfSync() },
            recordProgress: { try await SFAPI.shared.recordCloudProgress(bookID: $0, chapterID: $1, expectedGeneration: $2) },
            readingHistory: { try await SFAPI.shared.cloudReadingHistory() },
            connections: { try await SFAPI.shared.accountConnections() },
            catalog: { try await SFAPI.shared.cloudProgressChapters(bookID: $0) }
        )
    }

    private(set) var shelf = AccountShelfState()
    private(set) var account: AccountProfile?
    private(set) var accountError: String?
    private(set) var appConnected = false
    private(set) var webConnected = false
    private(set) var webNeedsLogin = false
    private(set) var appNeedsLogin = false
    private(set) var usesAppAccount = false
    private(set) var webAccount: AccountProfile?
    private(set) var webConnectionError: String?
    private(set) var hasCheckedAccount = false
    private(set) var accountLoading = false
    private(set) var sessionGeneration: UUID?
    private(set) var readingHistory: [CloudReadingProgress] = []
    private(set) var historyHasSnapshot = false
    private(set) var historyLoading = false
    private(set) var historyError: String?
    private(set) var readingFractionRevision: UInt64 = 0
    private var lastVerifiedPrimaryAccount: AccountProfile?
    private var purchaseStatesByBook: [Int: [Int: ChapterPurchaseState]] = [:]
    @ObservationIgnored private let client: Client
    @ObservationIgnored private var accountRequest = UUID()
    @ObservationIgnored private var historyRequest = UUID()
    @ObservationIgnored private var readingDataScope = UUID()
    @ObservationIgnored private var historyLastAttemptAt: Date?
    @ObservationIgnored private var acknowledgedPositions: [Int: CloudReadingProgress] = [:]
    @ObservationIgnored private var acknowledgmentSequence: UInt64 = 0
    @ObservationIgnored private var acknowledgmentVersions: [Int: UInt64] = [:]
    private struct CatalogEntry {
        let catalog: CloudReadingCatalog
        let fetchedAt: Date
        let bookRevision: String?
        let requestedChapterID: Int
    }
    private struct CatalogJob {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var catalogs: [Int: CatalogEntry] = [:]
    @ObservationIgnored private var catalogRecency: [Int] = []
    @ObservationIgnored private var catalogJobs: [Int: CatalogJob] = [:]
    @ObservationIgnored private var catalogLastFailure: [Int: Date] = [:]
    @ObservationIgnored private let catalogGate = CloudCatalogRequestGate(limit: 2)

    var isConnected: Bool { usesAppAccount ? appConnected : webConnected }
    private(set) var hasSavedConnection = false
    var books: [Book] { shelf.books }
    var sortedBooks: [Book] {
        let dates = Dictionary(uniqueKeysWithValues: readingHistory.map { ($0.bookID, $0.lastActivityAt) })
        return books.enumerated().sorted { lhs, rhs in
            switch (dates[lhs.element.id] ?? nil, dates[rhs.element.id] ?? nil) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    init(client: Client = .live) { self.client = client }

    /// Initializes permission scope without fetching a profile or the user's shelf.
    func checkSessionGeneration() async { _ = await synchronizeGeneration() }

    func readingProgress(bookID: Int) -> CloudReadingProgress? { readingHistory.first { $0.bookID == bookID } }

    func readingFraction(bookID: Int) -> Double? {
        guard let progress = readingProgress(bookID: bookID), let entry = catalogs[bookID],
              (0..<600).contains(client.now().timeIntervalSince(entry.fetchedAt)) else { return nil }
        if let book = books.first(where: { $0.id == bookID }), book.updatedAt != entry.bookRevision { return nil }
        return entry.catalog.fraction(chapterID: progress.chapterID)
    }

    /// Called only by visible shelf cards. Catalogs are shared, capped and account scoped.
    func loadReadingFractionIfNeeded(for book: Book) async {
        let generation = await synchronizeGeneration()
        guard book.id > 0, let progress = readingProgress(bookID: book.id),
              let fetch = client.catalog, !Task.isCancelled else { return }
        let now = client.now()
        if let cached = catalogs[book.id], (0..<600).contains(now.timeIntervalSince(cached.fetchedAt)),
           cached.bookRevision == book.updatedAt,
           cached.catalog.positions[progress.chapterID] != nil || cached.requestedChapterID == progress.chapterID {
            touchCatalog(book.id)
            return
        }
        if let failed = catalogLastFailure[book.id], (0..<60).contains(now.timeIntervalSince(failed)) { return }
        if let job = catalogJobs[book.id], !job.task.isCancelled {
            await withTaskCancellationHandler { await job.task.value } onCancel: { job.task.cancel() }
            return
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if catalogJobs[book.id]?.id == id { catalogJobs[book.id] = nil } }
            do {
                try await catalogGate.acquire()
                defer { Task { await self.catalogGate.release() } }
                try Task.checkCancellation()
                guard await isCurrent(generation), catalogJobs[book.id]?.id == id else { return }
                let chapters = try await fetch(book.id)
                try Task.checkCancellation()
                let catalog = try CloudReadingCatalog(bookID: book.id, chapters: chapters)
                guard await isCurrent(generation), catalogJobs[book.id]?.id == id else { return }
                catalogs[book.id] = CatalogEntry(catalog: catalog, fetchedAt: client.now(), bookRevision: book.updatedAt, requestedChapterID: progress.chapterID)
                catalogLastFailure[book.id] = nil
                touchCatalog(book.id)
                trimCatalogs()
            } catch {
                if !Task.isCancelled, !AccountShelfState.isCancellation(error),
                   await isCurrent(generation), catalogJobs[book.id]?.id == id {
                    catalogLastFailure[book.id] = client.now()
                }
            }
        }
        catalogJobs[book.id] = CatalogJob(id: id, task: task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func loadHistoryIfNeeded() async {
        _ = await synchronizeGeneration()
        guard !historyLoading else { return }
        if let last = historyLastAttemptAt, (0..<60).contains(client.now().timeIntervalSince(last)) { return }
        await refreshHistory()
    }

    func refreshHistory() async {
        let generation = await synchronizeGeneration()
        guard let read = client.readingHistory, await client.hasAppSession(), await isCurrent(generation) else { return }
        let request = UUID()
        historyRequest = request
        historyLoading = true
        historyLastAttemptAt = client.now()
        let acknowledgedBeforeRead = acknowledgmentSequence
        historyError = nil
        defer { if historyRequest == request { historyLoading = false } }
        do {
            let snapshot = try await read()
            guard await isCurrent(generation), snapshot.generation == generation,
                  historyRequest == request, !Task.isCancelled else { return }
            readingHistory = mergeAcknowledgments(into: snapshot.records, acknowledgedBeforeRead: acknowledgedBeforeRead)
            historyHasSnapshot = true
            readingFractionRevision &+= 1
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
        guard book.id > 0, chapter.id > 0, chapter.bookID == book.id, let record = client.recordProgress else { return false }
        let hasApp = await client.hasAppSession()
        let hasWeb = await client.hasWebSession()
        guard hasApp || hasWeb, await isCurrent(expectedGeneration), !Task.isCancelled else { return false }
        let scope = readingDataScope
        let receipt = try await record(book.id, chapter.id, expectedGeneration)
        guard await isCurrent(expectedGeneration), readingDataScope == scope, !Task.isCancelled else { return false }
        guard receipt.bookID == book.id, receipt.chapterID == chapter.id else { throw SFAPIError.invalidResponse }
        // Local reading files have no account identity and are never merged into this shelf.
        // Only this account's acknowledged write can temporarily supersede a stale GET.
        let position = CloudReadingProgress(bookID: book.id, chapterID: chapter.id, chapterTitle: chapter.title,
            updatedAt: nil, locallyConfirmedAt: receipt.confirmedAt)
        acknowledgedPositions[book.id] = position
        acknowledgmentSequence &+= 1
        acknowledgmentVersions[book.id] = acknowledgmentSequence
        readingHistory.removeAll { $0.bookID == book.id }
        readingHistory = CloudProgressParser.newestFirst(readingHistory + [position])
        return true
    }

    /// Account/settings screens only fetch identity; the library owns shelf synchronization.
    func refreshAccount() async {
        let generation = await synchronizeGeneration()
        let request = UUID()
        accountRequest = request
        accountLoading = true
        defer { if accountRequest == request { accountLoading = false; hasCheckedAccount = true } }
        let app = await client.hasAppSession()
        let web = await client.hasWebSession()
        guard await isCurrent(generation), accountRequest == request else { return }
        if client.connections == nil {
            appConnected = app
            webConnected = web
            hasSavedConnection = app || web
            usesAppAccount = app
        }
        guard app || web || client.connections != nil else {
            account = nil; accountError = nil; webNeedsLogin = false; appNeedsLogin = false
            appConnected = false; webConnected = false; lastVerifiedPrimaryAccount = nil
            clearReadingData(); purchaseStatesByBook = [:]
            webAccount = nil; webConnectionError = nil
            shelf.reset()
            accountLoading = false
            return
        }
        if let readConnections = client.connections {
            do {
                let connections = try await readConnections()
                guard await isCurrent(generation), connections.generation == generation,
                      accountRequest == request, !Task.isCancelled else { return }
                appConnected = connections.appAccount != nil
                webConnected = connections.webAccount != nil
                appNeedsLogin = connections.appNeedsLogin
                webNeedsLogin = connections.webNeedsLogin
                usesAppAccount = connections.usesAppAccount
                hasSavedConnection = connections.hasSavedConnection
                webAccount = connections.webAccount
                webConnectionError = connections.webError
                if let previous = lastVerifiedPrimaryAccount, let next = connections.primaryAccount,
                   !previous.matchesAccountIdentity(next) {
                    shelf.reset(); purchaseStatesByBook = [:]
                    clearReadingData()
                }
                account = connections.primaryAccount
                if let verified = connections.primaryAccount { lastVerifiedPrimaryAccount = verified }
                accountError = connections.primaryError
            } catch {
                if await isCurrent(generation), accountRequest == request,
                   !AccountShelfState.isCancellation(error), !Task.isCancelled {
                    accountError = error.localizedDescription
                    appConnected = false; webConnected = false
                }
            }
            if accountRequest == request { accountLoading = false }
            return
        }
        do {
            let profile = try await client.profile()
            guard await isCurrent(generation), accountRequest == request, !Task.isCancelled else {
                if accountRequest == request { accountLoading = false }
                return
            }
            if let previous = lastVerifiedPrimaryAccount, !previous.matchesAccountIdentity(profile) {
                shelf.reset()
                purchaseStatesByBook = [:]
                clearReadingData()
            }
            account = profile
            lastVerifiedPrimaryAccount = profile
            accountError = nil
            webNeedsLogin = false
        } catch {
            guard await isCurrent(generation), accountRequest == request else { return }
            if !Task.isCancelled && !AccountShelfState.isCancellation(error) {
                accountError = error.localizedDescription
                if SFAPI.isAuthenticationFailure(error) {
                    if app { appNeedsLogin = true } else if web { webNeedsLogin = true }
                }
            }
        }
        if accountRequest == request { accountLoading = false }
    }

    func loadIfNeeded() async {
        await refreshAccount()
        guard isConnected, !Task.isCancelled else { return }
        async let history: Void = loadHistoryIfNeeded()
        if !shelf.hasSnapshot && !shelf.loading { await synchronizeShelf() }
        await history
    }

    func refresh() async {
        await refreshAccount()
        guard isConnected, !Task.isCancelled else { return }
        async let history: Void = refreshHistory()
        await synchronizeShelf()
        await history
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
            if SFAPI.isAuthenticationFailure(error) {
                if usesAppAccount { appNeedsLogin = true; appConnected = false }
                else { webNeedsLogin = true; webConnected = false }
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

    private func mergeAcknowledgments(into records: [CloudReadingProgress], acknowledgedBeforeRead: UInt64) -> [CloudReadingProgress] {
        var merged = records
        for (bookID, acknowledged) in acknowledgedPositions {
            // A fresh GET begun after the write is authoritative, even if this device's clock
            // is fast. Only an older, already in-flight GET is prevented from undoing a new write.
            if (acknowledgmentVersions[bookID] ?? 0) <= acknowledgedBeforeRead {
                acknowledgedPositions[bookID] = nil
                acknowledgmentVersions[bookID] = nil
                continue
            }
            if let index = merged.firstIndex(where: { $0.bookID == bookID }) {
                merged[index] = acknowledged
            } else { merged.append(acknowledged) }
        }
        return CloudProgressParser.newestFirst(merged)
    }

    private func touchCatalog(_ bookID: Int) {
        catalogRecency.removeAll { $0 == bookID }
        catalogRecency.append(bookID)
    }

    private func trimCatalogs() {
        // Explicit LRU bounds: full chapter objects/text are never retained for cover percentages.
        while catalogs.count > 48 || catalogs.values.reduce(0, { $0 + $1.catalog.count }) > 100_000 {
            guard !catalogRecency.isEmpty else { break }
            catalogs[catalogRecency.removeFirst()] = nil
        }
    }

    private func clearReadingData() {
        readingDataScope = UUID()
        historyRequest = UUID()
        readingHistory = []; historyHasSnapshot = false
        historyLoading = false; historyError = nil
        historyLastAttemptAt = nil
        acknowledgedPositions = [:]
        acknowledgmentVersions = [:]
        readingFractionRevision &+= 1
        for job in catalogJobs.values { job.task.cancel() }
        catalogJobs = [:]; catalogs = [:]; catalogRecency = []; catalogLastFailure = [:]
    }

    private func clearAccountData() {
        accountRequest = UUID()
        clearReadingData()
        shelf.reset()
        purchaseStatesByBook = [:]
        account = nil; accountError = nil; lastVerifiedPrimaryAccount = nil
        appConnected = false; webConnected = false; webNeedsLogin = false; appNeedsLogin = false
        usesAppAccount = false; webAccount = nil; webConnectionError = nil
        hasCheckedAccount = false; accountLoading = false; hasSavedConnection = false
    }
}
