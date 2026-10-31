import Foundation
import CoreFoundation

struct ChapterPurchaseSnapshot: Sendable {
    let states: [Int: ChapterPurchaseState]
    let generation: UUID
    var ownershipRecordsComplete: Bool = false
    var notice: String? = nil
}

extension SFAPI {
    /// Combines current account prices with positive chapter subscription records. Never places an order.
    func chapterPurchaseStates(bookID: Int, forceRefresh: Bool = false,
                               onCurrentPermissions: (@Sendable (ChapterPurchaseSnapshot) async -> Void)? = nil) async throws -> ChapterPurchaseSnapshot {
        guard bookID > 0 else { throw SFAPIError.invalidIdentifier }
        let generation = sessionGeneration()
        let verified = verifiedReadableChapterStates(bookID: bookID, generation: generation)
        guard hasAppSession() else {
            guard !verified.isEmpty else { throw SFAPIError.server("连接同一账号的账号服务后，可确认章节购买状态。") }
            return ChapterPurchaseSnapshot(states: verified, generation: generation)
        }
        _ = try await accountServiceProfile()
        // Purchase facts belong to the primary App account; optional Web authorization is
        // checked separately when opening a paid chapter, not when reading this catalogue.
        let request = try appRequest(path: "/novels/\(bookID)/dirs", query: [:], body: nil, includeSession: true, method: "GET")
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        let payload = try Self.parseAppResponse(data, response: response)
        let fresh = try ChapterPurchaseParser.states(from: payload)
        let readable = ChapterPurchaseParser.merging(verified: verified, into: fresh)
        let cached = await ChapterSubscriptionCache.shared.value(bookID: bookID, generation: generation)
        guard sessionGeneration() == generation else { throw CancellationError() }
        // Publish current reading access before walking purchase history. Long novels never
        // need to wait for all subscription pages before their directory shows usable states.
        if let onCurrentPermissions {
            let initialStates = cached.map { ChapterPurchaseParser.merging(paidChapterIDs: $0.paidChapterIDs, into: readable).states } ?? readable
            await onCurrentPermissions(ChapterPurchaseSnapshot(states: initialStates, generation: generation))
            try Task.checkCancellation()
            guard sessionGeneration() == generation else { throw CancellationError() }
        }
        let records: ChapterSubscriptionResult
        if !forceRefresh, let cached, cached.isComplete {
            records = cached
        } else {
            records = try await ChapterSubscriptionProtocol.load(bookID: bookID, knownPaidChapterIDs: cached?.paidChapterIDs ?? [], onProgress: { progress in
                guard await self.sessionGeneration() == generation else { return }
                await ChapterSubscriptionCache.shared.store(progress, bookID: bookID, generation: generation)
                if let onCurrentPermissions {
                    let merged = ChapterPurchaseParser.merging(paidChapterIDs: progress.paidChapterIDs, into: readable)
                    await onCurrentPermissions(ChapterPurchaseSnapshot(states: merged.states, generation: generation))
                }
            }) { plan in
                let payload = try await self.orderPayload(path: plan.path, query: plan.query, method: plan.method, generation: generation)
                return try ChapterSubscriptionProtocol.parse(payload, bookID: bookID)
            }
            guard sessionGeneration() == generation else { throw CancellationError() }
            await ChapterSubscriptionCache.shared.store(records, bookID: bookID, generation: generation)
        }
        try Task.checkCancellation()
        guard sessionGeneration() == generation else { throw CancellationError() }
        let merged = ChapterPurchaseParser.merging(paidChapterIDs: records.paidChapterIDs, into: readable)
        let conflictNotice = merged.conflictCount > 0 ? "部分历史付费记录与当前阅读权限不一致，这些章节以官方当前权限为准。" : nil
        let notice = [records.notice, conflictNotice].compactMap { $0 }.joined(separator: "\n")
        return ChapterPurchaseSnapshot(states: merged.states, generation: generation,
                                       ownershipRecordsComplete: records.isComplete,
                                       notice: notice.isEmpty ? nil : notice)
    }
}

enum ChapterPurchaseParser {
    /// A past successful read only fills unknown entries. Current server permissions win,
    /// including a promotion that has ended or a now-positive subscription price.
    static func merging(verified: [Int: ChapterPurchaseState], into fresh: [Int: ChapterPurchaseState]) -> [Int: ChapterPurchaseState] {
        var result = fresh
        for (id, state) in verified where result[id] == nil || result[id] == .unknown { result[id] = state }
        return result
    }

    struct PaidMerge: Sendable {
        let states: [Int: ChapterPurchaseState]
        let conflictCount: Int
    }

    /// Never treat absence from history as proof of non-purchase. Only chapters in this
    /// authenticated catalogue can receive a purchase badge, and current denials still win.
    static func merging(paidChapterIDs: Set<Int>, into fresh: [Int: ChapterPurchaseState]) -> PaidMerge {
        var states = fresh
        var conflicts = 0
        for id in paidChapterIDs {
            switch states[id] {
            case .available, .unknown: states[id] = .purchased
            case .requiresPurchase, .notPurchased: conflicts += 1
            case .purchased, nil: break
            }
        }
        return PaidMerge(states: states, conflictCount: conflicts)
    }

    static func states(from payload: Any) throws -> [Int: ChapterPurchaseState] {
        guard let root = payload as? [String: Any],
              let volumes = (root["volumeList"] ?? root["volumes"]) as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var result: [Int: ChapterPurchaseState] = [:]
        for volume in volumes {
            for row in volume["chapterList"] as? [[String: Any]] ?? [] {
                guard let id = positiveInteger(row["chapId"]), boolean(row["isVip"]) == true else { continue }
                let ownership = boolean(row["has"])
                if ownership == true { result[id] = .purchased }
                // A zero account quote confirms readability, not the transaction that granted it.
                else if nonnegativePrice(row["needFireMoney"]) == 0 { result[id] = .available }
                else if ownership == false { result[id] = .notPurchased }
                else if ownership == nil, row["has"] == nil, let price = nonnegativePrice(row["needFireMoney"]), price > 0 { result[id] = .requiresPurchase }
                else { result[id] = .unknown }
            }
        }
        return result
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let integer = Int(exactly: number.doubleValue), integer > 0 { return integer }
        if let text = value as? String, let integer = Int(text), integer > 0 { return integer }
        return nil
    }

    private static func nonnegativePrice(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue), integer >= 0 else { return nil }
        return integer
    }
}
