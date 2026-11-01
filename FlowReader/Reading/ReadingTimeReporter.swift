import Foundation
import Observation

/// Owns the short-lived reading clock independently of a reader view or an HTTP request.
/// Only whole, genuinely elapsed seconds leave the ledger, and each delta is sent once.
@MainActor @Observable
final class ReadingTimeReporter {
    struct Client {
        var generation: @MainActor () async -> UUID
        var profile: @MainActor () async throws -> AccountProfile
        var report: @MainActor (ReadingTimeSubmission) async throws -> ReadingTimeReceipt

        static let live = Client(
            generation: { await SFAPI.shared.sessionGeneration() },
            profile: { try await SFAPI.shared.accountServiceProfile() },
            report: { try await SFAPI.shared.reportReadingTime($0) }
        )
    }

    private(set) var confirmationRevision = 0
    private(set) var isCounting = false
    private(set) var isVerifying = false
    private(set) var isSending = false
    private(set) var needsLogin = true
    private(set) var lastConfirmedAt: Date?
    private(set) var lastError: String?
    @ObservationIgnored private let client: Client
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let wallDate: () -> Date
    @ObservationIgnored private let automaticTicks: Bool
    @ObservationIgnored private var ledger = ReadingTimeLedger()
    @ObservationIgnored private var activity: ReadingTimeContext?
    @ObservationIgnored private var identity: AccountProfile?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var authorizationID = UUID()
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var submissionTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [ReadingTimeSubmission] = []

    init(client: Client = .live, automaticTicks: Bool = true,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallDate: @escaping () -> Date = Date.init) {
        self.client = client; self.automaticTicks = automaticTicks
        self.now = now; self.wallDate = wallDate
    }

    var statusMessage: String {
        if let lastError { return lastError }
        if isVerifying { return "正在确认阅读账号…" }
        if needsLogin { return "连接账号服务后，在本应用打开小说即可累计阅读时长。" }
        if isSending { return "正在同步本次阅读时长…" }
        if isCounting { return "正在累计本次阅读时长。" }
        if activity != nil { return "阅读计时已暂停，触摸正文或翻页后继续。" }
        if lastConfirmedAt != nil { return "阅读时长已同步，任务进度以官方返回为准。" }
        return "打开小说正文开始计时，离开阅读界面后暂停。"
    }

