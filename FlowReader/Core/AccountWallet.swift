import Foundation
import CoreFoundation

struct AccountWallet: Equatable, Sendable {
    let account: AccountProfile
    let generation: UUID
    /// Official integer units; no monetary conversion or predicted deduction order.
    let fireMoney: Int?
    let coupons: Int?
    let goldCoins: Int?

    var subscriptionBalance: Int? {
        guard let fireMoney, let coupons else { return nil }
        let total = fireMoney.addingReportingOverflow(coupons)
        return total.overflow ? nil : total.partialValue
    }
}

extension SFAPI {
    func wallet(expectedGeneration: UUID? = nil) async throws -> AccountWallet {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        let generation = sessionGeneration()
        if let expectedGeneration, generation != expectedGeneration { throw CancellationError() }
        let user = try await orderPayload(path: "/user", query: ["expand": "welfareCoin"], generation: generation)
        let money = try await orderPayload(path: "/user/money", generation: generation)
        let confirmation = try await orderPayload(path: "/user", query: ["expand": "welfareCoin"], generation: generation)
        let first = try AccountWalletParser.parse(user: user, money: money, generation: generation)
        let last = try AccountWalletParser.parse(user: confirmation, money: money, generation: generation)
        guard first.account.matchesAccountIdentity(last.account) else { throw SFAPIError.invalidResponse }
        return last
    }

    func orderPayload(path: String, query: [String: String] = [:], body: [String: Any]? = nil,
                      method: String = "GET", generation: UUID) async throws -> Any {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        guard sessionGeneration() == generation else { throw CancellationError() }
        var request = try appRequest(path: path, query: query, body: body, includeSession: true, method: method)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        return try Self.parseAppResponse(data, response: response)
    }
}

enum AccountWalletParser {
    static func parse(user payload: Any, money: Any, generation: UUID) throws -> AccountWallet {
        guard let user = payload as? [String: Any], let money = money as? [String: Any],
              let accountID = nonnegativeInteger(user["accountId"]), accountID > 0 else { throw SFAPIError.invalidResponse }
        // Current official money responses omit accountId. When present it must still match.
        // The network boundary verifies the same user before and after this request.
        if let rawID = money["accountId"], nonnegativeInteger(rawID) != accountID { throw SFAPIError.invalidResponse }
        let account = AccountProfile(id: accountID, name: nonempty(user["nickName"]) ?? "菠萝包读者",
                                     accountName: nonempty(user["userName"]) ?? String(accountID))
        let expand = user["expand"] as? [String: Any]
        return AccountWallet(account: account, generation: generation,
                             fireMoney: nonnegativeInteger(money["fireMoneyRemain"]),
                             coupons: nonnegativeInteger(money["couponsRemain"]),
                             goldCoins: nonnegativeInteger(expand?["welfareCoin"]))
    }

    static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              let integer = Int(number.stringValue), integer >= 0 else { return nil }
        return integer
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
