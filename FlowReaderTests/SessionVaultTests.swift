import XCTest
@testable import FlowReader

final class SessionVaultTests: XCTestCase {
    func testSignedAppCanStoreUpdateAndReadAnIsolatedSession() throws {
        let account = "flow-keychain-test-\(UUID().uuidString)"
        defer { SessionVault.clear(account: account) }
        let first = Data("synthetic-test-session".utf8)
        try SessionVault.write(first, account: account)
        XCTAssertEqual(SessionVault.read(account: account), first)
        let updated = Data("updated-synthetic-test-session".utf8)
        try SessionVault.write(updated, account: account)
        XCTAssertEqual(SessionVault.read(account: account), updated)
        SessionVault.clear(account: account)
        XCTAssertNil(SessionVault.read(account: account))
    }
}
