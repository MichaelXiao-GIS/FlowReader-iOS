import Foundation

struct ChapterOrderQuote: Identifiable, Equatable, Sendable {
    let id: UUID
    let chapter: Chapter
    let account: AccountProfile
    let generation: UUID
    let price: Int
    let wallet: AccountWallet
    let state: ChapterPurchaseState
    let expiresAt: Date
    var isPending: Bool = false

    var canPurchase: Bool {
        !isPending && price > 0 && state != .available && state != .purchased &&
        wallet.generation == generation && account.matchesAccountIdentity(wallet.account) &&
        (wallet.subscriptionBalance.map { $0 >= price } ?? false)
    }
}

struct ChapterOrderReceipt: Equatable, Sendable {
    let chapterID: Int
    let generation: UUID
    let state: ChapterPurchaseState
    let message: String
    var isReadabilityConfirmed: Bool { state == .available || state == .purchased }
}

enum ChapterOrderError: LocalizedError {
    case expiredQuote, changedQuote, insufficientBalance, unconfirmedBalance, duplicateSubmission, resultUnknown, pendingOrder, storageUnavailable
    var errorDescription: String? {
        switch self {
        case .expiredQuote: return "本次报价已过期，请刷新价格后重新确认。"
        case .changedQuote: return "账号或章节价格已发生变化，请重新查看报价后确认。"
        case .insufficientBalance: return "火券与代券余额不足，请前往菠萝包官方渠道充值后刷新。"
        case .unconfirmedBalance: return "暂未确认完整余额，无法安全提交订阅，请刷新后重试。"
        case .duplicateSubmission: return "本次订阅已提交或正在处理，请先刷新章节状态，不要重复提交。"
        case .pendingOrder: return "本章上次订阅结果尚未确认。请刷新状态，或在菠萝包官方核实订单；为避免重复扣款，暂不能再次提交。"
        case .storageUnavailable: return "无法安全保存订阅状态，暂不能提交。请检查设备存储空间后重试。"
        case .resultUnknown: return "订阅结果暂未确认，可能已扣款。请先刷新章节状态和余额，确认后再操作；本次请求不会自动重试。"
        }
    }
}

extension SFAPI {
    func chapterOrderQuote(chapter: Chapter, expectedGeneration: UUID? = nil) async throws -> ChapterOrderQuote {
        guard chapter.id > 0, chapter.bookID > 0 else { throw SFAPIError.invalidIdentifier }
        let generation = sessionGeneration()
        if let expectedGeneration, expectedGeneration != generation { throw CancellationError() }
        let wallet = try await wallet(expectedGeneration: generation)
        let current = try await orderChapterPrice(chapter, generation: generation)
        let pending = try await ChapterOrderCoordinator.shared.pendingStatus(accountID: wallet.account.id, chapter: chapter, state: current.state)
        guard sessionGeneration() == generation else { throw CancellationError() }
        return ChapterOrderQuote(id: UUID(), chapter: chapter, account: wallet.account, generation: generation,
                                 price: current.price, wallet: wallet, state: current.state,
                                 expiresAt: Date().addingTimeInterval(120), isPending: pending)
    }

    /// Called only after an explicit confirmation of this quote. No automatic order or retry.
    func purchaseChapter(quote: ChapterOrderQuote) async throws -> ChapterOrderReceipt {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        guard sessionGeneration() == quote.generation else { throw CancellationError() }
        // A submission can create a new paid record even if its response is interrupted.
        await ChapterSubscriptionCache.shared.invalidate(bookID: quote.chapter.bookID, generation: quote.generation)
        let receipt = try await ChapterOrderCoordinator.shared.purchase(quote: quote, refresh: {
            try await self.chapterOrderQuote(chapter: quote.chapter, expectedGeneration: quote.generation)
        }, submit: { fresh in
            let plan = try ChapterOrderProtocol.request(for: fresh)
            try await self.submitChapterOrder(plan, generation: quote.generation)
        }, verify: {
            let result = try await self.orderChapterPrice(quote.chapter, generation: quote.generation)
            return result.state
        })
        try Task.checkCancellation()
        guard sessionGeneration() == quote.generation else { throw CancellationError() }
        return receipt
    }

    private func submitChapterOrder(_ plan: ChapterOrderProtocol.Request, generation: UUID) async throws {
        let request: URLRequest
        do {
            guard hasAppSession() else { throw SFAPIError.loginRequired }
            guard sessionGeneration() == generation else { throw CancellationError() }
            request = try appRequest(path: plan.path, query: [:], body: plan.body, includeSession: true, method: plan.method)
        } catch { throw SFRequestNotSent(underlying: error) }
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation,
                                            reportUnsentFailure: true)
        try ChapterOrderProtocol.validateSubmissionResponse(data, response: response)
    }

    private func orderChapterPrice(_ chapter: Chapter, generation: UUID) async throws -> ChapterOrderProtocol.Price {
        // The authenticated directory's price was verified against an anonymous directory.
        // Do not request content or enable autoOrder while displaying a price.
        let payload = try await orderPayload(path: "/novels/\(chapter.bookID)/dirs", query: ["expand": "originNeedFireMoney"], generation: generation)
        return try ChapterOrderProtocol.price(in: payload, chapter: chapter)
    }
}

