#if DEBUG
import Foundation

/// Every dependency is local. Even accidental navigation to daily welfare cannot contact an API.
@MainActor
final class MemberGiftsFixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--member-gifts-fixture")
    }

    private let generation = UUID()
    private var dailyClaimed = false

    static func makeState() -> WelfareViewState {
        let fixture = MemberGiftsFixture()
        return WelfareViewState(client: .init(
            generation: { fixture.generation },
            profile: { try MemberGiftProtocol.account(from: fixture.user) },
            daily: { _ in throw SFAPIError.server("此离线场景仅验收会员礼包。") },
            gifts: { try fixture.snapshot(expectedGeneration: $0) },
            acceptTask: { _, _ in throw SFAPIError.server("离线场景不执行日常任务。") },
            claimReward: { _, _ in throw SFAPIError.server("离线场景不执行日常任务。") },
            claimGift: { try fixture.claim($0, expectedGeneration: $1) }
        ))
    }

    private var user: [String: Any] {
        ["accountId": 900_821, "nickName": "离线礼包测试读者", "userName": "offline-member-gifts",
         "expand": ["member": ["isOpen": true], "dianyamember": ["isOpen": false]]]
    }

    private var rows: [[String: Any]] {
        [
            ["type": 1, "packType": 0, "name": "每日会员代券", "desc": "每日可领取 20 代券",
             "num": 20, "interval": 1, "residueDay": dailyClaimed ? 1 : -1,
             "lastCreateDateTime": NSNull()],
            ["type": 0, "packType": 0, "name": "每周会员礼包", "desc": "每7天可领取一次",
             "num": 2, "interval": 7, "residueDay": 5, "lastCreateDateTime": NSNull()]
        ]
    }

    private func snapshot(expectedGeneration: UUID) throws -> MemberGiftsSnapshot {
        guard expectedGeneration == generation else { throw CancellationError() }
        return try MemberGiftProtocol.snapshot(user: user, gifts: rows, generation: generation)
    }

    private func claim(_ gift: MemberGift, expectedGeneration: UUID) throws -> MemberGiftReceipt {
        // Exercise the real fresh eligibility check before changing this in-memory fixture.
        let fresh = try snapshot(expectedGeneration: expectedGeneration)
        let plan = try MemberGiftProtocol.claimRequest(for: gift, current: fresh)
        guard plan.method == "POST", plan.path == "/Member/Prize",
              plan.query == ["type": "1", "packType": "0"] else {
            throw SFAPIError.server("离线场景只允许领取每日礼包。")
        }
        dailyClaimed = true
        return MemberGiftReceipt(message: "礼包领取成功")
    }
}
#endif
