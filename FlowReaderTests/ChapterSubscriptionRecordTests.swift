import XCTest
@testable import FlowReader

final class ChapterSubscriptionRecordTests: XCTestCase {
    private func row(chapter: Int = 10, fire: Any = 20, coupons: Any = 0, channel: Any = 0) -> [String: Any] {
        ["entityId": 42, "detailId": chapter, "consumeType": "小说订阅", "consumeFireMoney": fire,
         "consumeCoupon": coupons, "consumeChannel": channel, "sourceType": 0, "isRubbish": false,
         "consumeInfo": "原创测试章节", "consumeTime": "2026-01-01T12:00:00"]
    }

    func testPositiveFireMoneyAndCouponsProvePaidRecordsButFreeAndAdsDoNot() throws {
        let rows = [row(chapter: 10), row(chapter: 11, fire: 0, coupons: 5),
                    row(chapter: 12, fire: 0, coupons: 0), row(chapter: 13, fire: 0, channel: 1),
                    row(chapter: 14, fire: 20, channel: 1)]
        let result = try ChapterSubscriptionProtocol.parse(rows, bookID: 42)
        XCTAssertEqual(result.paidChapterIDs, [10, 11])
        XCTAssertEqual(result.rowCount, 5)
    }

    func testMissingAmountsCannotInventAPaidSubscription() throws {
        var missing = row()
        missing.removeValue(forKey: "consumeFireMoney")
        missing.removeValue(forKey: "consumeCoupon")
        let parsed = try ChapterSubscriptionProtocol.parse([missing], bookID: 42)
        XCTAssertTrue(parsed.paidChapterIDs.isEmpty)
        var explicit = missing
        explicit["consumeCoupon"] = 2
        XCTAssertEqual(try ChapterSubscriptionProtocol.parse([explicit], bookID: 42).paidChapterIDs, [10])
    }

    func testMalformedCurrencyOrIdentityCannotCreatePurchaseBadges() {
        for bad: Any in [true, -1, 0.5, "20", NSNull()] {
            XCTAssertThrowsError(try ChapterSubscriptionProtocol.parse([row(fire: bad)], bookID: 42))
            XCTAssertThrowsError(try ChapterSubscriptionProtocol.parse([row(coupons: bad)], bookID: 42))
            XCTAssertThrowsError(try ChapterSubscriptionProtocol.parse([row(channel: bad)], bookID: 42))
        }
        for (key, bad): (String, Any) in [("entityId", 43), ("entityId", "42"), ("detailId", true), ("detailId", 0),
                                         ("consumeType", "漫画订阅"), ("consumeType", NSNull())] {
            var value = row(); value[key] = bad
            XCTAssertThrowsError(try ChapterSubscriptionProtocol.parse([value], bookID: 42))
        }
        XCTAssertThrowsError(try ChapterSubscriptionProtocol.parse(["data": [row()]], bookID: 42))
    }

    func testRepeatedTransactionsDeduplicateWithoutClaimingMissingChaptersUnpurchased() throws {
        let parsed = try ChapterSubscriptionProtocol.parse([row(), row()], bookID: 42)
        XCTAssertEqual(parsed.paidChapterIDs, [10])
        XCTAssertEqual(parsed.rowCount, 2)
        let merged = ChapterPurchaseParser.merging(paidChapterIDs: parsed.paidChapterIDs,
                                                   into: [10: .available, 11: .available, 12: .unknown])
        XCTAssertEqual(merged.states, [10: .purchased, 11: .available, 12: .unknown])
    }

    func testRequestUsesTheVerifiedReadOnlySubscriptionDetailContract() async throws {
        let plan = try ChapterSubscriptionProtocol.request(bookID: 42, page: 2)
        let api = SFAPI(loadPersistedSessions: false)
        let request = try await api.appRequest(path: plan.path, query: plan.query, body: nil, includeSession: true, method: plan.method)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/user/consumes")
        XCTAssertEqual(plan.query, ["type": "chaps", "entityId": "42", "page": "2", "size": "20"])
        XCTAssertNil(request.httpBody)
        XCTAssertThrowsError(try ChapterSubscriptionProtocol.request(bookID: 0, page: 1))
        XCTAssertThrowsError(try ChapterSubscriptionProtocol.request(bookID: 42, page: 0))
        XCTAssertThrowsError(try ChapterSubscriptionProtocol.request(bookID: 42, page: 1, size: 21))
    }

