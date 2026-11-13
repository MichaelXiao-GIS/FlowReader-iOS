import XCTest
@testable import FlowReader

final class SignInViewStateTests: XCTestCase {
    func testConfirmedSignInIsNotReplacedByOptionalDetailsFailure() {
        var state = SignInViewState()
        state.prepare(generation: UUID(), serviceDay: "2026-10-31")
        state.confirmed(SignInReceipt(alreadySigned: true, rewards: []))
        state.failedStatus(SFAPIError.invalidResponse)
        XCTAssertTrue(state.hasSigned)
        XCTAssertNil(state.visibleError)
        XCTAssertNotNil(state.detailsNotice)
        XCTAssertEqual(state.receipt?.alreadySigned, true)
    }

    func testActualSubmissionFailureRemainsVisibleAndRetryCanConfirm() {
        var state = SignInViewState()
        state.prepare(generation: UUID(), serviceDay: "2026-10-31")
        state.failedAction(URLError(.timedOut))
        XCTAssertFalse(state.hasSigned)
        XCTAssertNotNil(state.visibleError)
        XCTAssertNil(state.detailsNotice)
        state.beginAction()
        state.confirmed(SignInReceipt(alreadySigned: false, rewards: []))
        XCTAssertTrue(state.hasSigned)
        XCTAssertNil(state.visibleError)
    }

    func testConfirmationSurvivesRefreshOnlyForSameAccountAndServiceDay() {
        var state = SignInViewState()
        let generation = UUID()
        state.prepare(generation: generation, serviceDay: "2026-10-31")
        state.confirmed(SignInReceipt(alreadySigned: false, rewards: []))
        state.prepare(generation: generation, serviceDay: "2026-10-31")
        XCTAssertTrue(state.hasSigned)
        state.prepare(generation: UUID(), serviceDay: "2026-10-31")
        XCTAssertFalse(state.hasSigned)
        state.confirmed(SignInReceipt(alreadySigned: false, rewards: []))
        state.prepare(generation: generation, serviceDay: "2026-11-01")
        XCTAssertFalse(state.hasSigned)
    }

    func testStatusRecoveryClearsDetailsNotice() {
        var state = SignInViewState()
        state.prepare(generation: UUID(), serviceDay: "2026-10-31")
        state.loaded(SignInStatus(signedToday: true, consecutiveDays: nil))
        state.failedStatus(SFAPIError.invalidResponse)
        XCTAssertNotNil(state.detailsNotice)
        state.loaded(SignInStatus(signedToday: true, consecutiveDays: 3))
        XCTAssertNil(state.detailsNotice)
        XCTAssertEqual(state.status?.consecutiveDays, 3)
    }

    func testStreakAfterSigningComesFromStatusReadbackAndSurvivesReceiptRestoration() {
        var state = SignInViewState()
        let generation = UUID()
        state.prepare(generation: generation, serviceDay: "2026-11-13")
        state.loaded(SignInStatus(signedToday: false, consecutiveDays: 6))
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "6 天")

        let receipt = SignInReceipt(alreadySigned: false, rewards: [.init(id: "gift", name: "测试奖励", quantity: 1)])
        state.confirmed(receipt)
        XCTAssertEqual(state.consecutiveDaysText(isLoading: true), "正在读取")
        state.failedStatus(URLError(.timedOut))
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "暂未获取")
        XCTAssertTrue(state.hasSigned)
        state.prepare(generation: generation, serviceDay: "2026-11-13")
        state.restoreConfirmedDay()
        state.loaded(SignInStatus(signedToday: nil, consecutiveDays: 9))
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "9 天")
        XCTAssertEqual(state.receipt, receipt)
    }

    func testStreakDistinguishesUnknownAndZeroAndClearsWhenAccountOrDayChanges() {
        var state = SignInViewState()
        let first = UUID(), second = UUID()
        state.prepare(generation: first, serviceDay: "2026-11-13")
        state.loaded(SignInStatus(signedToday: nil, consecutiveDays: 0))
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "0 天")
        XCTAssertFalse(state.hasSigned)
        state.failedStatus(URLError(.timedOut))
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "上次读取为 0 天")
        state.prepare(generation: second, serviceDay: "2026-11-13")
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "暂未获取")
        state.loaded(SignInStatus(signedToday: nil, consecutiveDays: 12))
        XCTAssertFalse(state.hasSigned)
        state.prepare(generation: second, serviceDay: "2026-11-14")
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "暂未获取")
        state.loaded(SignInStatus(signedToday: true, consecutiveDays: nil))
        XCTAssertTrue(state.hasSigned)
        XCTAssertEqual(state.consecutiveDaysText(isLoading: false), "暂未获取")
    }
}
