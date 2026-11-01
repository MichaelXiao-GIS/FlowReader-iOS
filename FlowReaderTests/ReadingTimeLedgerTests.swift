import XCTest
@testable import FlowReader

final class ReadingTimeLedgerTests: XCTestCase {
    private let generation = UUID()
    private var start: Date { Date(timeIntervalSince1970: 1_799_049_600) }
    private func context(_ chapter: Int = 11, generation: UUID? = nil, book: Int = 1) -> ReadingTimeContext {
        ReadingTimeContext(generation: generation ?? self.generation, bookID: book, chapterID: chapter)
    }

    func testElapsedMonotonicSecondsAreIndependentOfHeartbeatCount() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(), now: 100, wallDate: start)
        ledger.sample(now: 110, wallDate: start.addingTimeInterval(10))
        ledger.sample(now: 140, wallDate: start.addingTimeInterval(40))
        XCTAssertEqual(ledger.pendingSeconds, 40, "Two callbacks measure forty seconds, not two synthetic ticks")
        ledger.sample(now: 140, wallDate: start.addingTimeInterval(40))
        XCTAssertEqual(ledger.pendingSeconds, 40, "Repeated sampling at the same instant must not double count")
        XCTAssertTrue(ledger.isCounting)
    }

    func testPausedLoadingBackgroundAndClosedIntervalsNeverAccrue() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(nil, now: 0, wallDate: start)
        ledger.sample(now: 100, wallDate: start.addingTimeInterval(100))
        XCTAssertEqual(ledger.pendingSeconds, 0)
        ledger.setContext(context(), now: 100, wallDate: start.addingTimeInterval(100))
        ledger.setContext(nil, now: 105, wallDate: start.addingTimeInterval(105))
        ledger.sample(now: 3_705, wallDate: start.addingTimeInterval(3_705))
        XCTAssertEqual(ledger.pendingSeconds, 5, "The one-hour pause must not be backfilled on return")
        XCTAssertFalse(ledger.isCounting)
        ledger.setContext(context(), now: 3_705, wallDate: start.addingTimeInterval(3_705))
        ledger.sample(now: 3_707, wallDate: start.addingTimeInterval(3_707))
        XCTAssertEqual(ledger.pendingSeconds, 7)
    }

    func testChapterChangeSettlesOldContextAndKeepsNaturalBookAttribution() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(11), now: 0, wallDate: start)
        ledger.setContext(context(12), now: 10, wallDate: start.addingTimeInterval(10))
        ledger.sample(now: 25, wallDate: start.addingTimeInterval(25))
        let slices = ledger.takePending(force: true)
        XCTAssertEqual(slices.map(\.chapterID), [11, 12])
        XCTAssertEqual(slices.map(\.seconds), [10, 15])
        XCTAssertTrue(slices.allSatisfy { $0.bookID == 1 && $0.generation == generation })
    }

    func testForceTakePreservesSubsecondRemaindersAcrossChapterChanges() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(11), now: 0, wallDate: start)
        ledger.sample(now: 1.75, wallDate: start.addingTimeInterval(1.75))
        XCTAssertEqual(ledger.takePending(force: true).map(\.seconds), [1])
        XCTAssertEqual(ledger.pendingDuration, 0.75, accuracy: 0.000_001)
        ledger.setContext(context(12), now: 1.75, wallDate: start.addingTimeInterval(1.75))
        ledger.setContext(context(11), now: 2.25, wallDate: start.addingTimeInterval(2.25))
        ledger.sample(now: 2.50, wallDate: start.addingTimeInterval(2.50))
        let next = ledger.takePending(force: true)
        XCTAssertEqual(next.map(\.chapterID), [11])
        XCTAssertEqual(next.map(\.seconds), [1])
        XCTAssertEqual(ledger.pendingDuration, 0.5, accuracy: 0.000_001, "The other chapter's half-second is still retained")
    }

    func testBatchThresholdAndTakeBeforeDispatchPreventAnyReplay() {
        var ledger = ReadingTimeLedger(minimumBatchSeconds: 60)
        ledger.setContext(context(11), now: 0, wallDate: start)
        ledger.setContext(context(12), now: 30, wallDate: start.addingTimeInterval(30))
        XCTAssertTrue(ledger.takePending().isEmpty)
        ledger.sample(now: 60, wallDate: start.addingTimeInterval(60))
        let dispatched = ledger.takePending()
        XCTAssertEqual(dispatched.map(\.seconds), [30, 30])
        XCTAssertEqual(Set(dispatched.map(\.id)).count, 2)
        XCTAssertEqual(ledger.pendingSeconds, 0)
        // There is deliberately no automatic put-back API after an ambiguous network result.
        XCTAssertTrue(ledger.takePending(force: true).isEmpty)
        ledger.sample(now: 65, wallDate: start.addingTimeInterval(65))
        let newTime = ledger.takePending(force: true)
        XCTAssertEqual(newTime.map(\.seconds), [5])
        XCTAssertFalse(dispatched.map(\.id).contains(newTime[0].id))
    }

    func testTwoMinuteIdleCeilingDoesNotBackfillWhenUserReturns() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(), now: 0, wallDate: start)
        ledger.sample(now: 600, wallDate: start.addingTimeInterval(600))
        XCTAssertEqual(ledger.pendingSeconds, 120)
        XCTAssertFalse(ledger.isCounting)
        ledger.markInteraction(now: 900, wallDate: start.addingTimeInterval(900))
        XCTAssertEqual(ledger.pendingSeconds, 120, "The idle gap before a new touch is never counted")
        XCTAssertTrue(ledger.isCounting)
        ledger.sample(now: 901, wallDate: start.addingTimeInterval(901))
        XCTAssertEqual(ledger.pendingSeconds, 121)
    }

    func testRepeatedContextAndHeartbeatDoNotRenewIdleGraceButInteractionDoes() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(), now: 0, wallDate: start)
        ledger.setContext(context(), now: 100, wallDate: start.addingTimeInterval(100))
        ledger.sample(now: 150, wallDate: start.addingTimeInterval(150))
        XCTAssertEqual(ledger.pendingSeconds, 120)
        XCTAssertFalse(ledger.isCounting)

        var active = ReadingTimeLedger()
        active.setContext(context(), now: 0, wallDate: start)
        active.markInteraction(now: 100, wallDate: start.addingTimeInterval(100))
        active.sample(now: 200, wallDate: start.addingTimeInterval(200))
        XCTAssertEqual(active.pendingSeconds, 200)
        XCTAssertTrue(active.isCounting)
    }

    func testInteractionWhilePausedDoesNotStartReading() {
        var ledger = ReadingTimeLedger()
        ledger.markInteraction(now: 10, wallDate: start)
        ledger.sample(now: 60, wallDate: start.addingTimeInterval(50))
        XCTAssertFalse(ledger.isCounting)
        XCTAssertEqual(ledger.pendingSeconds, 0)
    }

    func testMidnightSplitsIncrementByOfficialGMT8ServiceDate() throws {
        let midnight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z"))
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(), now: 10, wallDate: midnight.addingTimeInterval(-1))
        ledger.sample(now: 12, wallDate: midnight.addingTimeInterval(1))
        let slices = ledger.takePending(force: true)
        XCTAssertEqual(slices.map(\.readingDate), ["2026-11-01", "2026-11-02"])
        XCTAssertEqual(slices.map(\.seconds), [1, 1])
    }

    func testMidnightFractionsAreNotTransferredToAnotherServiceDay() throws {
        let midnight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z"))
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(), now: 0, wallDate: midnight.addingTimeInterval(-0.5))
        ledger.sample(now: 1, wallDate: midnight.addingTimeInterval(0.5))
        XCTAssertTrue(ledger.takePending(force: true).isEmpty)
        ledger.sample(now: 1.5, wallDate: midnight.addingTimeInterval(1))
        let slices = ledger.takePending(force: true)
        XCTAssertEqual(slices.map(\.readingDate), ["2026-11-02"])
        XCTAssertEqual(slices.map(\.seconds), [1])
        XCTAssertEqual(ledger.pendingDuration, 0.5, accuracy: 0.000_001)
    }

    func testClockAdjustmentCannotIncreaseMeasuredSeconds() {
        for wallJump: TimeInterval in [-86_400, 86_400] {
            var ledger = ReadingTimeLedger()
            ledger.setContext(context(), now: 100, wallDate: start)
            ledger.sample(now: 110, wallDate: start.addingTimeInterval(wallJump))
            XCTAssertEqual(ledger.pendingSeconds, 10)
        }
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(), now: 100, wallDate: start)
        ledger.sample(now: 110, wallDate: start.addingTimeInterval(10))
        ledger.sample(now: 99, wallDate: start)
        XCTAssertEqual(ledger.pendingSeconds, 10)
        XCTAssertFalse(ledger.isCounting, "A reset or invalid monotonic clock must pause rather than produce a bogus delta")
        ledger.sample(now: .infinity, wallDate: start)
        XCTAssertEqual(ledger.pendingSeconds, 10)
    }

    func testNewGenerationAndLogoutDiscardAllPreviousAccountTime() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(), now: 0, wallDate: start)
        ledger.sample(now: 30.5, wallDate: start.addingTimeInterval(30.5))
        let next = UUID()
        ledger.setContext(context(22, generation: next), now: 31, wallDate: start.addingTimeInterval(31))
        XCTAssertEqual(ledger.pendingDuration, 0)
        ledger.sample(now: 34, wallDate: start.addingTimeInterval(34))
        let slices = ledger.takePending(force: true)
        XCTAssertEqual(slices.map(\.generation), [next])
        XCTAssertEqual(slices.map(\.seconds), [3])
        ledger.sample(now: 35.5, wallDate: start.addingTimeInterval(35.5))
        ledger.reset()
        XCTAssertEqual(ledger.pendingDuration, 0)
        XCTAssertFalse(ledger.isCounting)
        XCTAssertTrue(ledger.takePending(force: true).isEmpty)
    }

    func testImportedTextAndInvalidChapterCannotAccrueReadingRewards() {
        var ledger = ReadingTimeLedger()
        ledger.setContext(context(-10, book: -100), now: 0, wallDate: start)
        ledger.sample(now: 100, wallDate: start.addingTimeInterval(100))
        XCTAssertEqual(ledger.pendingSeconds, 0)
        XCTAssertFalse(ledger.isCounting)
        ledger.setContext(context(0), now: 100, wallDate: start.addingTimeInterval(100))
        ledger.sample(now: 110, wallDate: start.addingTimeInterval(110))
        XCTAssertEqual(ledger.pendingSeconds, 0)
    }
}
