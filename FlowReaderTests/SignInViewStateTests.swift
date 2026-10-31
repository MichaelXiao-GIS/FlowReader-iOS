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
}