    func testServerCappedShortPagesContinueUntilAnEmptyPage() async throws {
        let first = try ChapterSubscriptionProtocol.parse([row(chapter: 10)], bookID: 42)
        let second = try ChapterSubscriptionProtocol.parse([row(chapter: 11)], bookID: 42)
        let empty = try ChapterSubscriptionProtocol.parse([], bookID: 42)
        let calls = SubscriptionPageCalls()
        let result = try await ChapterSubscriptionProtocol.load(bookID: 42) { plan in
            await calls.append(plan.query["page"]!)
            switch plan.query["page"] {
            case "1": return first
            case "2": return second
            default: return empty
            }
        }
        XCTAssertEqual(result.paidChapterIDs, [10, 11])
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.notice)
        let requested = await calls.pages
        XCTAssertEqual(requested, ["1", "2", "3"], "A short response may be a server cap, not the final page")
    }

    func testMidPaginationFailureRetainsEvidenceAndReportsIncompleteHistory() async throws {
        let first = try ChapterSubscriptionProtocol.parse([row()], bookID: 42)
        let result = try await ChapterSubscriptionProtocol.load(bookID: 42) { plan in
            if plan.query["page"] == "1" { return first }
            throw SFAPIError.httpStatus(500)
        }
        XCTAssertEqual(result.paidChapterIDs, [10])
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.notice)
    }

    func testFirstPageFailureNeverClaimsThereAreNoPaidSubscriptions() async throws {
        let result = try await ChapterSubscriptionProtocol.load(bookID: 42) { _ in throw URLError(.timedOut) }
        XCTAssertTrue(result.paidChapterIDs.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.notice)
    }

    func testCancellationAndAuthenticationAreNeverConvertedIntoPartialSuccess() async {
        let errors: [Error] = [CancellationError(), URLError(.cancelled),
                              NSError(domain: "FixtureWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)]),
                              SFAPIError.loginRequired, SFAPIError.authenticationRequired("测试会话过期"),
                              SFAPIError.httpStatus(401), SFAPIError.httpStatus(403)]
        for expected in errors {
            do {
                _ = try await ChapterSubscriptionProtocol.load(bookID: 42) { _ in throw expected }
                XCTFail("Authentication and cancellation must propagate")
            } catch { XCTAssertEqual(error.localizedDescription, expected.localizedDescription) }
        }
    }

    func testRepeatedPageAndPageLimitPreventUnboundedRequestsWithoutPretendingComplete() async throws {
        let page = try ChapterSubscriptionProtocol.parse([row()], bookID: 42)
        let calls = SubscriptionPageCalls()
        let repeated = try await ChapterSubscriptionProtocol.load(bookID: 42) { plan in
            await calls.append(plan.query["page"]!); return page
        }
        XCTAssertFalse(repeated.isComplete)
        XCTAssertEqual(repeated.paidChapterIDs, [10])
        let count = await calls.pages.count
        XCTAssertEqual(count, 2)
        let limited = try await ChapterSubscriptionProtocol.load(bookID: 42, maximumPages: 1) { _ in page }
        XCTAssertFalse(limited.isComplete)
        XCTAssertNotNil(limited.notice)
    }

    func testEachPagePublishesIncrementalEvidenceAndCancellationKeepsConfirmedPages() async throws {
        let first = try ChapterSubscriptionProtocol.parse([row(chapter: 10)], bookID: 42)
        let cache = ChapterSubscriptionCache(), generation = UUID(), observed = SubscriptionProgressCalls()
        do {
            _ = try await ChapterSubscriptionProtocol.load(bookID: 42, knownPaidChapterIDs: [9], onProgress: { result in
                await cache.store(result, bookID: 42, generation: generation)
                await observed.append(result)
            }) { plan in
                if plan.query["page"] == "1" { return first }
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        let recorded = await observed.results
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.paidChapterIDs, [9, 10])
        XCTAssertFalse(recorded.first?.isComplete ?? true)
        let restored = await cache.value(bookID: 42, generation: generation)
        XCTAssertEqual(restored?.paidChapterIDs, [9, 10])
        XCTAssertFalse(restored?.isComplete ?? true)
    }

    func testIncrementalCallbacksStayIncompleteUntilTheEmptyTerminalPage() async throws {
        let first = try ChapterSubscriptionProtocol.parse([row(chapter: 10)], bookID: 42)
        let second = try ChapterSubscriptionProtocol.parse([row(chapter: 11)], bookID: 42)
        let empty = try ChapterSubscriptionProtocol.parse([], bookID: 42)
        let observed = SubscriptionProgressCalls()
        let final = try await ChapterSubscriptionProtocol.load(bookID: 42, onProgress: { result in await observed.append(result) }) { plan in
            switch plan.query["page"] {
            case "1": return first
            case "2": return second
            default: return empty
            }
        }
        let recorded = await observed.results
        XCTAssertEqual(recorded.map(\.paidChapterIDs), [[10], [10, 11]])
        XCTAssertTrue(recorded.allSatisfy { !$0.isComplete })
        XCTAssertTrue(final.isComplete)
    }

    func testRecordCacheSeparatesAccountsBooksAndRetainsPartialEvidenceUntilExpiry() async {
        let cache = ChapterSubscriptionCache(), generation = UUID(), now = Date(timeIntervalSince1970: 1_000)
        let complete = ChapterSubscriptionResult(paidChapterIDs: [10], isComplete: true, notice: nil)
        let partial = ChapterSubscriptionResult(paidChapterIDs: [11], isComplete: false, notice: "测试提示")
        await cache.store(complete, bookID: 42, generation: generation, now: now)
        await cache.store(partial, bookID: 43, generation: generation, now: now)
        let current = await cache.value(bookID: 42, generation: generation, now: now.addingTimeInterval(40))
        let retainedPartial = await cache.value(bookID: 43, generation: generation, now: now.addingTimeInterval(40))
        let expiredPartial = await cache.value(bookID: 43, generation: generation, now: now.addingTimeInterval(301))
        let wrongAccount = await cache.value(bookID: 42, generation: UUID(), now: now)
        let expiredComplete = await cache.value(bookID: 42, generation: generation, now: now.addingTimeInterval(301))
        XCTAssertEqual(current?.paidChapterIDs, [10])
        XCTAssertEqual(retainedPartial?.paidChapterIDs, [11])
        XCTAssertFalse(retainedPartial?.isComplete ?? true)
        XCTAssertNil(expiredPartial)
        XCTAssertNil(wrongAccount)
        XCTAssertNil(expiredComplete)
    }

    func testConcurrentPartialCacheUpdatesNeverEraseAlreadyConfirmedPaidEvidence() async {
        let cache = ChapterSubscriptionCache(), generation = UUID()
        await cache.store(ChapterSubscriptionResult(paidChapterIDs: [10, 11], isComplete: true, notice: nil), bookID: 42, generation: generation)
        await cache.store(ChapterSubscriptionResult(paidChapterIDs: [10, 12], isComplete: false, notice: nil), bookID: 42, generation: generation)
        let merged = await cache.value(bookID: 42, generation: generation)
        XCTAssertEqual(merged?.paidChapterIDs, [10, 11, 12])
        XCTAssertFalse(merged?.isComplete ?? true)
    }

    func testRecordCacheHasABoundAndExplicitPurchaseInvalidation() async {
        let cache = ChapterSubscriptionCache(), generation = UUID(), now = Date(timeIntervalSince1970: 1_000)
        let value = ChapterSubscriptionResult(paidChapterIDs: [10], isComplete: true, notice: nil)
        for id in 1...21 { await cache.store(value, bookID: id, generation: generation, now: now.addingTimeInterval(Double(id))) }
        let evicted = await cache.value(bookID: 1, generation: generation, now: now.addingTimeInterval(22))
        let retained = await cache.value(bookID: 21, generation: generation, now: now.addingTimeInterval(22))
        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)
        await cache.invalidate(bookID: 21, generation: generation)
        let invalidated = await cache.value(bookID: 21, generation: generation, now: now.addingTimeInterval(22))
        XCTAssertNil(invalidated)
    }

    func testPaidHistoryOnlyUpgradesMatchingCatalogEntriesAndRespectsCurrentDenials() {
        let current: [Int: ChapterPurchaseState] = [10: .available, 11: .unknown, 12: .requiresPurchase,
                                                   13: .notPurchased, 14: .purchased, 15: .available]
        let merged = ChapterPurchaseParser.merging(paidChapterIDs: [10, 11, 12, 13, 14, 99], into: current)
        XCTAssertEqual(merged.states[10], .purchased)
        XCTAssertEqual(merged.states[11], .purchased)
        XCTAssertEqual(merged.states[12], .requiresPurchase)
        XCTAssertEqual(merged.states[13], .notPurchased)
        XCTAssertEqual(merged.states[14], .purchased)
        XCTAssertEqual(merged.states[15], .available)
        XCTAssertNil(merged.states[99])
        XCTAssertEqual(merged.conflictCount, 2)
    }
}

private actor SubscriptionPageCalls {
    private(set) var pages: [String] = []
    func append(_ page: String) { pages.append(page) }
}

private actor SubscriptionProgressCalls {
    private(set) var results: [ChapterSubscriptionResult] = []
    func append(_ result: ChapterSubscriptionResult) { results.append(result) }
}
