import XCTest
@testable import FlowReader

@MainActor final class ChapterPurchaseViewStateTests: XCTestCase {
    private let chapter = Chapter(id: 72, bookID: 18, volumeID: 1, volumeTitle: "正文", title: "离线测试章节", order: 0, isVIP: true)

    func testLoadingAndCancellingConfirmationNeverSubmitsAnOrder() async throws {
        let service = CommerceTestService()
        let state = ChapterPurchaseViewState(chapter: chapter, client: service.client)
        await state.load()
        let confirmation = await state.confirmation()
        XCTAssertNotNil(confirmation)
        // Dismissing the dialog does not call confirm(). Opening it again remains read-only.
        _ = await state.confirmation()
        await state.load()
        let count = await service.purchaseCount
        XCTAssertEqual(count, 0)
    }

    func testTwoConfirmationsSubmitOnceAndReceiptSurvivesFailedRefresh() async throws {
        let service = CommerceTestService()
        let state = ChapterPurchaseViewState(chapter: chapter, client: service.client)
        await state.load()
        let prepared = await state.confirmation()
        let quote = try XCTUnwrap(prepared)
        async let first: Void = state.confirm(quote)
        async let second: Void = state.confirm(quote)
        _ = await (first, second)
        let count = await service.purchaseCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(state.readableChapter?.id, chapter.id)
        XCTAssertFalse(state.canRequestConfirmation)
        await service.failReadback()
        await state.load()
        XCTAssertNotNil(state.readableChapter, "A failed follow-up read must not undo the confirmed receipt")
        XCTAssertFalse(state.canRequestConfirmation)
    }

    func testPendingResultCannotResubmitAfterStaleRefreshOrReopening() async throws {
        let service = CommerceTestService()
        await service.usePendingReceipt()
        let state = ChapterPurchaseViewState(chapter: chapter, client: service.client)
        await state.load()
        let prepared = await state.confirmation()
        await state.confirm(try XCTUnwrap(prepared))
        XCTAssertTrue(state.resultPending)
        XCTAssertNil(state.readableChapter)
        let reopened = ChapterPurchaseViewState(chapter: chapter, client: service.client)
        await reopened.load()
        XCTAssertFalse(reopened.canRequestConfirmation, "Core pending status also blocks a new sheet")
        await service.returnStaleNonPendingQuote()
        await state.load()
        XCTAssertTrue(state.resultPending)
        XCTAssertFalse(state.canRequestConfirmation)
        await service.confirmReadable()
        await state.load()
        XCTAssertNotNil(state.readableChapter)
        XCTAssertFalse(state.resultPending)
        let count = await service.purchaseCount
        XCTAssertEqual(count, 1, "Only the explicit confirmation may call the mutation")
    }

    func testAccountSwitchInvalidatesPreparedConfirmationBeforePurchase() async throws {
        let service = CommerceTestService()
        let state = ChapterPurchaseViewState(chapter: chapter, client: service.client)
        await state.load()
        let prepared = await state.confirmation()
        let quote = try XCTUnwrap(prepared)
        await service.changeAccount()
        await state.confirm(quote)
        let count = await service.purchaseCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(state.quote)
        XCTAssertNil(state.receipt)
        XCTAssertFalse(state.canRequestConfirmation)
    }

    func testPriceChangeRequiresFreshQuoteAndAnotherConfirmation() async throws {
        let service = CommerceTestService()
        let state = ChapterPurchaseViewState(chapter: chapter, client: service.client)
        await state.load()
        let prepared = await state.confirmation()
        let quote = try XCTUnwrap(prepared)
        await service.changePrice()
        await state.confirm(quote)
        XCTAssertFalse(state.canRequestConfirmation)
        XCTAssertNil(state.readableChapter)
        await state.load()
        XCTAssertEqual(state.quote?.price, 40)
        XCTAssertTrue(state.canRequestConfirmation)
        let count = await service.purchaseCount
        XCTAssertEqual(count, 1, "Refreshing the changed quote must not submit it")
    }

    func testWalletAccountSwitchClearsOldBalanceEvenWhenNewReadFails() async throws {
        let service = CommerceTestService()
        let state = AccountWalletState(client: service.client)
        await state.load()
        XCTAssertEqual(state.wallet?.fireMoney, 50)
        await service.changeAccount()
        await service.failReadback()
        await state.load()
        XCTAssertNil(state.wallet)
        XCTAssertNotNil(state.error)
    }

    func testFreshContradictoryQuoteDoesNotReuseSuccessOrPermitAnotherPurchase() async throws {
        let service = CommerceTestService()
        let state = ChapterPurchaseViewState(chapter: chapter, client: service.client)
        await state.load()
        let prepared = await state.confirmation()
        await state.confirm(try XCTUnwrap(prepared))
        XCTAssertNotNil(state.readableChapter)
        await service.returnStaleNonPendingQuote()
        await state.load()
        XCTAssertTrue(state.resultPending)
        XCTAssertNil(state.readableChapter, "A contradictory fresh quote must be reconciled before opening")
        XCTAssertFalse(state.canRequestConfirmation, "The old receipt must still prevent a second charge")
    }
}

private actor CommerceTestService {
    private var generation = UUID()
    private var account = AccountProfile(id: 1, name: "测试账号一", accountName: "test-one")
    private var failReads = false
    private var pendingReceipt = false
    private var pending = false
    private var readable = false
    private var price = 20
    private(set) var purchaseCount = 0

    nonisolated var client: ChapterCommerceClient {
        ChapterCommerceClient(generation: { await self.currentGeneration() },
                              wallet: { _ in try await self.wallet() },
                              quote: { chapter, _ in try await self.quote(chapter) },
                              purchase: { try await self.purchase($0) })
    }
    func currentGeneration() -> UUID { generation }
    func wallet() throws -> AccountWallet {
        if failReads { throw URLError(.notConnectedToInternet) }
        return AccountWallet(account: account, generation: generation, fireMoney: 50, coupons: 30, goldCoins: nil)
    }
    func quote(_ chapter: Chapter) throws -> ChapterOrderQuote {
        ChapterOrderQuote(id: UUID(), chapter: chapter, account: account, generation: generation,
                          price: readable ? 0 : price, wallet: try wallet(), state: readable ? .available : .requiresPurchase,
                          expiresAt: Date().addingTimeInterval(120), isPending: pending)
    }
    func purchase(_ quote: ChapterOrderQuote) async throws -> ChapterOrderReceipt {
        purchaseCount += 1
        guard quote.price == price else { throw ChapterOrderError.changedQuote }
        try await Task.sleep(for: .milliseconds(20))
        pending = pendingReceipt
        readable = !pendingReceipt
        return ChapterOrderReceipt(chapterID: quote.chapter.id, generation: generation,
                                   state: pendingReceipt ? .unknown : .available,
                                   message: pendingReceipt ? "结果待确认" : "本章已可阅读")
    }
    func usePendingReceipt() { pendingReceipt = true }
    func returnStaleNonPendingQuote() { pending = false; readable = false }
    func confirmReadable() { readable = true; pending = false }
    func failReadback() { failReads = true }
    func changePrice() { price = 40 }
    func changeAccount() { generation = UUID(); account = AccountProfile(id: 2, name: "测试账号二", accountName: "test-two") }
}
