import XCTest
@testable import FlowReader

final class SignInTests: XCTestCase {
    func testContinuousDayRequestUsesAndroidReadOnlyEndpoint() async throws {
        let api = SFAPI(loadPersistedSessions: false)
        let plan = SignInProtocol.streakRequest
        let request = try await api.appRequest(path: plan.path, query: [:], body: plan.body,
                                               includeSession: true, method: plan.method)
        XCTAssertEqual(request.url?.absoluteString, "https://api.sfacg.com/user/sign/continueDay")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
    }

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

    func testTodayStatusRequiresAnExplicitBoolean() throws {
        XCTAssertNil(try SignInProtocol.signedToday(from: ["unrecognized": true]))
        XCTAssertNil(try SignInProtocol.signedToday(from: ["isSigned": 1]))
        XCTAssertThrowsError(try SignInProtocol.signedToday(from: "login page"))
        XCTAssertEqual(try SignInProtocol.signedToday(from: ["isSigned": true]), true)
        XCTAssertEqual(try SignInProtocol.signedToday(from: ["isSigned": false]), false)
    }

    func testLegacyCalendarCollectionIsValidButDoesNotProveTodayStatus() throws {
        let calendars: [[Any]] = [[], [["date": "2026-10-30"]]]
        for payload in calendars {
            XCTAssertNil(try SignInProtocol.signedToday(from: payload))
        }
    }

    func testStreakReadsTotalContinueDaysIncludingZeroAndValuesBeyondTheCurrentWeek() throws {
        for total in [0, 42] {
            let payload = [
                "totalContinueDays": total, "seventDayContinueDays": 7,
                "currentMonthContinueDays": 12, "activityContinueDays": 4,
                "currentWeekTotalDays": 2, "nearlyContinueDays": 3
            ]
            XCTAssertEqual(try SignInProtocol.streak(from: payload), total)
        }
    }

    func testStreakRejectsMissingOrMalformedTotalsWithoutFallingBackToOtherCounts() {
        let invalid: [Any] = [
            [], NSNull(), 7, ["currentWeekTotalDays": 3],
            ["totalContinueDays": NSNull()], ["totalContinueDays": true],
            ["totalContinueDays": -1], ["totalContinueDays": 2.5],
            ["totalContinueDays": "unknown", "currentMonthContinueDays": 12]
        ]
        for payload in invalid {
            XCTAssertThrowsError(try SignInProtocol.streak(from: payload), String(describing: payload))
        }
    }

    func testStatusCombinesExplicitTodayFlagWithTotalFromTheStreakEndpoint() async throws {
        let status = try await loadStatus(today: { ["isSigned": false, "continueDays": 2] },
                                          streak: { ["totalContinueDays": 42] })
        XCTAssertEqual(status, SignInStatus(signedToday: false, consecutiveDays: 42))
    }

    func testUnknownOrUnavailableTodayStatusDoesNotHideAValidStreak() async throws {
        for total in [0, 42] {
            let expected = SignInStatus(signedToday: nil, consecutiveDays: total)
            let emptyCalendar = try await loadStatus(today: { [] }, streak: { ["totalContinueDays": total] })
            XCTAssertEqual(emptyCalendar, expected)
            let unavailable = try await loadStatus(today: { throw URLError(.timedOut) },
                                                   streak: { ["totalContinueDays": total] })
            XCTAssertEqual(unavailable, expected)
        }
    }

    func testUnavailableStreakPreservesKnownTodayWithoutBorrowingLegacyCounts() async throws {
        for signed in [false, true] {
            let today: @Sendable () -> Any = { ["isSigned": signed, "continueDays": 2] }
            let missing = try await loadStatus(today: today, streak: { ["currentWeekTotalDays": 2] })
            let unavailable = try await loadStatus(today: today, streak: { throw URLError(.timedOut) })
            let expected = SignInStatus(signedToday: signed, consecutiveDays: nil)
            XCTAssertEqual(missing, expected)
            XCTAssertEqual(unavailable, expected)
        }
    }

    func testStreakErrorIsReportedWhenNeitherReadProvidesUsableData() async {
        do {
            _ = try await loadStatus(today: { [] }, streak: { throw URLError(.timedOut) })
            XCTFail("An empty calendar cannot mask the unavailable streak")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testAuthenticationFailureOrCancellationFromEitherReadPreventsPartialResults() async {
        for failToday in [false, true] {
            for failure: Error in [SFAPIError.authenticationRequired("expired"), CancellationError()] {
                do {
                    _ = try await loadStatus(today: {
                        if failToday { throw failure }
                        return ["isSigned": true]
                    }, streak: {
                        if !failToday { throw failure }
                        return ["totalContinueDays": 3]
                    })
                    XCTFail("Cannot display partial results for an expired or changed account")
                } catch {
                    if failure is CancellationError {
                        XCTAssertTrue(error is CancellationError)
                    } else if case SFAPIError.authenticationRequired(let message) = error {
                        XCTAssertEqual(message, "expired")
                    } else {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }

    private func loadStatus(today: @escaping @Sendable () throws -> Any,
                            streak: @escaping @Sendable () throws -> Any) async throws -> SignInStatus {
        try await SignInProtocol.loadStatus { request in
            switch request.path {
            case "/user/signInfo": return try today()
            case "/user/sign/continueDay": return try streak()
            default:
                XCTFail("Unexpected sign-in request: \(request.path)")
                throw SFAPIError.invalidResponse
            }
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
