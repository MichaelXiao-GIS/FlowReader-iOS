import XCTest
@testable import FlowReader

@MainActor
final class ReadingTimeReporterTests: XCTestCase {
    func testMeasuredBatchAndExitFlushAreConsumedOnce() async {
        let fixture = ReporterFixture()
        let reporter = fixture.makeReporter()
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(59)
        await reporter.tick()
        XCTAssertTrue(fixture.sent.isEmpty)
        fixture.advance(1)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        await reporter.tick()
        XCTAssertEqual(fixture.sent.map(\.seconds), [60])
        fixture.advance(7.8)
        reporter.setActivity(nil)
        guard await waitFor({ fixture.sent.count == 2 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent.map(\.seconds), [60, 7])
        XCTAssertEqual(Set(fixture.sent.map(\.id)).count, 2)
        XCTAssertEqual(reporter.confirmationRevision, 2)
        XCTAssertFalse(reporter.isCounting)
        reporter.setActivity(nil)
        await reporter.tick()
        XCTAssertEqual(fixture.sent.count, 2)
    }

    func testBackgroundGapAndUnopenedWelfarePageDoNotAccumulateTime() async {
        let fixture = ReporterFixture()
        let reporter = fixture.makeReporter()
        await reporter.refreshSessionStatus()
        fixture.advance(600)
        await reporter.tick()
        XCTAssertTrue(fixture.sent.isEmpty)
        XCTAssertFalse(reporter.isCounting)
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(20)
        reporter.setActivity(nil)
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        fixture.advance(1_000)
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(30)
        reporter.setActivity(nil)
        guard await waitFor({ fixture.sent.count == 2 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent.map(\.seconds), [20, 30])
    }

    func testIdleDeadlineCapsLateTickAndRealInteractionResumesClock() async {
        let fixture = ReporterFixture()
        let reporter = fixture.makeReporter()
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(200)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertFalse(reporter.isCounting)
        XCTAssertEqual(fixture.sent[0].seconds, 120)
        fixture.advance(100)
        await reporter.tick()
        XCTAssertEqual(fixture.sent.count, 1)
        reporter.noteInteraction()
        XCTAssertTrue(reporter.isCounting)
        fixture.advance(15)
        reporter.setActivity(nil)
        guard await waitFor({ fixture.sent.count == 2 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent[1].seconds, 15)
    }

    func testOldTickCannotStopNewChapterAfterGenerationAwait() async {
        let fixture = ReporterFixture()
        let reporter = fixture.makeReporter()
        reporter.setActivity(fixture.context(chapterID: 611))
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.holdNextGeneration = true
        let oldTick = Task { await reporter.tick() }
        guard await waitFor({ fixture.heldGeneration != nil }) else { return }
        reporter.setActivity(fixture.context(chapterID: 612))
        guard await waitFor({ reporter.isCounting && !reporter.isVerifying }) else { return }
        fixture.releaseGeneration()
        await oldTick.value
        XCTAssertTrue(reporter.isCounting)
        XCTAssertFalse(reporter.needsLogin)
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent[0].chapterID, 612)
        reporter.setActivity(nil)
    }

    func testOldAuthorizationFinalGenerationAwaitCannotReplaceNewChapter() async {
        let fixture = ReporterFixture()
        let reporter = fixture.makeReporter()
        fixture.holdNextProfile = true
        reporter.setActivity(fixture.context(chapterID: 611))
        guard await waitFor({ fixture.heldProfile != nil }) else { return }
        fixture.holdNextGeneration = true
        fixture.releaseProfile()
        guard await waitFor({ fixture.heldGeneration != nil }) else { return }
        reporter.setActivity(fixture.context(chapterID: 612))
        guard await waitFor({ reporter.isCounting && !reporter.isVerifying }) else { return }
        fixture.releaseGeneration()
        await settleTasks()
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent[0].chapterID, 612, "A cancelled authorization cannot restore its old chapter")
        reporter.setActivity(nil)
    }

    func testOldAccountReceiptOrErrorCannotClearNewAccountOrItsQueuedTime() async {
        for oldRequestFails in [false, true] {
            let fixture = ReporterFixture()
            let reporter = fixture.makeReporter()
            reporter.setActivity(fixture.context())
            guard await waitFor({ reporter.isCounting }) else { return }
            fixture.holdNextReport = true
            fixture.advance(60)
            await reporter.tick()
            guard await waitFor({ fixture.heldReport != nil }) else { return }
            let oldGeneration = fixture.generation
            fixture.switchAccount()
            reporter.setActivity(fixture.context(chapterID: 710))
            guard await waitFor({ reporter.isCounting && !reporter.isVerifying }) else { return }
            fixture.advance(60)
            await reporter.tick()
            XCTAssertEqual(fixture.sent.count, 1, "New report waits behind the single in-flight request")
            fixture.releaseReport(failing: oldRequestFails)
            guard await waitFor({ fixture.sent.count == 2 && !reporter.isSending }) else { return }
            XCTAssertTrue(reporter.isCounting)
            XCTAssertFalse(reporter.needsLogin)
            XCTAssertEqual(fixture.sent[0].generation, oldGeneration)
            XCTAssertEqual(fixture.sent[1].generation, fixture.generation)
            XCTAssertEqual(fixture.sent[1].account.id, fixture.account.id)
            XCTAssertEqual(fixture.sent[1].seconds, 60)
            XCTAssertEqual(reporter.confirmationRevision, 1, "Only the current account's receipt is published")
            reporter.setActivity(nil)
        }
    }

    func testAccountSwitchDiscardsOldSubthresholdTimeWithoutCancellingNewAuthorization() async {
        let fixture = ReporterFixture()
        let reporter = fixture.makeReporter()
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(30)
        fixture.switchAccount()
        reporter.setActivity(fixture.context(chapterID: 710))
        guard await waitFor({ reporter.isCounting && !reporter.isVerifying }) else { return }
        XCTAssertTrue(fixture.sent.isEmpty, "Old-account time cannot be flushed after switching identity")
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent[0].account.id, fixture.account.id)
        XCTAssertEqual(fixture.sent[0].chapterID, 710)
        XCTAssertEqual(fixture.sent[0].seconds, 60)
        reporter.setActivity(nil)
    }

