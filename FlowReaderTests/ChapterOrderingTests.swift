import XCTest
@testable import FlowReader

final class ChapterOrderingTests: XCTestCase {
    private let generation = UUID()
    private let chapter = Chapter(id: 123, bookID: 456, volumeID: 7, volumeTitle: "测试卷", title: "原创测试章", order: 0, isVIP: true)

    private func quote(price: Int = 26, state: ChapterPurchaseState = .unknown,
                       accountID: Int = 42, generation: UUID? = nil, fire: Int? = 100,
                       coupons: Int? = 0, expiresAt: Date = Date().addingTimeInterval(120)) -> ChapterOrderQuote {
        let generation = generation ?? self.generation
        let account = AccountProfile(id: accountID, name: "原创测试读者", accountName: "fixture-\(accountID)")
        let wallet = AccountWallet(account: account, generation: generation, fireMoney: fire, coupons: coupons, goldCoins: 999)
        return ChapterOrderQuote(id: UUID(), chapter: chapter, account: account, generation: generation,
                                 price: price, wallet: wallet, state: state, expiresAt: expiresAt)
    }

    private func directory(price: Any = 26, owned: Any? = nil) -> [String: Any] {
        var row: [String: Any] = ["chapId": 123, "isVip": true, "needFireMoney": price]
        if let owned { row["has"] = owned }
        return ["novelId": 456, "volumeList": [["chapterList": [row]]]]
    }

    func testPriceRequiresUniqueChapterAndExactNonnegativeInteger() throws {
        XCTAssertEqual(try ChapterOrderProtocol.price(in: directory(), chapter: chapter).price, 26)
        for bad: Any in [true, -1, 0.5, "26", NSNull()] {
            XCTAssertThrowsError(try ChapterOrderProtocol.price(in: directory(price: bad), chapter: chapter))
        }
        for bad: Any in ["true", 1, NSNull()] {
            XCTAssertThrowsError(try ChapterOrderProtocol.price(in: directory(owned: bad), chapter: chapter))
        }
        var wrongBook = directory(); wrongBook["novelId"] = 457
        XCTAssertThrowsError(try ChapterOrderProtocol.price(in: wrongBook, chapter: chapter))
        let row: [String: Any] = ["chapId": 123, "isVip": true, "needFireMoney": 26]
        XCTAssertThrowsError(try ChapterOrderProtocol.price(in: ["volumeList": [["chapterList": [row, row]]]], chapter: chapter))
        XCTAssertThrowsError(try ChapterOrderProtocol.price(in: ["volumeList": []], chapter: chapter))
    }

    func testZeroQuoteConfirmsAccessWithoutInventingTransaction() throws {
        XCTAssertEqual(try ChapterOrderProtocol.price(in: directory(price: 0, owned: false), chapter: chapter).state, .available)
        XCTAssertEqual(try ChapterOrderProtocol.price(in: directory(price: 26, owned: true), chapter: chapter).state, .purchased)
        XCTAssertEqual(try ChapterOrderProtocol.price(in: directory(), chapter: chapter).state, .requiresPurchase)
        XCTAssertFalse(quote(price: 0, state: .available).canPurchase)
        XCTAssertFalse(quote(state: .purchased).canPurchase)
    }

    func testUnknownAndInsufficientBalancesNeverEnablePurchaseOrUseGoldCoins() {
        XCTAssertFalse(quote(fire: nil).canPurchase)
        XCTAssertFalse(quote(coupons: nil).canPurchase)
        XCTAssertFalse(quote(fire: 0, coupons: 0).canPurchase)
        XCTAssertTrue(quote(fire: 10, coupons: 16).canPurchase)
    }

