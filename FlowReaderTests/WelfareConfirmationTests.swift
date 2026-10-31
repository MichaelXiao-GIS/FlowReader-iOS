import XCTest
@testable import FlowReader

final class WelfareConfirmationTests: XCTestCase {
    func testAcceptedTaskWaitsForFreshStateBeforeRewardAndConfirmedRewardCannotRepeat() {
        var policy = WelfareConfirmationPolicy()
        let generation = UUID()
        policy.prepare(generation: generation, serviceDay: "2026-10-31")
        XCTAssertTrue(policy.canSubmit(task(.notAccepted)))
        policy.record(DailyWelfareReceipt(taskID: 10, action: .acceptTask, confirmedAt: Date()))
        policy.reconcile(tasks: [task(.notAccepted)])
        XCTAssertFalse(policy.canSubmit(task(.notAccepted)), "A stale refresh must not accept the same task again")
        policy.reconcile(tasks: [task(.claimable)])
        XCTAssertTrue(policy.canSubmit(task(.claimable)), "A server-completed accepted task may advance to its reward")
        policy.record(DailyWelfareReceipt(taskID: 10, action: .claimReward, confirmedAt: Date()))
        policy.reconcile(tasks: [task(.claimable)])
        XCTAssertFalse(policy.canSubmit(task(.claimable)), "The reward receipt wins over the old claimable row")
        policy.reconcile(tasks: [task(.claimed)])
        XCTAssertFalse(policy.canSubmit(task(.claimed)))
        policy.reconcile(tasks: [task(.claimable)])
        XCTAssertFalse(policy.canSubmit(task(.claimable)), "A later stale row must not undo today's confirmed reward")
    }

    func testGiftConfirmationSurvivesSameDayRefreshUntilServerShowsCooldown() {
        var policy = WelfareConfirmationPolicy()
        let generation = UUID()
        policy.prepare(generation: generation, serviceDay: "2026-10-31")
        let available = gift(.available)
        policy.record(MemberGiftReceipt(message: "礼包领取成功"), gift: available)
        policy.prepare(generation: generation, serviceDay: "2026-10-31")
        policy.reconcile(gifts: [available])
        XCTAssertFalse(policy.canSubmit(available))
        XCTAssertEqual(policy.giftMessages[available.id], "礼包领取成功")
        policy.reconcile(gifts: [gift(.cooldown)])
        XCTAssertFalse(policy.canSubmit(gift(.cooldown)))
        policy.reconcile(gifts: [available])
        XCTAssertFalse(policy.canSubmit(available), "A same-day stale available row cannot erase a confirmed claim")
        policy.prepare(generation: generation, serviceDay: "2026-11-01")
        XCTAssertFalse(policy.canSubmit(available), "The day change alone is not a new eligibility response")
        policy.reconcile(gifts: [available])
        XCTAssertTrue(policy.canSubmit(available))
    }

    func testNextServiceDayReleasesOldReceiptsButStillRequiresActionableServerRows() {
        var policy = WelfareConfirmationPolicy()
        let generation = UUID()
        policy.prepare(generation: generation, serviceDay: "2026-10-31")
        policy.record(DailyWelfareReceipt(taskID: 10, action: .claimReward, confirmedAt: Date()))
        policy.record(MemberGiftReceipt(message: "礼包领取成功"), gift: gift(.available))
        policy.prepare(generation: generation, serviceDay: "2026-11-01")
        XCTAssertTrue(policy.canSubmit(task(.notAccepted)))
        XCTAssertFalse(policy.canSubmit(gift(.available)))
        policy.reconcile(gifts: [gift(.available)])
        XCTAssertTrue(policy.canSubmit(gift(.available)))
        XCTAssertFalse(policy.canSubmit(task(.unknown)))
        XCTAssertFalse(policy.canSubmit(gift(.cooldown)))
        XCTAssertFalse(policy.canSubmit(gift(.membershipRequired)))
    }

    func testNewSessionDoesNotInheritAnotherAccountsConfirmation() {
        var policy = WelfareConfirmationPolicy()
        policy.prepare(generation: UUID(), serviceDay: "2026-10-31")
        policy.record(DailyWelfareReceipt(taskID: 10, action: .claimReward, confirmedAt: Date()))
        policy.record(MemberGiftReceipt(message: "礼包领取成功"), gift: gift(.available))
        policy.prepare(generation: UUID(), serviceDay: "2026-10-31")
        XCTAssertTrue(policy.taskActions.isEmpty)
        XCTAssertTrue(policy.giftMessages.isEmpty)
        XCTAssertTrue(policy.canSubmit(task(.claimable)))
        XCTAssertFalse(policy.canSubmit(task(.inProgress)))
        XCTAssertFalse(policy.canSubmit(gift(.unknown)))
    }

    func testSignInCannotBecomeAWelfareTaskAction() {
        let signIn = DailyWelfareTask(taskID: 26, recordID: 0, name: "每日签到", description: "签到",
                                      rewardText: nil, statusText: nil, kind: "signIn", taskType: 26,
                                      requiredCount: 1, completedCount: 0, state: .notAccepted)
        XCTAssertFalse(WelfareConfirmationPolicy().canSubmit(signIn))
    }

    func testGiftWithoutCooldownReadbackUnlocksOnlyAfterItsFullIntervalAndFreshAvailability() {
        var policy = WelfareConfirmationPolicy()
        let generation = UUID()
        let weekly = MemberGift(type: 1, packType: 0, title: "每周礼包", detail: "每7天可领", quantity: 1,
                                intervalDays: 7, remainingDays: 0, lastClaimedAt: nil, availability: .available)
        policy.prepare(generation: generation, serviceDay: "2026-10-31")
        policy.record(MemberGiftReceipt(message: "礼包领取成功"), gift: weekly)
        // Simulate a failed post-claim refresh: no cooldown snapshot is ever received.
        policy.prepare(generation: generation, serviceDay: "2026-11-01")
        policy.reconcile(gifts: [weekly])
        XCTAssertFalse(policy.canSubmit(weekly))
        policy.prepare(generation: generation, serviceDay: "2026-11-07")
        XCTAssertFalse(policy.canSubmit(weekly))
        policy.reconcile(gifts: [weekly])
        XCTAssertTrue(policy.canSubmit(weekly), "A confirmed old claim must not permanently lock a later server-approved cycle")
    }

    private func task(_ state: DailyWelfareState) -> DailyWelfareTask {
        DailyWelfareTask(taskID: 10, recordID: state == .notAccepted ? 0 : 3, name: "阅读一小时", description: "测试任务",
                         rewardText: "测试奖励", statusText: nil, kind: "novelHome", taskType: 4,
                         requiredCount: 3600, completedCount: state == .claimable || state == .claimed ? 3600 : 0, state: state)
    }

    private func gift(_ availability: MemberGiftAvailability) -> MemberGift {
        MemberGift(type: 0, packType: 0, title: "每日礼包", detail: "测试礼包", quantity: 1, intervalDays: 1,
                   remainingDays: availability == .cooldown ? 1 : 0, lastClaimedAt: nil, availability: availability)
    }
}
