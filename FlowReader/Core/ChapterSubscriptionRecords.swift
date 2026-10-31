import Foundation
import CryptoKit

struct ChapterSubscriptionPage: Sendable {
    let paidChapterIDs: Set<Int>
    let rowCount: Int
    let fingerprint: String
}

struct ChapterSubscriptionResult: Sendable {
    let paidChapterIDs: Set<Int>
    let isComplete: Bool
    let notice: String?
}

/// The official Android subscription-detail screen reads AccountApi.getUserConsumesDetail
/// with type=chaps and entityId=novelId. A consumption row's detailId opens that chapter.
/// Only explicit positive currency consumption establishes a paid purchase; zero-cost and
/// advertisement unlock records must not turn a promotion into a purchase badge.
enum ChapterSubscriptionProtocol {
    struct Request: Equatable, Sendable {
        let path = "/user/consumes"
        let method = "GET"
        let query: [String: String]
    }

    static func request(bookID: Int, page: Int, size: Int = 20) throws -> Request {
        guard bookID > 0, page > 0, size > 0, size <= 20 else { throw SFAPIError.invalidIdentifier }
        return Request(query: ["type": "chaps", "entityId": String(bookID), "page": String(page), "size": String(size)])
    }

    static func parse(_ payload: Any, bookID: Int) throws -> ChapterSubscriptionPage {
        guard bookID > 0, let rows = payload as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var paid = Set<Int>()
        for row in rows {
            guard row["consumeType"] as? String == "小说订阅" else { throw SFAPIError.invalidResponse }
            guard AccountWalletParser.nonnegativeInteger(row["entityId"]) == bookID,
                  let chapterID = AccountWalletParser.nonnegativeInteger(row["detailId"]), chapterID > 0 else {
                throw SFAPIError.invalidResponse
            }
            let fire = AccountWalletParser.nonnegativeInteger(row["consumeFireMoney"])
            let coupons = AccountWalletParser.nonnegativeInteger(row["consumeCoupon"])
            if row["consumeFireMoney"] != nil, fire == nil { throw SFAPIError.invalidResponse }
            if row["consumeCoupon"] != nil, coupons == nil { throw SFAPIError.invalidResponse }
            let channel = AccountWalletParser.nonnegativeInteger(row["consumeChannel"])
            if row["consumeChannel"] != nil, channel == nil { throw SFAPIError.invalidResponse }
            // Channel 1 is separately rendered as an advertisement unlock by the official UI.
            guard channel != 1, (fire ?? 0) > 0 || (coupons ?? 0) > 0 else { continue }
            paid.insert(chapterID)
        }
        let encoded = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return ChapterSubscriptionPage(paidChapterIDs: paid, rowCount: rows.count, fingerprint: fingerprint)
    }

    /// The service may cap a requested page size. Only an empty page proves completion.
    /// Failed/repeated/limited pages retain confirmed records without inventing a complete list.
    static func load(bookID: Int, maximumPages: Int = 200, knownPaidChapterIDs: Set<Int> = [],
                     onProgress: (@Sendable (ChapterSubscriptionResult) async -> Void)? = nil,
                     fetch: @Sendable (Request) async throws -> ChapterSubscriptionPage) async throws -> ChapterSubscriptionResult {
        guard bookID > 0, maximumPages > 0 else { throw SFAPIError.invalidIdentifier }
        var paid = knownPaidChapterIDs
        var fingerprints = Set<String>()
        for page in 1...maximumPages {
            try Task.checkCancellation()
            do {
                let result = try await fetch(request(bookID: bookID, page: page))
                try Task.checkCancellation()
                if result.rowCount == 0 {
                    return ChapterSubscriptionResult(paidChapterIDs: paid, isComplete: true, notice: nil)
                }
                guard fingerprints.insert(result.fingerprint).inserted else {
                    return incomplete(paid)
                }
                paid.formUnion(result.paidChapterIDs)
                if let onProgress {
                    await onProgress(ChapterSubscriptionResult(paidChapterIDs: paid, isComplete: false, notice: nil))
                    try Task.checkCancellation()
                }
            } catch {
                if Task.isCancelled || isCancellation(error) { throw error }
                if let apiError = error as? SFAPIError {
                    switch apiError {
                    case .loginRequired, .authenticationRequired: throw apiError
                    case .httpStatus(let code) where code == 401 || code == 403: throw apiError
                    default: break
                    }
                }
                return incomplete(paid)
            }
        }
        return incomplete(paid)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isCancellation(underlying) }
        return false
    }

    private static func incomplete(_ paid: Set<Int>) -> ChapterSubscriptionResult {
        ChapterSubscriptionResult(paidChapterIDs: paid, isComplete: false,
                                  notice: "部分订阅记录暂未确认，已确认的付费章节仍会显示；其他章节按当前阅读权限标记。")
    }
}

/// Purchase evidence stays in memory and is scoped to the current session generation.
/// Current directory prices are still fetched on every lookup; this cache cannot hide a new denial.
actor ChapterSubscriptionCache {
    static let shared = ChapterSubscriptionCache()
    private struct Key: Hashable { let bookID: Int; let generation: UUID }
    private struct Entry { let result: ChapterSubscriptionResult; let storedAt: Date }
    private var entries: [Key: Entry] = [:]

    func value(bookID: Int, generation: UUID, now: Date = Date()) -> ChapterSubscriptionResult? {
        let key = Key(bookID: bookID, generation: generation)
        guard let entry = entries[key] else { return nil }
        let lifetime: TimeInterval = 300
        guard now.timeIntervalSince(entry.storedAt) < lifetime else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.result
    }

    func store(_ result: ChapterSubscriptionResult, bookID: Int, generation: UUID, now: Date = Date()) {
        let key = Key(bookID: bookID, generation: generation)
        let accumulated = (entries[key]?.result.paidChapterIDs ?? []).union(result.paidChapterIDs)
        let combined = ChapterSubscriptionResult(paidChapterIDs: accumulated, isComplete: result.isComplete, notice: result.notice)
        entries[key] = Entry(result: combined, storedAt: now)
        while entries.count > 20, let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    func invalidate(bookID: Int, generation: UUID) {
        entries.removeValue(forKey: Key(bookID: bookID, generation: generation))
    }
}