enum ChapterOrderProtocol {
    struct Price: Equatable, Sendable { let price: Int; let state: ChapterPurchaseState }
    struct Request {
        let path: String
        let method = "POST"
        let body: [String: Any]
    }

    static func price(in payload: Any, chapter: Chapter) throws -> Price {
        guard chapter.id > 0, chapter.bookID > 0,
              let root = payload as? [String: Any],
              let volumes = (root["volumeList"] ?? root["volumes"]) as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        if let rawID = root["novelId"], AccountWalletParser.nonnegativeInteger(rawID) != chapter.bookID {
            throw SFAPIError.invalidResponse
        }
        let rows = volumes.flatMap { $0["chapterList"] as? [[String: Any]] ?? [] }
            .filter { AccountWalletParser.nonnegativeInteger($0["chapId"]) == chapter.id }
        guard rows.count == 1, let row = rows.first,
              let price = AccountWalletParser.nonnegativeInteger(row["needFireMoney"]),
              let isVIP = AccountWalletParser.boolean(row["isVip"]) else { throw SFAPIError.invalidResponse }
        // A locally cached isVIP value is not authoritative, but never sell a server-free chapter.
        guard isVIP || price == 0 else { throw SFAPIError.invalidResponse }
        let owned = AccountWalletParser.boolean(row["has"])
        if row["has"] != nil, owned == nil { throw SFAPIError.invalidResponse }
        return Price(price: price, state: owned == true ? .purchased : price == 0 ? .available : owned == false ? .notPurchased : .requiresPurchase)
    }

    static func request(for quote: ChapterOrderQuote) throws -> Request {
        guard quote.chapter.id > 0, quote.chapter.bookID > 0 else { throw SFAPIError.invalidIdentifier }
        guard quote.canPurchase else { throw balanceError(for: quote) }
        // APK NovelApi.orderNovelChaps POST @Body Map, confirmed by the official reader's
        // chapIds/orderAll/autoOrder/orderType map construction and the pinned upstream client.
        // No all-book order, recurring subscription, coupon selection or membership purchase.
        return Request(path: "/novels/\(quote.chapter.bookID)/orderedchaps", body: [
            "chapIds": [quote.chapter.id], "orderAll": false, "autoOrder": false, "orderType": "readOrder"
        ])
    }

    static func validateSubmissionResponse(_ data: Data, response: HTTPURLResponse) throws {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = root?["status"] as? [String: Any]
        let apiCode = AccountWalletParser.nonnegativeInteger(status?["httpCode"])
        let rejectionCodes = (400..<500).filter { $0 != 408 && $0 != 409 }
        // Transport uncertainty takes precedence over a contradictory inner error (even auth).
        // A lost/failed server response cannot establish whether an order was committed.
        guard (200..<300).contains(response.statusCode) || rejectionCodes.contains(response.statusCode) else {
            throw ChapterOrderError.resultUnknown
        }
        if let apiCode, apiCode >= 500 || apiCode == 408 || apiCode == 409 { throw ChapterOrderError.resultUnknown }
        do { _ = try SFAPI.parseAppResponse(data, response: response) }
        catch {
            if let failure = error as? SFAPIError {
                switch failure {
                case .authenticationRequired, .loginRequired: throw failure
                default: break
                }
            }
            if rejectionCodes.contains(response.statusCode) || (apiCode.map { rejectionCodes.contains($0) } ?? false) {
                throw ChapterOrderRejection(message: error.localizedDescription)
            }
            throw error
        }
    }

    static func balanceError(for quote: ChapterOrderQuote) -> ChapterOrderError {
        quote.isPending ? .pendingOrder : quote.wallet.subscriptionBalance == nil ? .unconfirmedBalance : .insufficientBalance
    }
}

