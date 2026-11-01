#if DEBUG
import Foundation

/// Local end-to-end fixture: the reader still uses real elapsed time and production tracking.
/// Negative demo IDs map only here to synthetic remote IDs; no credentials or live APIs exist.
@MainActor
final class ReadingTimeFixture {
    static let shared = ReadingTimeFixture()
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--reading-time-fixture")
    }
    private let generation = UUID()
    private let account = AccountProfile(id: 900_901, name: "离线阅读计时测试", accountName: "offline-reading-time", avatarURL: nil)
    private var serverSeconds = 3_599
    private var submissions = Set<UUID>()

    func context(chapterID: Int) -> ReadingTimeContext {
        .init(generation: generation, bookID: 900_101, chapterID: 900_000 + abs(chapterID))
    }

    func makeReporter() -> ReadingTimeReporter {
        ReadingTimeReporter(client: .init(generation: { self.generation }, profile: { self.account }, report: {
            let plan = try ReadingTimeProtocol.request(for: $0)
            guard $0.generation == self.generation, $0.account == self.account,
                  self.submissions.insert($0.id).inserted, plan.bookID == 900_101 else { throw SFAPIError.invalidResponse }
            if ProcessInfo.processInfo.arguments.contains("--reading-time-failure-fixture") {
                throw ReadingTimeSubmissionError.resultUnknown("离线模拟未确认回执")
            }
            self.serverSeconds += plan.seconds
            return ReadingTimeReceipt(submissionID: $0.id, generation: $0.generation, confirmedAt: Date())
        }))
    }

    func makeWelfareState() -> WelfareViewState {
        WelfareViewState(client: .init(generation: { self.generation }, profile: { self.account }, daily: { expected in
            guard expected == self.generation else { throw CancellationError() }
            let rows: [[String: Any]] = [["taskId": 5, "recordId": 9001, "name": "每日阅读60分钟",
                "desc": "轻小说／漫画／对话", "tips1": "离线验收，无真实奖励", "type": "novelHome", "taskType": 4,
                "category": 1, "requireNum": 3600, "completeNum": self.serverSeconds,
                "status": self.serverSeconds >= 3600 ? 1 : 0]]
            return DailyWelfareSnapshot(tasks: try DailyWelfareProtocol.tasks(from: rows), generation: self.generation)
        }, gifts: { _ in throw SFAPIError.invalidResponse },
        acceptTask: { _, _ in throw SFAPIError.server("离线测试不接受任务。") },
        claimReward: { _, _ in throw SFAPIError.server("离线测试不领取奖励。") },
        claimGift: { _, _ in throw SFAPIError.server("离线测试不领取礼包。") }))
    }
}
#endif
