import Foundation
import Observation

struct ChapterCommerceClient: Sendable {
    var generation: @Sendable () async -> UUID
    var wallet: @Sendable (UUID) async throws -> AccountWallet
    var quote: @Sendable (Chapter, UUID) async throws -> ChapterOrderQuote
    var purchase: @Sendable (ChapterOrderQuote) async throws -> ChapterOrderReceipt

    static let live = ChapterCommerceClient(
        generation: { await SFAPI.shared.sessionGeneration() },
        wallet: { try await SFAPI.shared.wallet(expectedGeneration: $0) },
        quote: { try await SFAPI.shared.chapterOrderQuote(chapter: $0, expectedGeneration: $1) },
        purchase: { try await SFAPI.shared.purchaseChapter(quote: $0) }
    )
    static var current: ChapterCommerceClient {
        #if DEBUG
        if usesUITestFixture { return ChapterCommerceFixture.client }
        #endif
        return .live
    }
    static var usesUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--chapter-purchase-fixture")
        #else
        false
        #endif
    }
}

@MainActor @Observable
final class AccountWalletState {
    static let shared = AccountWalletState()
    private(set) var wallet: AccountWallet?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var needsLogin = false
    @ObservationIgnored private let client: ChapterCommerceClient
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var generation: UUID?

    init(client: ChapterCommerceClient = .current) { self.client = client }

    func load() async {
        let request = UUID()
        requestID = request
        loading = true
        defer { if requestID == request { loading = false } }
        let current = await client.generation()
        guard requestID == request, !Task.isCancelled else { return }
        if generation != current { wallet = nil; generation = current }
        error = nil; needsLogin = false
        do {
            let result = try await client.wallet(current)
            guard await isCurrent(request, generation: current), result.generation == current else { return }
            wallet = result
        } catch {
            guard await isCurrent(request, generation: current), !AccountShelfState.isCancellation(error) else { return }
            self.error = error.localizedDescription
            needsLogin = ChapterPurchaseViewState.isLoginError(error)
            if needsLogin { wallet = nil }
        }
    }

    private func isCurrent(_ request: UUID, generation: UUID) async -> Bool {
        let latest = await client.generation()
        guard requestID == request, !Task.isCancelled else { return false }
        if latest != generation { wallet = nil; self.generation = latest; return false }
        return true
    }
}

@MainActor @Observable
final class ChapterPurchaseViewState {
    let chapter: Chapter
    private(set) var quote: ChapterOrderQuote?
    private(set) var receipt: ChapterOrderReceipt?
    private(set) var loading = false
    private(set) var submitting = false
    private(set) var needsLogin = false
    private(set) var error: String?
    private(set) var resultPending = false
    @ObservationIgnored private let client: ChapterCommerceClient
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var usedQuoteIDs = Set<UUID>()

    init(chapter: Chapter, client: ChapterCommerceClient = .current) { self.chapter = chapter; self.client = client }

    var readableChapter: Chapter? {
        guard !resultPending else { return nil }
        let state: ChapterPurchaseState
        if let receipt, receipt.isReadabilityConfirmed { state = receipt.state }
        else if let quote, quote.state == .available || quote.state == .purchased { state = quote.state }
        else { return nil }
        guard let generation else { return nil }
        var result = chapter
        result.confirmedPurchaseState = state
        result.purchaseSessionGeneration = generation
        return result
    }

    var canRequestConfirmation: Bool {
        guard let quote, !loading, !submitting, !resultPending, !needsLogin,
              readableChapter == nil, !usedQuoteIDs.contains(quote.id) else { return false }
        return quote.canPurchase
    }

    var pendingMessage: String? {
        guard resultPending || quote?.isPending == true else { return nil }
        if let receipt, !receipt.isReadabilityConfirmed { return receipt.message }
        return "上次订阅结果待确认，请刷新章节状态或到官方核实；暂不能重复订阅。"
    }

    func load() async {
        guard !submitting else { return }
        let request = UUID()
        requestID = request
        loading = true
        defer { if requestID == request { loading = false } }
        let current = await client.generation()
        guard requestID == request, !Task.isCancelled else { return }
        prepare(generation: current)
        quote = nil; error = nil; needsLogin = false
        do {
            let result = try await client.quote(chapter, current)
            guard await isCurrent(request, generation: current) else { return }
            guard result.generation == current, result.chapter.id == chapter.id,
                  result.chapter.bookID == chapter.bookID else { throw SFAPIError.invalidResponse }
            quote = result
            if result.state == .available || result.state == .purchased { resultPending = false }
            else if result.isPending || receipt?.isReadabilityConfirmed == true { resultPending = true }
            // An ambiguous local submission stays locked even if a stale response lacks pending.
        } catch {
            guard await isCurrent(request, generation: current), !AccountShelfState.isCancellation(error) else { return }
            self.error = error.localizedDescription
            needsLogin = Self.isLoginError(error)
        }
    }

