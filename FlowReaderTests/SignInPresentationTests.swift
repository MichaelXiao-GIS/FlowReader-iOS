import XCTest
@testable import FlowReader

final class SignInPresentationTests: XCTestCase {
    func testUnavailableStatusDoesNotClaimSignedOrUnsigned() {
        XCTAssertEqual(SignInPresentation.statusText(status: nil, receipt: nil), "今日签到状态暂未提供")
        XCTAssertEqual(SignInPresentation.statusText(status: SignInStatus(signedToday: nil, consecutiveDays: nil), receipt: nil), "今日签到状态暂未提供")
    }

    func testOnlyExplicitServerStatusDescribesToday() {
        XCTAssertEqual(SignInPresentation.statusText(status: SignInStatus(signedToday: true, consecutiveDays: nil), receipt: nil), "今日已签到")
        XCTAssertEqual(SignInPresentation.statusText(status: SignInStatus(signedToday: false, consecutiveDays: nil), receipt: nil), "今日尚未签到")
    }

    func testConfirmedActionReceiptTakesPrecedenceOverEarlierStatus() {
        let before = SignInStatus(signedToday: false, consecutiveDays: nil)
        XCTAssertEqual(SignInPresentation.statusText(status: before, receipt: SignInReceipt(alreadySigned: false, rewards: [])), "签到完成")
        XCTAssertEqual(SignInPresentation.statusText(status: before, receipt: SignInReceipt(alreadySigned: true, rewards: [])), "今日已签到")
    }
}
