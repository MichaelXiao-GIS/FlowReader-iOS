import XCTest
@testable import FlowReader

@MainActor
final class SignInConfirmationStoreTests: XCTestCase {
    func testConfirmedReceiptSurvivesRecreationForOnlyTheSameAppAccountAndServiceDay() throws {
        let suite = "FlowSignInTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-30T17:00:00Z"))
        let account = AccountProfile(id: 123, name: "测试昵称", accountName: "private_test_name")
        SignInConfirmationStore(defaults: defaults).record(SignInReceipt(alreadySigned: true, rewards: []), for: account, at: date)
        let restored = SignInConfirmationStore(defaults: defaults)
        XCTAssertTrue(restored.isConfirmed(for: account, at: date))
        XCTAssertFalse(restored.isConfirmed(for: AccountProfile(id: 456, name: "测试昵称", accountName: "other"), at: date))
        XCTAssertFalse(restored.isConfirmed(for: account, at: date.addingTimeInterval(86_400)))
        let saved = try XCTUnwrap(defaults.dictionary(forKey: SignInConfirmationStore.storageKey) as? [String: String])
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved.keys.allSatisfy { $0.count == 64 && !$0.contains(account.accountName) })
        XCTAssertEqual(Array(saved.values), ["2026-10-31"])
    }

    func testUnknownAndNegativeStatusNeverCreateConfirmation() throws {
        let suite = "FlowSignInTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SignInConfirmationStore(defaults: defaults)
        let account = AccountProfile(id: 123, name: "测试", accountName: "test")
        store.record(SignInStatus(signedToday: nil, consecutiveDays: nil), for: account)
        store.record(SignInStatus(signedToday: false, consecutiveDays: 0), for: account)
        XCTAssertFalse(store.isConfirmed(for: account))
        XCTAssertNil(defaults.dictionary(forKey: SignInConfirmationStore.storageKey))
    }

    func testUnknownAccountIdentityCannotBeCached() throws {
        let suite = "FlowSignInTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SignInConfirmationStore(defaults: defaults)
        let account = AccountProfile(id: 0, name: "未确认", accountName: "web_only")
        store.record(SignInReceipt(alreadySigned: false, rewards: []), for: account)
        XCTAssertFalse(store.isConfirmed(for: account))
        XCTAssertNil(defaults.dictionary(forKey: SignInConfirmationStore.storageKey))
    }
}
