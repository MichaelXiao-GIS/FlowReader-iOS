import XCTest
@testable import FlowReader

final class AccountWalletTests: XCTestCase {
    private let generation = UUID()
    private var user: [String: Any] {
        ["accountId": 42, "userName": "fixture-reader", "nickName": "原创测试读者", "expand": ["welfareCoin": 37]]
    }
    private var money: [String: Any] { ["accountId": 42, "fireMoneyRemain": 123, "couponsRemain": 45] }

    func testWalletUsesOfficialIntegerUnitsAndSameAccount() throws {
        let value = try AccountWalletParser.parse(user: user, money: money, generation: generation)
        XCTAssertEqual(value.account.id, 42)
        XCTAssertEqual(value.generation, generation)
        XCTAssertEqual(value.fireMoney, 123)
        XCTAssertEqual(value.coupons, 45)
        XCTAssertEqual(value.goldCoins, 37)
        XCTAssertEqual(value.subscriptionBalance, 168, "Gold coins do not count towards chapter payment")
    }

    func testMissingAndMalformedBalancesRemainUnknownInsteadOfZero() throws {
        let invalid: [Any] = [true, -1, 2.5, "12", NSNull(), Double.infinity]
        for bad in invalid {
            var object = money
            object["fireMoneyRemain"] = bad
            let value = try AccountWalletParser.parse(user: user, money: object, generation: generation)
            XCTAssertNil(value.fireMoney)
            XCTAssertNil(value.subscriptionBalance)
        }
        let missing = try AccountWalletParser.parse(user: ["accountId": 42], money: [:], generation: generation)
        XCTAssertNil(missing.fireMoney)
        XCTAssertNil(missing.coupons)
        XCTAssertNil(missing.goldCoins)
        XCTAssertEqual(AccountWalletParser.nonnegativeInteger(0), 0)
    }

    func testMoneyIdentityMayBeAbsentButMustMatchWhenPresent() throws {
        var anonymousShape = money
        anonymousShape.removeValue(forKey: "accountId")
        XCTAssertEqual(try AccountWalletParser.parse(user: user, money: anonymousShape, generation: generation).fireMoney, 123)
        for id: Any in [43, 0, true, "42", NSNull()] {
            var object = money
            object["accountId"] = id
            XCTAssertThrowsError(try AccountWalletParser.parse(user: user, money: object, generation: generation))
        }
        XCTAssertThrowsError(try AccountWalletParser.parse(user: [:], money: money, generation: generation))
    }

    func testLargeIntegerRetainsPrecisionAndCombinedBalanceDoesNotOverflow() throws {
        XCTAssertEqual(AccountWalletParser.nonnegativeInteger(NSNumber(value: Int64(9_007_199_254_740_993))), 9_007_199_254_740_993)
        var object = money
        object["fireMoneyRemain"] = Int.max
        object["couponsRemain"] = 1
        let value = try AccountWalletParser.parse(user: user, money: object, generation: generation)
        XCTAssertEqual(value.fireMoney, Int.max)
        XCTAssertNil(value.subscriptionBalance)
    }

    func testWalletWithoutAppLoginStopsBeforeAnyNetworkRequest() async {
        let api = SFAPI(loadPersistedSessions: false)
        do { _ = try await api.wallet(); XCTFail("Must require an App session") }
        catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected \(error)") } }
    }
}