    /// Preparing a confirmation is read-only. Its immutable quote is captured by the dialog.
    func confirmation() async -> ChapterOrderQuote? {
        guard canRequestConfirmation, let quote else { return nil }
        let current = await client.generation()
        guard current == generation, current == quote.generation else {
            prepare(generation: current)
            error = "账号已变化，请刷新后重新确认。"
            return nil
        }
        guard quote.expiresAt > Date() else {
            self.quote = nil
            error = ChapterOrderError.expiredQuote.localizedDescription
            return nil
        }
        return quote
    }

    /// Only the confirmation dialog calls this method; loading and scene changes never do.
    func confirm(_ confirmed: ChapterOrderQuote) async {
        guard canRequestConfirmation, quote?.id == confirmed.id, confirmed.expiresAt > Date() else { return }
        submitting = true
        defer { submitting = false }
        let current = await client.generation()
        guard current == generation, current == confirmed.generation else {
            prepare(generation: current)
            error = "账号已变化，请刷新后重新确认。"
            return
        }
        // Recheck after the actor hop: two taps must not both pass the initial guard.
        guard !usedQuoteIDs.contains(confirmed.id), quote?.id == confirmed.id else { return }
        usedQuoteIDs.insert(confirmed.id)
        error = nil
        let request = UUID()
        requestID = request
        do {
            let result = try await client.purchase(confirmed)
            guard await isCurrent(request, generation: current) else { return }
            guard result.chapterID == chapter.id, result.generation == current else {
                resultPending = true
                throw ChapterOrderError.resultUnknown
            }
            receipt = result
            resultPending = !result.isReadabilityConfirmed
        } catch {
            guard await isCurrent(request, generation: current) else { return }
            self.error = error.localizedDescription
            needsLogin = Self.isLoginError(error)
            switch error {
            case ChapterOrderError.resultUnknown, ChapterOrderError.pendingOrder, ChapterOrderError.duplicateSubmission:
                resultPending = true
            case is CancellationError:
                resultPending = true
                self.error = ChapterOrderError.resultUnknown.localizedDescription
            case is URLError:
                resultPending = true
                self.error = ChapterOrderError.resultUnknown.localizedDescription
            default: break // Core distinguishes a definitive rejection from an ambiguous submission.
            }
        }
    }

    func cancelReads() {
        if !submitting { requestID = UUID(); loading = false }
    }

    private func prepare(generation: UUID) {
        guard self.generation != generation else { return }
        self.generation = generation
        quote = nil; receipt = nil; error = nil; needsLogin = false; resultPending = false
        usedQuoteIDs.removeAll()
    }

    private func isCurrent(_ request: UUID, generation: UUID) async -> Bool {
        let latest = await client.generation()
        guard requestID == request else { return false }
        guard latest == generation else { prepare(generation: latest); return false }
        return !Task.isCancelled
    }

    static func isLoginError(_ error: Error) -> Bool {
        switch error {
        case SFAPIError.loginRequired, SFAPIError.authenticationRequired: true
        default: false
        }
    }
}

#if DEBUG
/// Activated only by an explicit offline UI-test argument. No closure references a live API.
private actor ChapterCommerceFixture {
    static let shared = ChapterCommerceFixture()
    static let client = ChapterCommerceClient(
        generation: { shared.generation }, wallet: { _ in await shared.wallet() },
        quote: { chapter, _ in await shared.quote(chapter) }, purchase: { await shared.purchase($0) }
    )
    let generation = UUID()
    let account = AccountProfile(id: 900_001, name: "离线测试读者", accountName: "offline-purchase-fixture")
    private var purchased = Set<Int>()
    func wallet() -> AccountWallet {
        AccountWallet(account: account, generation: generation, fireMoney: purchased.isEmpty ? 50 : 30, coupons: 30, goldCoins: 700)
    }
    func quote(_ chapter: Chapter) -> ChapterOrderQuote {
        let owned = purchased.contains(chapter.id)
        return ChapterOrderQuote(id: UUID(), chapter: chapter, account: account, generation: generation,
                                 price: owned ? 0 : 20, wallet: wallet(), state: owned ? .available : .notPurchased,
                                 expiresAt: Date().addingTimeInterval(120))
    }
    func purchase(_ quote: ChapterOrderQuote) -> ChapterOrderReceipt {
        purchased.insert(quote.chapter.id)
        return ChapterOrderReceipt(chapterID: quote.chapter.id, generation: generation, state: .available,
                                   message: "离线测试：本章已可阅读。")
    }
}
#endif