    /// A nil context means no eligible text is currently visible. This call settles time
    /// synchronously, before asynchronous identity checks or a background transition.
    func setActivity(_ context: ReadingTimeContext?) {
        guard context != activity else { return }
        if let context, let generation, context.generation != generation {
            // A new account must never race an automatic flush of the previous account.
            clearIdentity()
        } else {
            ledger.setContext(nil, now: now(), wallDate: wallDate())
            isCounting = false
            enqueuePending(force: true)
        }
        activity = context
        authorizationID = UUID()
        authorizationTask?.cancel(); authorizationTask = nil
        timerTask?.cancel(); timerTask = nil
        isVerifying = false
        guard let context else { return }
        let request = authorizationID
        isVerifying = true
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            await self.authorize(context, request: request)
        }
    }

    func noteInteraction() {
        guard activity != nil, identity != nil, !needsLogin else { return }
        ledger.markInteraction(now: now(), wallDate: wallDate())
        isCounting = ledger.isCounting
    }

    /// Refreshing the welfare page may verify identity, but cannot start a reading clock.
    func refreshSessionStatus() async {
        guard activity == nil else { return }
        var request = authorizationID
        let current = await client.generation()
        guard activity == nil, request == authorizationID else { return }
        if let generation, current != generation { clearIdentity() }
        request = authorizationID
        do {
            let account = try await client.profile()
            let after = await client.generation()
            guard after == current, activity == nil, request == authorizationID else { return }
            if let identity, !identity.matchesAccountIdentity(account) { clearIdentity() }
            identity = account; generation = current; needsLogin = false
        } catch {
            let after = await client.generation()
            guard after == current, activity == nil, request == authorizationID else { return }
            if SFAPI.isAuthenticationFailure(error) {
                clearIdentity()
            }
        }
    }

    /// Exposed internally for deterministic clocks in tests; production calls this every 5s.
    func tick() async {
        guard let activity, let generation else { return }
        let request = authorizationID
        let current = await client.generation()
        guard request == authorizationID, activity == self.activity, generation == self.generation else { return }
        guard current == generation else { clearIdentity(); return }
        ledger.sample(now: now(), wallDate: wallDate())
        isCounting = ledger.isCounting
        enqueuePending(force: false)
    }

    private func authorize(_ context: ReadingTimeContext, request: UUID) async {
        defer {
            if authorizationID == request { isVerifying = false; authorizationTask = nil }
        }
        do {
            guard await client.generation() == context.generation else { throw CancellationError() }
            let account: AccountProfile
            if generation == context.generation, let identity, !needsLogin {
                account = identity
            } else {
                account = try await client.profile()
            }
            let after = await client.generation()
            try Task.checkCancellation()
            guard authorizationID == request, activity == context, after == context.generation else { return }
            if generation != context.generation { ledger.reset(); queue.removeAll(); lastConfirmedAt = nil; lastError = nil }
            identity = account; generation = context.generation; needsLogin = false
            ledger.setContext(context, now: now(), wallDate: wallDate())
            isCounting = ledger.isCounting
            startTimer()
        } catch {
            guard authorizationID == request, activity == context else { return }
            ledger.reset(); isCounting = false
            if SFAPI.isAuthenticationFailure(error) { identity = nil; needsLogin = true; lastError = nil }
            else if !(error is CancellationError) { lastError = "暂时无法确认阅读账号，本次尚未开始计时。请联网后重新打开章节。" }
        }
    }

    private func startTimer() {
        guard automaticTicks else { return }
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func enqueuePending(force: Bool) {
        guard let identity, let generation else { return }
        for slice in ledger.takePending(force: force) where slice.generation == generation {
            queue.append(ReadingTimeSubmission(id: slice.id, account: identity, generation: generation,
                                              bookID: slice.bookID, chapterID: slice.chapterID,
                                              seconds: slice.seconds, readingDate: slice.readingDate))
        }
        guard submissionTask == nil, !queue.isEmpty else { return }
        submissionTask = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        isSending = true
        defer { isSending = false; submissionTask = nil }
        while !queue.isEmpty {
            let submission = queue.removeFirst()
            guard generation == submission.generation else { continue }
            let current = await client.generation()
            guard generation == submission.generation else { continue }
            guard current == submission.generation else { clearIdentity(); return }
            do {
                let receipt = try await client.report(submission)
                guard generation == submission.generation else { continue }
                let current = await client.generation()
                guard generation == submission.generation else { continue }
                guard current == submission.generation else { clearIdentity(); return }
                guard receipt.submissionID == submission.id, receipt.generation == submission.generation else {
                    lastError = "本次时长的同步结果未能确认，请刷新任务查看。为避免重复计时，不会重复提交。"
                    continue
                }
                lastConfirmedAt = receipt.confirmedAt; lastError = nil
                confirmationRevision &+= 1
            } catch {
                guard generation == submission.generation else { continue }
                let current = await client.generation()
                guard generation == submission.generation else { continue }
                guard current == submission.generation else { clearIdentity(); return }
                // An additive endpoint has no idempotency token. Never replay an uncertain delta,
                // including after a view dismissal, app foreground transition or network recovery.
                if case ReadingTimeSubmissionError.notSent(let underlying) = error,
                   SFAPI.isAuthenticationFailure(underlying) {
                    clearIdentity()
                    lastError = "阅读账号已失效，请重新连接账号服务后继续计时。"
                    return
                }
                lastError = "本次时长未能确认同步，请刷新任务查看。为避免重复计时，不会重复提交。"
            }
        }
    }

    private func clearIdentity() {
        ledger.reset(); queue.removeAll()
        identity = nil; generation = nil; activity = nil
        authorizationID = UUID(); authorizationTask?.cancel(); authorizationTask = nil
        timerTask?.cancel(); timerTask = nil
        isCounting = false; isVerifying = false; needsLogin = true
        lastConfirmedAt = nil; lastError = nil
    }
}