    func testStaleWelfareRefreshCannotStopNewAccountReading() async {
        let fixture = ReporterFixture()
        let reporter = fixture.makeReporter()
        fixture.holdNextGeneration = true
        let oldRefresh = Task { await reporter.refreshSessionStatus() }
        guard await waitFor({ fixture.heldGeneration != nil }) else { return }
        fixture.switchAccount()
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.releaseGeneration()
        await oldRefresh.value
        XCTAssertTrue(reporter.isCounting)
        XCTAssertFalse(reporter.needsLogin)
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent[0].account.id, fixture.account.id)
        reporter.setActivity(nil)
    }

    func testUncertainDeltaIsNeverReplayedAndOnlyNewReadingProducesNextReport() async {
        let fixture = ReporterFixture()
        fixture.reportMode = .unknown
        let reporter = fixture.makeReporter()
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertEqual(reporter.confirmationRevision, 0)
        XCTAssertNotNil(reporter.lastError)
        await reporter.tick()
        reporter.setActivity(nil)
        fixture.advance(600)
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        await reporter.tick()
        XCTAssertEqual(fixture.sent.count, 1)
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 2 && !reporter.isSending }) else { return }
        XCTAssertEqual(fixture.sent.map(\.seconds), [60, 60])
        XCTAssertNotEqual(fixture.sent[0].id, fixture.sent[1].id)
        reporter.setActivity(nil)
    }

    func testProfileFailureAndExpiredLoginDoNotKeepAccumulating() async {
        let fixture = ReporterFixture()
        fixture.profileFails = true
        let reporter = fixture.makeReporter()
        reporter.setActivity(fixture.context())
        guard await waitFor({ !reporter.isVerifying }) else { return }
        fixture.advance(120)
        reporter.noteInteraction()
        await reporter.tick()
        XCTAssertTrue(fixture.sent.isEmpty)
        XCTAssertTrue(reporter.needsLogin)
        XCTAssertFalse(reporter.isCounting)
        reporter.setActivity(nil)
        fixture.profileFails = false
        fixture.reportMode = .expired
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertTrue(reporter.needsLogin)
        XCTAssertFalse(reporter.isCounting)
        fixture.advance(600)
        await reporter.tick()
        XCTAssertEqual(fixture.sent.count, 1)
    }

    func testWrongReceiptCannotConfirmOrCauseRetry() async {
        let fixture = ReporterFixture()
        fixture.reportMode = .wrongReceipt
        let reporter = fixture.makeReporter()
        reporter.setActivity(fixture.context())
        guard await waitFor({ reporter.isCounting }) else { return }
        fixture.advance(60)
        await reporter.tick()
        guard await waitFor({ fixture.sent.count == 1 && !reporter.isSending }) else { return }
        XCTAssertEqual(reporter.confirmationRevision, 0)
        XCTAssertNil(reporter.lastConfirmedAt)
        XCTAssertNotNil(reporter.lastError)
        await reporter.tick()
        XCTAssertEqual(fixture.sent.count, 1)
        reporter.setActivity(nil)
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        XCTFail("Expected asynchronous test state was not reached", file: file, line: line)
        return false
    }

    private func settleTasks() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
