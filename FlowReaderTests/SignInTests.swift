import XCTest
@testable import FlowReader

final class SignInTests: XCTestCase {
    func testStatusIsReadOnlyAndSubmissionUsesServiceDayInUTCPlusEight() throws {
        XCTAssertEqual(SignInProtocol.statusRequest.path, "/user/signInfo")
        XCTAssertEqual(SignInProtocol.statusRequest.method, "GET")
        XCTAssertNil(SignInProtocol.statusRequest.body)
        let formatter = ISO8601DateFormatter()
        let before = try XCTUnwrap(formatter.date(from: "2026-10-30T15:59:59Z"))
        let after = try XCTUnwrap(formatter.date(from: "2026-10-30T16:00:00Z"))
        XCTAssertEqual(SignInProtocol.submission(at: before).body, ["signDate": "2026-10-30"])
        XCTAssertEqual(SignInProtocol.submission(at: after).body, ["signDate": "2026-10-31"])
        XCTAssertEqual(SignInProtocol.submission(at: after).path, "/user/newSignInfo")
        XCTAssertEqual(SignInProtocol.submission(at: after).method, "PUT")
    }

    func testRequestBuilderPreservesPUTAndDateJSON() async throws {
        let api = SFAPI(loadPersistedSessions: false)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-30T16:00:00Z"))
        let plan = SignInProtocol.submission(at: date)
        let request = try await api.appRequest(path: plan.path, query: [:], body: plan.body, includeSession: true, method: plan.method)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.sfacg.com/user/newSignInfo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["signDate": "2026-10-31"])
    }

    func testStatusAndSubmissionRejectMissingAppSessionBeforeNetwork() async {
        let api = SFAPI(loadPersistedSessions: false)
        do {
            _ = try await api.signInStatus()
            XCTFail("Status requires an App session")
        } catch {
            guard case SFAPIError.loginRequired = error else { return XCTFail("Wrong error: \(error)") }
        }
        do {
            _ = try await api.signInToday()
            XCTFail("Submission requires an App session")
        } catch {
            guard case SFAPIError.loginRequired = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testUnknownStatusDoesNotBecomeNotSignedOrZeroDays() throws {
        let unknown = try SignInProtocol.status(from: ["unrecognized": true])
        XCTAssertNil(unknown.signedToday)
        XCTAssertNil(unknown.consecutiveDays)
        let invalid = try SignInProtocol.status(from: ["isSigned": 1, "continueDays": false])
        XCTAssertNil(invalid.signedToday)
        XCTAssertNil(invalid.consecutiveDays)
        XCTAssertThrowsError(try SignInProtocol.status(from: "login page"))
        let known = try SignInProtocol.status(from: ["isSigned": true, "continueDays": 3])
        XCTAssertEqual(known.signedToday, true)
        XCTAssertEqual(known.consecutiveDays, 3)
    }

    func testLegacyCalendarCollectionIsValidButDoesNotProveTodayStatus() throws {
        let calendars: [[Any]] = [[], [["date": "2026-10-30"]]]
        for payload in calendars {
            let status = try SignInProtocol.status(from: payload)
            XCTAssertNil(status.signedToday)
            XCTAssertNil(status.consecutiveDays)
        }
    }

    func testRewardsOnlyDisplayConfirmedNamesAndWholeQuantities() {
        let receipt = SignInProtocol.receipt(from: [["name": "代币", "num": 5], ["name": "无效", "num": true], ["name": "缺少数量"], ["name": "代币", "num": "2"]])
        XCTAssertFalse(receipt.alreadySigned)
        XCTAssertEqual(receipt.rewards.map(\.quantity), [5, 2])
        XCTAssertEqual(Set(receipt.rewards.map(\.id)).count, 2)
        XCTAssertTrue(SignInProtocol.receipt(from: []).rewards.isEmpty)
    }

    func testOnlyExplicitAlreadySignedResponseCountsAsAlreadySigned() {
        XCTAssertTrue(SignInProtocol.isAlreadySignedError(SFAPIError.server("该日期已签到，请重新确认并提交")))
        XCTAssertFalse(SignInProtocol.isAlreadySignedError(SFAPIError.server("请先完成验证码")))
        XCTAssertFalse(SignInProtocol.isAlreadySignedError(SFAPIError.authenticationRequired("今日已签到状态需要登录后查询")))
        XCTAssertFalse(SignInProtocol.isAlreadySignedError(URLError(.timedOut)))
    }
}
