import XCTest
@testable import FlowReader

final class ReadingTimeProtocolTests: XCTestCase {
    private func submission(seconds: Int = 73, date: String = "2026-11-01", bookID: Int = 510,
                            chapterID: Int = 611, accountID: Int = 42) -> ReadingTimeSubmission {
        ReadingTimeSubmission(id: UUID(), account: AccountProfile(id: accountID, name: "测试读者", accountName: "fixture-reader"),
                              generation: UUID(), bookID: bookID, chapterID: chapterID, seconds: seconds, readingDate: date)
    }

    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.sfacg.com/user/readingtime")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    func testAPKRequestUsesFiveFieldsAndMeasuredDeltaWithoutFixedBookOrDuration() throws {
        let value = submission()
        let plan = try ReadingTimeProtocol.request(for: value)
        XCTAssertEqual(plan.method, "PUT")
        XCTAssertEqual(plan.path, "/user/readingtime")
        XCTAssertEqual(Set(plan.body.keys), ["seconds", "readingDate", "entityType", "entityId", "chapterId"])
        XCTAssertEqual(plan.body["seconds"] as? Int, 73)
        XCTAssertEqual(plan.body["readingDate"] as? String, value.readingDate)
        XCTAssertEqual(plan.body["entityType"] as? Int, 2)
        XCTAssertEqual(plan.body["entityId"] as? Int, 510)
        XCTAssertEqual(plan.body["chapterId"] as? Int, 611)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: plan.body))
        XCTAssertEqual(try ReadingTimeProtocol.request(for: submission(seconds: 17, bookID: 810, chapterID: 912)).seconds, 17)
    }

    func testInvalidIdentityDurationAndCalendarDatesNeverFormRequests() {
        for value in [submission(seconds: 0), submission(seconds: -1), submission(seconds: 86_401),
                      submission(bookID: -1), submission(chapterID: 0), submission(accountID: 0)] {
            XCTAssertThrowsError(try ReadingTimeProtocol.request(for: value))
        }
        for date in ["", "2026-2-01", "2026-02-30", "2026-13-01", "2026-11-01T00:00:00Z", " 2026-11-01", "２０２６-11-01"] {
            XCTAssertThrowsError(try ReadingTimeProtocol.request(for: submission(date: date)))
        }
        XCTAssertNoThrow(try ReadingTimeProtocol.request(for: submission(seconds: 86_400, date: "2028-02-29")))
    }

    func testServiceDateUsesBeijingMidnightIndependentOfDeviceTimezone() throws {
        let formatter = ISO8601DateFormatter()
        let before = try XCTUnwrap(formatter.date(from: "2026-10-31T15:59:59Z"))
        let after = try XCTUnwrap(formatter.date(from: "2026-10-31T16:00:00Z"))
        XCTAssertEqual(ReadingTimeProtocol.serviceDate(for: before), "2026-10-31")
        XCTAssertEqual(ReadingTimeProtocol.serviceDate(for: after), "2026-11-01")
    }

    func testAcknowledgmentRequiresExplicitSuccessfulEnvelopeAndTransport() throws {
        for errorCode: Any in [0, 200, NSNull()] {
            let data = try JSONSerialization.data(withJSONObject: ["status": ["httpCode": 200, "errorCode": errorCode], "data": NSNull()])
            XCTAssertNoThrow(try ReadingTimeProtocol.requireAcknowledgment(data, response: response()))
            XCTAssertThrowsError(try ReadingTimeProtocol.requireAcknowledgment(data, response: response(500)))
        }
        for payload: [String: Any] in [[:], ["data": true], ["status": ["httpCode": true]],
                                       ["status": ["httpCode": 200, "errorCode": 400]],
                                       ["status": ["httpCode": 401, "msg": "需要登录"]]] {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(try ReadingTimeProtocol.requireAcknowledgment(data, response: response()))
        }
    }

    func testSuccessSubmitsOnceAndDoesNotExposeTaskCompletionOrRewards() async throws {
        let value = submission()
        let fixture = ReadingTimeFixture(value)
        let receipt = try await submit(value, fixture: fixture)
        XCTAssertEqual(receipt.submissionID, value.id)
        XCTAssertEqual(receipt.generation, value.generation)
        let counts = await fixture.counts()
        XCTAssertEqual(counts.profiles, 1)
        XCTAssertEqual(counts.sends, 1)
        XCTAssertEqual(receipt.confirmedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testChangedIdentityOrGenerationNeverDispatchesIncrement() async {
        let value = submission()
        for failure in [ReadingTimeFixture.Mode.wrongAccount, .switchDuringProfile, .profileFailure] {
            let fixture = ReadingTimeFixture(value, mode: failure)
            do { _ = try await submit(value, fixture: fixture); XCTFail("Must stop before dispatch") }
            catch { guard case ReadingTimeSubmissionError.notSent = error else { return XCTFail("Unexpected \(error)") } }
            let counts = await fixture.counts()
            XCTAssertEqual(counts.sends, 0)
        }
        let fixture = ReadingTimeFixture(value)
        do {
            _ = try await ReadingTimeProtocol.submit(value, expectedGeneration: UUID(),
                currentGeneration: { await fixture.generation }, currentAccount: { try await fixture.profile() },
                send: { try await fixture.send($0, generation: $1) })
            XCTFail("Caller generation must match")
        } catch { guard case ReadingTimeSubmissionError.notSent = error else { return XCTFail("Unexpected \(error)") } }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.profiles, 0)
        XCTAssertEqual(counts.sends, 0)
    }

    func testOnlyExplicitPreDispatchFailureIsReportedAsUnsent() async {
        let value = submission()
        let fixture = ReadingTimeFixture(value, mode: .notSent)
        do { _ = try await submit(value, fixture: fixture); XCTFail("Pre-dispatch failure") }
        catch { guard case ReadingTimeSubmissionError.notSent = error else { return XCTFail("Unexpected \(error)") } }
        for mode in [ReadingTimeFixture.Mode.timeout, .cancelled, .malformed, .switchDuringSend] {
            let fixture = ReadingTimeFixture(value, mode: mode)
            do { _ = try await submit(value, fixture: fixture); XCTFail("Cannot confirm result") }
            catch { guard case ReadingTimeSubmissionError.resultUnknown = error else { return XCTFail("Unexpected \(error)") } }
            let counts = await fixture.counts()
            XCTAssertEqual(counts.sends, 1, "Never retry an ambiguous additive report")
        }
    }

    func testSameSubmissionIDCannotReplaySuccessOrUncertainResult() async throws {
        for mode in [ReadingTimeFixture.Mode.normal, .timeout] {
            let value = submission()
            let fixture = ReadingTimeFixture(value, mode: mode)
            let gate = ReadingTimeSubmissionGate()
            _ = try? await submit(value, fixture: fixture, gate: gate)
            do { _ = try await submit(value, fixture: fixture, gate: gate); XCTFail("Duplicate delta") }
            catch { guard case ReadingTimeSubmissionError.notSent = error else { return XCTFail("Unexpected \(error)") } }
            let counts = await fixture.counts()
            XCTAssertEqual(counts.profiles, 1)
            XCTAssertEqual(counts.sends, 1)
        }
    }

    func testMissingAppSessionCannotReachNetwork() async {
        let api = SFAPI(loadPersistedSessions: false)
        let value = ReadingTimeSubmission(id: UUID(), account: submission().account, generation: await api.sessionGeneration(),
                                         bookID: 510, chapterID: 611, seconds: 60, readingDate: "2026-11-01")
        do { _ = try await api.reportReadingTime(value); XCTFail("Login required") }
        catch {
            guard case ReadingTimeSubmissionError.notSent(let underlying) = error,
                  case SFAPIError.loginRequired = underlying else { return XCTFail("Unexpected \(error)") }
        }
    }

    private func submit(_ value: ReadingTimeSubmission, fixture: ReadingTimeFixture,
                        gate: ReadingTimeSubmissionGate = ReadingTimeSubmissionGate()) async throws -> ReadingTimeReceipt {
        try await ReadingTimeProtocol.submit(value, gate: gate, currentGeneration: { await fixture.generation },
            currentAccount: { try await fixture.profile() }, send: { try await fixture.send($0, generation: $1) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
}

private actor ReadingTimeFixture {
    enum Mode { case normal, wrongAccount, switchDuringProfile, profileFailure, notSent, timeout, cancelled, malformed, switchDuringSend }
    var generation: UUID
    let account: AccountProfile
    let mode: Mode
    var profiles = 0
    var sends = 0

    init(_ submission: ReadingTimeSubmission, mode: Mode = .normal) {
        generation = submission.generation
        account = submission.account
        self.mode = mode
    }

    func profile() throws -> AccountProfile {
        profiles += 1
        if mode == .profileFailure { throw SFAPIError.loginRequired }
        if mode == .switchDuringProfile { generation = UUID() }
        if mode == .wrongAccount { return AccountProfile(id: 43, name: "另一个测试账号", accountName: "other-fixture") }
        return account
    }

    func send(_ request: ReadingTimeProtocol.Request, generation: UUID) throws -> (Data, HTTPURLResponse) {
        sends += 1
        switch mode {
        case .notSent: throw SFRequestNotSent(underlying: CancellationError())
        case .timeout: throw URLError(.timedOut)
        case .cancelled: throw CancellationError()
        case .switchDuringSend: self.generation = UUID()
        default: break
        }
        let payload: [String: Any] = mode == .malformed ? [:] : ["status": ["httpCode": 200, "errorCode": 0], "data": NSNull()]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: URL(string: "https://api.sfacg.com" + request.path)!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!)
    }

    func counts() -> (profiles: Int, sends: Int) { (profiles, sends) }
}
