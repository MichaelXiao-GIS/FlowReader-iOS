import Foundation
import CoreFoundation

enum MemberGiftAvailability: Equatable, Sendable {
    case unknown, available, cooldown, membershipRequired
}

struct MemberGift: Identifiable, Equatable, Sendable {
    var id: String { "\(packType)-\(type)" }
    let type: Int
    let packType: Int
    let title: String
    let detail: String
    let quantity: Int?
    let intervalDays: Int?
    let remainingDays: Int?
    let lastClaimedAt: String?
    let availability: MemberGiftAvailability
}

struct MemberGiftsSnapshot: Equatable, Sendable {
    let account: AccountProfile
    let generation: UUID
    let gifts: [MemberGift]
    let isActiveMember: Bool?
    let notice: String?
}

struct MemberGiftReceipt: Equatable, Sendable {
    let message: String
}

extension SFAPI {
    func memberGifts(expectedGeneration: UUID? = nil) async throws -> MemberGiftsSnapshot {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        let generation = sessionGeneration()
        if let expectedGeneration, expectedGeneration != generation { throw CancellationError() }
        // The gift catalogue also works anonymously. A current authenticated user response
        // must establish both identity and membership before catalogue cooldowns are meaningful.
        let user = try await memberGiftPayload(MemberGiftProtocol.userRequest, generation: generation)
        _ = try MemberGiftProtocol.account(from: user)
        let gifts = try await memberGiftPayload(MemberGiftProtocol.listRequest, generation: generation)
        return try MemberGiftProtocol.snapshot(user: user, gifts: gifts, generation: generation)
    }

    /// Explicit user action only. Refresh account entitlement and cooldown immediately before POST.
    func claimMemberGift(_ gift: MemberGift, expectedGeneration: UUID) async throws -> MemberGiftReceipt {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        guard sessionGeneration() == expectedGeneration else { throw CancellationError() }
        guard await MemberGiftMutationGate.shared.begin(expectedGeneration) else {
            throw SFAPIError.server("正在领取会员礼包，请稍候。")
        }
        do {
            let fresh = try await memberGifts(expectedGeneration: expectedGeneration)
            let plan = try MemberGiftProtocol.claimRequest(for: gift, current: fresh)
            _ = try await memberGiftPayload(plan, generation: expectedGeneration)
            await MemberGiftMutationGate.shared.end(expectedGeneration)
            try Task.checkCancellation()
            guard sessionGeneration() == expectedGeneration else { throw CancellationError() }
            // parseAppResponse has already required an explicit successful server envelope.
            // No amount is invented when the server returns an empty receipt.
            return MemberGiftReceipt(message: "礼包领取成功")
        } catch {
            await MemberGiftMutationGate.shared.end(expectedGeneration)
            throw error
        }
    }

    private func memberGiftPayload(_ plan: MemberGiftProtocol.Request, generation: UUID) async throws -> Any {
        let request = try appRequest(path: plan.path, query: plan.query, body: nil, includeSession: true, method: plan.method)
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        return try Self.parseAppResponse(data, response: response)
    }
}

/// Original APK WelfareApi annotations establish POST query parameters, with no form/JSON body.
/// Authenticated read-only responses establish member.isOpen and the server's residueDay cooldown.
enum MemberGiftProtocol {
    struct Request: Equatable, Sendable {
        let path: String
        let method: String
        let query: [String: String]
    }

    static let userRequest = Request(path: "/user", method: "GET", query: ["expand": "member,dianyamember"])
    static let listRequest = Request(path: "/Member/Prize", method: "GET", query: ["packType": "0"])

    static func account(from payload: Any) throws -> AccountProfile {
        guard let user = payload as? [String: Any], let id = integer(user["accountId"]), id > 0 else {
            throw SFAPIError.authenticationRequired("请重新连接菠萝包账号服务后查看会员礼包。")
        }
        return AccountProfile(id: id, name: nonempty(user["nickName"]) ?? "菠萝包读者",
                              accountName: nonempty(user["userName"]) ?? String(id),
                              avatarURL: AccountProfileParser.avatarURL(in: user))
    }

    static func snapshot(user payload: Any, gifts: Any, generation: UUID) throws -> MemberGiftsSnapshot {
        let account = try account(from: payload)
        guard let user = payload as? [String: Any], let rows = gifts as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        let expand = user["expand"] as? [String: Any]
        let member = expand?["member"] as? [String: Any]
        let isActive = boolean(member?["isOpen"])
        var seen = Set<String>()
        let parsed = try rows.map { row -> MemberGift in
            guard let type = integer(row["type"]), let packType = integer(row["packType"]),
                  let title = nonempty(row["name"]) else { throw SFAPIError.invalidResponse }
            // Android aw.y.f() returns signed residueDay; the gift adapter enables
            // claiming for every value <= 0. interval is separate display metadata.
            let remaining = signedInteger(row["residueDay"])
            let interval = integer(row["interval"]).flatMap { $0 > 0 ? $0 : nil }
            let availability: MemberGiftAvailability
            if packType != 0 || !(0...3).contains(type) { availability = .unknown }
            else if isActive == false { availability = .membershipRequired }
            else if isActive == true, let remaining {
                availability = remaining <= 0 ? .available : .cooldown
            } else { availability = .unknown }
            let gift = MemberGift(type: type, packType: packType, title: title,
                                  detail: nonempty(row["desc"]) ?? "",
                                  quantity: integer(row["num"]).flatMap { $0 > 0 ? $0 : nil },
                                  intervalDays: interval, remainingDays: remaining,
                                  lastClaimedAt: nonempty(row["lastCreateDateTime"]), availability: availability)
            guard seen.insert(gift.id).inserted else { throw SFAPIError.invalidResponse }
            return gift
        }
        return MemberGiftsSnapshot(account: account, generation: generation, gifts: parsed, isActiveMember: isActive,
                                   notice: isActive == nil ? "暂未确认会员资格，请刷新后重试。" : nil)
    }

    static func claimRequest(for selected: MemberGift, current: MemberGiftsSnapshot) throws -> Request {
        guard let fresh = current.gifts.first(where: { $0.id == selected.id }) else {
            throw SFAPIError.server("该礼包已更新，请刷新列表后重试。")
        }
        guard fresh.packType == 0, (0...3).contains(fresh.type), current.isActiveMember == true else {
            throw SFAPIError.server(current.isActiveMember == false ? "当前账号尚未开通菠萝包会员。" : "尚未确认此礼包的领取资格，请刷新后重试。")
        }
        guard fresh.availability == .available else {
            if fresh.availability == .cooldown {
                throw SFAPIError.server("此礼包尚在领取间隔内，请按列表提示稍后再领。")
            }
            throw SFAPIError.server("尚未确认此礼包的领取资格，请刷新后重试。")
        }
        return Request(path: "/Member/Prize", method: "POST", query: ["type": String(fresh.type), "packType": "0"])
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0 else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func signedInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return Int(number.stringValue)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

actor MemberGiftMutationGate {
    static let shared = MemberGiftMutationGate()
    private var activeGenerations = Set<UUID>()
    func begin(_ generation: UUID) -> Bool { activeGenerations.insert(generation).inserted }
    func end(_ generation: UUID) { activeGenerations.remove(generation) }
}