private final class ReporterFixture {
    enum ReportMode { case normal, unknown, expired, wrongReceipt }
    var uptime: TimeInterval = 0
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var generation = UUID()
    var account = AccountProfile(id: 42, name: "原创测试读者", accountName: "fixture-reader")
    var profileFails = false
    var reportMode: ReportMode = .normal
    var sent: [ReadingTimeSubmission] = []
    var holdNextGeneration = false
    var holdNextProfile = false
    var holdNextReport = false
    var heldGeneration: (UUID, CheckedContinuation<UUID, Never>)?
    var heldProfile: (AccountProfile, CheckedContinuation<AccountProfile, Error>)?
    var heldReport: (ReadingTimeSubmission, CheckedContinuation<ReadingTimeReceipt, Error>)?

    func context(chapterID: Int = 611) -> ReadingTimeContext {
        ReadingTimeContext(generation: generation, bookID: 510, chapterID: chapterID)
    }

    func makeReporter() -> ReadingTimeReporter {
        ReadingTimeReporter(client: .init(generation: { await self.readGeneration() },
            profile: { try await self.readProfile() }, report: { try await self.send($0) }),
            automaticTicks: false, now: { self.uptime }, wallDate: { self.date })
    }

    func advance(_ seconds: TimeInterval) { uptime += seconds; date.addTimeInterval(seconds) }

    func switchAccount() {
        generation = UUID()
        account = AccountProfile(id: 43, name: "另一个测试读者", accountName: "other-fixture")
    }

    func readGeneration() async -> UUID {
        let snapshot = generation
        if holdNextGeneration {
            holdNextGeneration = false
            return await withCheckedContinuation { heldGeneration = (snapshot, $0) }
        }
        return snapshot
    }

    func readProfile() async throws -> AccountProfile {
        if profileFails { throw SFAPIError.loginRequired }
        if holdNextProfile {
            holdNextProfile = false
            return try await withCheckedThrowingContinuation { heldProfile = (account, $0) }
        }
        return account
    }

    func send(_ submission: ReadingTimeSubmission) async throws -> ReadingTimeReceipt {
        sent.append(submission)
        if holdNextReport {
            holdNextReport = false
            return try await withCheckedThrowingContinuation { heldReport = (submission, $0) }
        }
        switch reportMode {
        case .normal: return receipt(submission)
        case .unknown: throw ReadingTimeSubmissionError.resultUnknown("离线测试超时")
        case .expired: throw ReadingTimeSubmissionError.notSent(SFAPIError.loginRequired)
        case .wrongReceipt: return ReadingTimeReceipt(submissionID: UUID(), generation: submission.generation, confirmedAt: date)
        }
    }

    func releaseGeneration() {
        guard let (value, continuation) = heldGeneration else { return }
        heldGeneration = nil
        continuation.resume(returning: value)
    }

    func releaseProfile() {
        guard let (value, continuation) = heldProfile else { return }
        heldProfile = nil
        continuation.resume(returning: value)
    }

    func releaseReport(failing: Bool) {
        guard let (value, continuation) = heldReport else { return }
        heldReport = nil
        if failing { continuation.resume(throwing: ReadingTimeSubmissionError.resultUnknown("离线测试超时")) }
        else { continuation.resume(returning: receipt(value)) }
    }

    private func receipt(_ submission: ReadingTimeSubmission) -> ReadingTimeReceipt {
        ReadingTimeReceipt(submissionID: submission.id, generation: submission.generation, confirmedAt: date)
    }
}