    func testExactSingleChapterPOSTBodyDisablesAllAndAutomaticOrders() async throws {
        let plan = try ChapterOrderProtocol.request(for: quote())
        let api = SFAPI(loadPersistedSessions: false)
        let request = try await api.appRequest(path: plan.path, query: [:], body: plan.body, includeSession: true, method: plan.method)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "api.sfacg.com")
        XCTAssertEqual(request.url?.path, "/novels/456/orderedchaps")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["chapIds", "orderAll", "autoOrder", "orderType"])
        XCTAssertEqual(body["chapIds"] as? [Int], [123])
        XCTAssertEqual(AccountWalletParser.boolean(body["autoOrder"]), false)
        XCTAssertEqual(AccountWalletParser.boolean(body["orderAll"]), false)
        XCTAssertEqual(body["orderType"] as? String, "readOrder")
    }

    func testRefreshedAccessAvoidsDuplicatePurchase() async throws {
        let initial = quote(), readable = quote(price: 0, state: .available)
        let calls = OrderCalls()
        let receipt = try await ChapterOrderCoordinator().purchase(quote: initial, refresh: { readable },
            submit: { _ in await calls.submit() }, verify: { .unknown })
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(receipt.isReadabilityConfirmed)
        XCTAssertEqual(receipt.state, .available)
    }

    func testChangedPriceIdentityOrGenerationAndExpiredQuoteBlockPOST() async {
        let initial = quote()
        for changed in [quote(price: 27), quote(accountID: 43), quote(generation: UUID()), quote(fire: 0)] {
            let calls = OrderCalls()
            do {
                _ = try await ChapterOrderCoordinator().purchase(quote: initial, refresh: { changed },
                    submit: { _ in await calls.submit() }, verify: { .available })
                XCTFail("Changed confirmation must be rejected")
            } catch { }
            let count = await calls.count
            XCTAssertEqual(count, 0)
        }
        let expired = quote(expiresAt: .distantPast)
        do {
            _ = try await ChapterOrderCoordinator().purchase(quote: expired, refresh: { initial },
                submit: { _ in XCTFail("Expired quote submitted") }, verify: { .available })
            XCTFail("Expected expired quote")
        } catch { guard case ChapterOrderError.expiredQuote = error else { return XCTFail("Unexpected \(error)") } }
    }

    func testSuccessRequiresExplicitReadbackAndConsumesConfirmation() async throws {
        let value = quote(), gate = ChapterOrderCoordinator(), calls = OrderCalls()
        let receipt = try await gate.purchase(quote: value, refresh: { value },
            submit: { _ in await calls.submit() }, verify: { .available })
        XCTAssertTrue(receipt.isReadabilityConfirmed)
        do {
            _ = try await gate.purchase(quote: value, refresh: { value }, submit: { _ in await calls.submit() }, verify: { .available })
            XCTFail("Reusing a confirmation must never submit again")
        } catch { guard case ChapterOrderError.duplicateSubmission = error else { return XCTFail("Unexpected \(error)") } }
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testTimeoutIsUncertainAndNeverAutomaticallyRetried() async {
        let value = quote(), gate = ChapterOrderCoordinator(), calls = OrderCalls()
        do {
            _ = try await gate.purchase(quote: value, refresh: { value }, submit: { _ in
                await calls.submit(); throw URLError(.timedOut)
            }, verify: { XCTFail("Do not silently perform another operation after a transport failure"); return .unknown })
            XCTFail("Expected an uncertain outcome")
        } catch { guard case ChapterOrderError.resultUnknown = error else { return XCTFail("Unexpected \(error)") } }
        do {
            _ = try await gate.purchase(quote: value, refresh: { value }, submit: { _ in await calls.submit() }, verify: { .available })
            XCTFail("Must not replay timed-out confirmation")
        } catch { }
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testUnconfirmedReadbackDoesNotClaimPurchaseSuccess() async throws {
        let value = quote()
        let receipt = try await ChapterOrderCoordinator().purchase(quote: value, refresh: { value }, submit: { _ in },
                                                                   verify: { throw URLError(.networkConnectionLost) })
        XCTAssertEqual(receipt.state, .unknown)
        XCTAssertFalse(receipt.isReadabilityConfirmed)
        XCTAssertTrue(receipt.message.contains("尚待确认"))
    }

    func testAccountGateRejectsConcurrentDifferentQuoteBeforeSecondRefresh() async throws {
        let value = quote(), another = quote(), gate = ChapterOrderCoordinator(), latch = OrderLatch()
        let first = Task {
            try await gate.purchase(quote: value, refresh: {
                await latch.wait(); return value
            }, submit: { _ in }, verify: { .available })
        }
        await latch.waitUntilEntered()
        do {
            _ = try await gate.purchase(quote: another, refresh: { XCTFail("Second refresh must not run"); return another },
                                       submit: { _ in XCTFail("Concurrent submit") }, verify: { .available })
            XCTFail("Expected in-flight gate")
        } catch { guard case ChapterOrderError.duplicateSubmission = error else { return XCTFail("Unexpected \(error)") } }
        await latch.release()
        _ = try await first.value
    }

    func testUncertainOrderPersistsAcrossNewQuoteAndRelaunchUntilAccessConfirmed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pending.json")
        let value = quote(), first = ChapterOrderCoordinator(storageURL: file)
        do {
            _ = try await first.purchase(quote: value, refresh: { value },
                                         submit: { _ in throw URLError(.timedOut) }, verify: { .unknown })
            XCTFail("Expected uncertain result")
        } catch { }
        let relaunched = ChapterOrderCoordinator(storageURL: file)
        let pending = try await relaunched.pendingStatus(accountID: 42, chapter: chapter, state: .unknown)
        XCTAssertTrue(pending)
        let renewed = quote()
        do {
            _ = try await relaunched.purchase(quote: renewed, refresh: { renewed },
                                              submit: { _ in XCTFail("A new quote must not replay an ambiguous order") }, verify: { .available })
            XCTFail("Expected a pending-order block")
        } catch { guard case ChapterOrderError.pendingOrder = error else { return XCTFail("Unexpected \(error)") } }
        let otherAccount = try await relaunched.pendingStatus(accountID: 43, chapter: chapter, state: .unknown)
        XCTAssertFalse(otherAccount)
        let resolved = try await relaunched.pendingStatus(accountID: 42, chapter: chapter, state: .available)
        XCTAssertFalse(resolved)
        let readAgain = try await ChapterOrderCoordinator(storageURL: file).pendingStatus(accountID: 42, chapter: chapter, state: .unknown)
        XCTAssertFalse(readAgain)
    }

    func testCorruptPendingStoreStopsMutationInsteadOfForgettingPotentialCharge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pending.json")
        try Data("not valid JSON".utf8).write(to: file)
        let value = quote(), gate = ChapterOrderCoordinator(storageURL: file)
        do {
            _ = try await gate.purchase(quote: value, refresh: { value },
                                        submit: { _ in XCTFail("Unsafe persistent state must stop submission") }, verify: { .available })
            XCTFail("Expected storage error")
        } catch { guard case ChapterOrderError.storageUnavailable = error else { return XCTFail("Unexpected \(error)") } }
    }

    func testExplicitRejectionPreservesMessageAndDoesNotLeaveAnAmbiguousOrder() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["status": ["httpCode": 402, "errorCode": 402, "msg": "测试余额不足"], "data": NSNull()])
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://api.sfacg.com/novels/456/orderedchaps")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try ChapterOrderProtocol.validateSubmissionResponse(data, response: response)) { error in
            XCTAssertTrue(error is ChapterOrderRejection)
            XCTAssertEqual(error.localizedDescription, "测试余额不足")
        }
        let value = quote(), gate = ChapterOrderCoordinator()
        do {
            _ = try await gate.purchase(quote: value, refresh: { value }, submit: { _ in
                try ChapterOrderProtocol.validateSubmissionResponse(data, response: response)
            }, verify: { .unknown })
            XCTFail("Expected server rejection")
        } catch { XCTAssertTrue(error is ChapterOrderRejection) }
        let pending = try await gate.pendingStatus(accountID: 42, chapter: chapter, state: .unknown)
        XCTAssertFalse(pending)
    }

    func testServerErrorAndMalformedSuccessNeverAcknowledgePurchase() throws {
        let url = URL(string: "https://api.sfacg.com/novels/456/orderedchaps")!
        let ok = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let server = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        let failed = try JSONSerialization.data(withJSONObject: ["status": ["httpCode": 500, "errorCode": 500, "msg": "服务器暂时不可用"]])
        XCTAssertThrowsError(try ChapterOrderProtocol.validateSubmissionResponse(failed, response: server)) { error in
            XCTAssertFalse(error is ChapterOrderRejection, "5xx must retain the pending record")
        }
        XCTAssertThrowsError(try ChapterOrderProtocol.validateSubmissionResponse(Data("{\"data\":true}".utf8), response: ok))
        let accepted = try JSONSerialization.data(withJSONObject: ["status": ["httpCode": 201, "errorCode": 200], "data": NSNull()])
        XCTAssertNoThrow(try ChapterOrderProtocol.validateSubmissionResponse(accepted, response: ok))
    }

    func testTransportUncertaintyCannotBeOverriddenByInnerRejectionOrAuthentication() async throws {
        let url = URL(string: "https://api.sfacg.com/novels/456/orderedchaps")!
        for transport in [500, 408, 409] {
            for business in [400, 502] {
                let data = try JSONSerialization.data(withJSONObject: ["status": ["httpCode": 400, "errorCode": business, "msg": "测试服务响应"]])
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: transport, httpVersion: nil, headerFields: nil))
                let value = quote(), gate = ChapterOrderCoordinator()
                do {
                    _ = try await gate.purchase(quote: value, refresh: { value }, submit: { _ in
                        try ChapterOrderProtocol.validateSubmissionResponse(data, response: response)
                    }, verify: { .unknown })
                    XCTFail("Ambiguous transport cannot clear pending")
                } catch { guard case ChapterOrderError.resultUnknown = error else { return XCTFail("Unexpected \(error)") } }
                let pending = try await gate.pendingStatus(accountID: 42, chapter: chapter, state: .requiresPurchase)
                XCTAssertTrue(pending)
            }
        }
    }

    func testDefinitePreDispatchCancellationClearsPendingButDispatchedCancellationDoesNot() async throws {
        let value = quote()
        for dispatched in [false, true] {
            let gate = ChapterOrderCoordinator()
            do {
                _ = try await gate.purchase(quote: value, refresh: { value }, submit: { _ in
                    if dispatched { throw CancellationError() }
                    throw SFRequestNotSent(underlying: CancellationError())
                }, verify: { .unknown })
                XCTFail("Expected cancellation or uncertain outcome")
            } catch {
                if dispatched { XCTAssertTrue(error is ChapterOrderError) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            let pending = try await gate.pendingStatus(accountID: 42, chapter: chapter, state: .unknown)
            XCTAssertEqual(pending, dispatched)
        }
    }

    func testSendIdentifiesChangedGenerationBeforeAnyDispatch() async throws {
        let api = SFAPI(loadPersistedSessions: false)
        let request = URLRequest(url: URL(string: "https://api.sfacg.com/novels/456/orderedchaps")!)
        do {
            _ = try await api.send(request, expectedGeneration: UUID(), reportUnsentFailure: true)
            XCTFail("Changed generation must not issue a network request")
        } catch {
            let unsent = try XCTUnwrap(error as? SFRequestNotSent)
            XCTAssertTrue(unsent.underlying is CancellationError)
        }
    }

    func testMissingAppLoginStopsQuoteAndPurchaseBeforeNetwork() async {
        let api = SFAPI(loadPersistedSessions: false)
        do { _ = try await api.chapterOrderQuote(chapter: chapter); XCTFail("Requires session") }
        catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected \(error)") } }
        do { _ = try await api.purchaseChapter(quote: quote()); XCTFail("Requires session") }
        catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected \(error)") } }
    }
}

private actor OrderCalls {
    private(set) var count = 0
    func submit() { count += 1 }
}
private actor OrderLatch {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { waiting?.resume(); waiting = nil }
}
