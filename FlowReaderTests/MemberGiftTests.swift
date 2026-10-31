import XCTest
@testable import FlowReader

final class MemberGiftTests: XCTestCase {
    private let generation = UUID()
    private func user(_ active: Any? = true) -> [String: Any] {
        var membership: [String: Any] = [:]
        if let active { membership["isOpen"] = active }
        return ["accountId": 42, "nickName": "测试读者", "userName": "fixture-reader",
                "expand": ["member": membership, "dianyamember": ["isOpen": false]]]
    }
    private func row(type: Int = 1, remaining: Any = 0, packType: Int = 0) -> [String: Any] {
        ["type": type, "packType": packType, "name": "每日礼包", "desc": "每日可领", "num": 0,
         "interval": 1, "residueDay": remaining, "lastCreateDateTime": NSNull()]
    }
    private func snapshot(_ rows: [[String: Any]], active: Any? = true) throws -> MemberGiftsSnapshot {
        try MemberGiftProtocol.snapshot(user: user(active), gifts: rows, generation: generation)
    }

    func testAnonymousCatalogueCannotEstablishIdentityOrEligibility() throws {
        XCTAssertThrowsError(try MemberGiftProtocol.snapshot(user: ["expand": ["member": ["isOpen": true]]],
                                                            gifts: [row()], generation: generation))
        let unknown = try snapshot([row()], active: nil)
        XCTAssertNil(unknown.isActiveMember)
        XCTAssertEqual(unknown.gifts[0].availability, .unknown)
        XCTAssertNotNil(unknown.notice)
        XCTAssertThrowsError(try MemberGiftProtocol.claimRequest(for: unknown.gifts[0], current: unknown))
    }

    func testVerifiedActiveMemberUsesServerCooldownWithoutInventingRewardAmount() throws {
        let value = try snapshot([row(type: 0, remaining: 5), row(type: 1, remaining: 0)])
        XCTAssertEqual(value.account.id, 42)
        XCTAssertEqual(value.generation, generation)
        XCTAssertEqual(value.gifts.map(\.availability), [.cooldown, .available])
        XCTAssertEqual(value.gifts[0].remainingDays, 5)
        XCTAssertNil(value.gifts[1].quantity, "Catalogue num=0 is not a zero-value reward receipt")
        XCTAssertThrowsError(try MemberGiftProtocol.claimRequest(for: value.gifts[0], current: value))
    }

    func testNonmemberAndMalformedScalarValuesNeverEnableClaim() throws {
        let notMember = try snapshot([row()], active: false)
        XCTAssertEqual(notMember.gifts[0].availability, .membershipRequired)
        for value: Any in [1, "true", NSNull()] {
            XCTAssertEqual(try snapshot([row()], active: value).gifts[0].availability, .unknown)
        }
        for value: Any in [-1, 0.5, true, "0", NSNull()] {
            let result = try snapshot([row(remaining: value)])
            XCTAssertEqual(result.gifts[0].availability, .unknown)
            XCTAssertThrowsError(try MemberGiftProtocol.claimRequest(for: result.gifts[0], current: result))
        }
    }

    func testRefreshRechecksSelectedGiftInsteadOfTrustingOldAvailableState() throws {
        let old = try snapshot([row()])
        let refreshed = try snapshot([row(remaining: 1)])
        XCTAssertThrowsError(try MemberGiftProtocol.claimRequest(for: old.gifts[0], current: refreshed))
        let gone = try snapshot([])
        XCTAssertThrowsError(try MemberGiftProtocol.claimRequest(for: old.gifts[0], current: gone))
        let revoked = try snapshot([row()], active: false)
        XCTAssertThrowsError(try MemberGiftProtocol.claimRequest(for: old.gifts[0], current: revoked))
    }

    func testUnverifiedPackTypesAndDuplicateRowsAreNotClaimable() throws {
        for record in [row(type: 4), row(packType: 1)] {
            let value = try snapshot([record])
            XCTAssertEqual(value.gifts[0].availability, .unknown)
            XCTAssertThrowsError(try MemberGiftProtocol.claimRequest(for: value.gifts[0], current: value))
        }
        XCTAssertThrowsError(try snapshot([row(), row()]))
    }

    func testAPKContractUsesAuthenticatedGETThenBodylessPOSTWithQueryOnly() async throws {
        XCTAssertEqual(MemberGiftProtocol.userRequest.method, "GET")
        XCTAssertEqual(MemberGiftProtocol.userRequest.query, ["expand": "member,dianyamember"])
        XCTAssertEqual(MemberGiftProtocol.listRequest.method, "GET")
        XCTAssertEqual(MemberGiftProtocol.listRequest.path, "/Member/Prize")
        let current = try snapshot([row()])
        let plan = try MemberGiftProtocol.claimRequest(for: current.gifts[0], current: current)
        XCTAssertEqual(plan.method, "POST")
        XCTAssertEqual(plan.query, ["type": "1", "packType": "0"])
        let api = SFAPI(loadPersistedSessions: false)
        let request = try await api.appRequest(path: plan.path, query: plan.query, body: nil, includeSession: true, method: plan.method)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "api.sfacg.com")
        XCTAssertEqual(request.url?.path, "/Member/Prize")
        let queries = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: queries.map { ($0.name, $0.value ?? "") }), plan.query)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
    }

    func testMissingAppSessionStopsBothReadsAndClaimsBeforeNetwork() async throws {
        let api = SFAPI(loadPersistedSessions: false)
        do { _ = try await api.memberGifts(); XCTFail("Missing session must fail") }
        catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected: \(error)") } }
        let current = try snapshot([row()])
        do { _ = try await api.claimMemberGift(current.gifts[0], expectedGeneration: generation); XCTFail("Missing session must fail") }
        catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected: \(error)") } }
    }

    func testMutationGateRejectsConcurrentClaimAndAllowsRetryAfterCompletion() async {
        let gate = MemberGiftMutationGate()
        let first = await gate.begin(generation)
        let duplicate = await gate.begin(generation)
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        await gate.end(generation)
        let next = await gate.begin(generation)
        XCTAssertTrue(next)
        await gate.end(generation)
    }
}
