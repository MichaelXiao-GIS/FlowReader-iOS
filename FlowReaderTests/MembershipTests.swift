import XCTest
@testable import FlowReader

final class MembershipTests: XCTestCase {
    func testNewVIPDoesNotGrantChapterOrMembershipOwnership() {
        let user: [String: Any] = ["expand": ["newVip": ["isNewVip": true, "level": 3, "name": "VIP 3"], "member": ["isMember": true, "expireTime": "2030-01-01"]]]
        let parsed = MembershipParser.appUser(user)
        XCTAssertEqual(parsed.vipLevel, 3)
        XCTAssertEqual(parsed.vipName, "VIP 3")
        XCTAssertEqual(parsed.system, "new")
        XCTAssertNil(parsed.isMember, "Unknown member DTOs must not become inferred subscription status")
        XCTAssertNil(parsed.expiresAt)
    }

    func testConfirmedMemberFlagIsIndependentFromVIPLevel() {
        let active = MembershipParser.appUser(["expand": ["member": ["isOpen": true]]])
        XCTAssertEqual(active.isMember, true)
        XCTAssertNil(active.vipLevel)
        XCTAssertNil(active.expiresAt)
        let inactive = MembershipParser.appUser(["expand": ["member": ["isOpen": false]]])
        XCTAssertEqual(inactive.isMember, false)
        let malformed = MembershipParser.appUser(["expand": ["member": ["isOpen": 1]]])
        XCTAssertNil(malformed.isMember)
    }

    func testMissingVIPIsUnknownInsteadOfZero() {
        let parsed = MembershipParser.appUser(["expand": [:]])
        XCTAssertNil(parsed.vipLevel)
        XCTAssertNil(parsed.vipName)
        XCTAssertNil(parsed.isMember)
    }

    func testLegacyLevelDoesNotUseNewVIPLevel() {
        let parsed = MembershipParser.appUser(["expand": ["newVip": ["isNewVip": false, "level": 9], "vipInfo": ["vipLevel": 2]]])
        XCTAssertEqual(parsed.vipLevel, 2)
        XCTAssertEqual(parsed.system, "legacy")
    }

    func testIncompleteNewVIPNeverFallsBackToLegacyLevels() {
        let result = MembershipParser.appUser(["vipLevel": 8, "expand": ["newVip": ["isNewVip": true, "name": "新 VIP"], "vipInfo": ["vipLevel": 7]]])
        XCTAssertEqual(result.system, "new")
        XCTAssertEqual(result.vipName, "新 VIP")
        XCTAssertNil(result.vipLevel)
        XCTAssertFalse(result.needsLegacyLevelLookup)
        let legacy = MembershipParser.appUser(["expand": ["newVip": ["isNewVip": false]]])
        XCTAssertTrue(legacy.needsLegacyLevelLookup)
    }

    func testUnknownOrMalformedVIPSystemDoesNotInventALevel() {
        for newVIP in [[String: Any](), ["isNewVip": 1, "level": 9]] {
            let result = MembershipParser.appUser(["vipLevel": 8, "expand": ["newVip": newVIP, "vipInfo": ["vipLevel": 7]]])
            XCTAssertNil(result.system)
            XCTAssertNil(result.vipLevel)
            XCTAssertFalse(result.needsLegacyLevelLookup)
        }
        let fractional = MembershipParser.appUser(["expand": ["newVip": ["isNewVip": true, "level": 2.5]]])
        XCTAssertNil(fractional.vipLevel)
    }

    func testWebAuthenticationFailureRemainsAuthenticationFailure() {
        XCTAssertThrowsError(try MembershipParser.webPayload(#"{"status":{"errorCode":401,"msg":"请先登录"},"data":null}"#)) { error in
            guard case SFAPIError.authenticationRequired(let message) = error else { return XCTFail("Expected authenticationRequired, got \(error)") }
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertThrowsError(try MembershipParser.webPayload(#"{"status":{"errorCode":403,"msg":"访问受限"},"data":null}"#)) { error in
            guard case SFAPIError.authenticationRequired(let message) = error else { return XCTFail("Expected authenticationRequired, got \(error)") }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testWebVIPResponseEnvelope() throws {
        let data = try MembershipParser.webPayload(#"{"status":{"errorCode":200},"data":{"expand":{"newVip":{"isNewVip":true,"level":4,"name":"VIP4"}}}}"#)
        XCTAssertEqual(MembershipParser.appUser(data).vipLevel, 4)
    }
}