/// Serializes per-account submissions and consumes a confirmation before any network mutation.
/// Expired entries are discarded, so repeated reads do not create an unbounded history.
actor ChapterOrderCoordinator {
    static let shared = ChapterOrderCoordinator(storageURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PendingChapterOrders.json"))
    private var usedQuotes: [UUID: Date] = [:]
    private var activeAccounts = Set<Int>()
    private let storageURL: URL?
    private var pending = Set<PendingChapterOrder>()
    private var storageFailed = false

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let rows = try JSONDecoder().decode(Set<PendingChapterOrder>.self, from: Data(contentsOf: storageURL))
                guard rows.allSatisfy({ $0.accountID > 0 && $0.bookID > 0 && $0.chapterID > 0 }) else {
                    throw ChapterOrderError.storageUnavailable
                }
                pending = rows
            } catch { storageFailed = true }
        }
    }

    func pendingStatus(accountID: Int, chapter: Chapter, state: ChapterPurchaseState) throws -> Bool {
        guard !storageFailed else { throw ChapterOrderError.storageUnavailable }
        let key = PendingChapterOrder(accountID: accountID, bookID: chapter.bookID, chapterID: chapter.id)
        if state == .available || state == .purchased { try removePending(key) }
        return pending.contains(key)
    }

    private func persist(_ replacement: Set<PendingChapterOrder>) throws {
        guard !storageFailed else { throw ChapterOrderError.storageUnavailable }
        if let storageURL {
            do {
                try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(replacement).write(to: storageURL, options: .atomic)
            } catch { throw ChapterOrderError.storageUnavailable }
        }
        pending = replacement
    }

    private func removePending(_ key: PendingChapterOrder) throws {
        guard pending.contains(key) else { return }
        var replacement = pending
        replacement.remove(key)
        try persist(replacement)
    }

    func purchase(quote: ChapterOrderQuote, now: Date = Date(),
                  refresh: @Sendable () async throws -> ChapterOrderQuote,
                  submit: @Sendable (ChapterOrderQuote) async throws -> Void,
                  verify: @Sendable () async throws -> ChapterPurchaseState) async throws -> ChapterOrderReceipt {
        guard !storageFailed else { throw ChapterOrderError.storageUnavailable }
        guard quote.expiresAt > now else { throw ChapterOrderError.expiredQuote }
        let key = PendingChapterOrder(accountID: quote.account.id, bookID: quote.chapter.bookID, chapterID: quote.chapter.id)
        guard !pending.contains(key), !quote.isPending else { throw ChapterOrderError.pendingOrder }
        usedQuotes = usedQuotes.filter { $0.value > now }
        guard usedQuotes[quote.id] == nil, activeAccounts.insert(quote.account.id).inserted else {
            throw ChapterOrderError.duplicateSubmission
        }
        usedQuotes[quote.id] = quote.expiresAt
        defer { activeAccounts.remove(quote.account.id) }
        try Task.checkCancellation()
        let fresh = try await refresh()
        guard fresh.generation == quote.generation, fresh.chapter.id == quote.chapter.id,
              fresh.chapter.bookID == quote.chapter.bookID,
              fresh.account.matchesAccountIdentity(quote.account) else { throw ChapterOrderError.changedQuote }
        if fresh.state == .available || fresh.state == .purchased {
            return ChapterOrderReceipt(chapterID: quote.chapter.id, generation: quote.generation,
                                       state: fresh.state, message: "本章已可阅读，无需重复订阅。")
        }
        guard fresh.price == quote.price else { throw ChapterOrderError.changedQuote }
        guard fresh.canPurchase else { throw ChapterOrderProtocol.balanceError(for: fresh) }
        guard quote.expiresAt > Date() else { throw ChapterOrderError.expiredQuote }
        try Task.checkCancellation()
        var replacement = pending
        replacement.insert(key)
        // Atomic persistence precedes the mutation: reopening the sheet or relaunching the
        // process cannot lose an ambiguous order and submit the same chapter a second time.
        try persist(replacement)
        do { try await submit(fresh) }
        catch {
            if let unsent = error as? SFRequestNotSent {
                try removePending(key)
                throw unsent.underlying
            }
            if let rejection = error as? ChapterOrderRejection {
                try removePending(key)
                throw rejection
            }
            // Server authentication/validation rejections are definitive; transport failures
            // can occur after the order was accepted and must never be treated as safe to retry.
            if let apiError = error as? SFAPIError {
                switch apiError {
                case .authenticationRequired, .loginRequired:
                    try removePending(key)
                    throw apiError
                default: break
                }
            }
            throw ChapterOrderError.resultUnknown
        }
        // A successful envelope acknowledges submission, not a guessed purchase history.
        // Read-only verification determines whether the chapter is now available.
        let state = (try? await verify()) ?? .unknown
        if state == .available || state == .purchased { try removePending(key) }
        return ChapterOrderReceipt(chapterID: quote.chapter.id, generation: quote.generation, state: state,
                                   message: state == .available || state == .purchased ? "订阅完成，本章已可阅读。" : "订阅请求已提交，阅读权限尚待确认，请刷新章节状态和余额，不要重复订阅。")
    }
}

private struct PendingChapterOrder: Codable, Hashable {
    let accountID: Int
    let bookID: Int
    let chapterID: Int
}

struct ChapterOrderRejection: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
