import XCTest
@testable import FlowReader

final class ChapterPurchaseTests: XCTestCase {
    func testOnlyExplicitAuthenticatedOwnershipFieldsConfirmPurchase() throws {
        let payload: [String: Any] = ["volumeList": [["chapterList": [
            ["chapId": 1, "isVip": true, "has": true],
            ["chapId": 2, "isVip": true, "has": false],
            ["chapId": 3, "isVip": true],
            ["chapId": 4, "isVip": false, "has": true]
        ]]]]
        let result = try ChapterPurchaseParser.states(from: payload)
        XCTAssertEqual(result[1], .purchased)
        XCTAssertEqual(result[2], .notPurchased)
        XCTAssertEqual(result[3], .unknown)
        XCTAssertNil(result[4], "Free access does not establish a purchase")
    }

    func testAuthenticatedZeroQuoteMeansReadableAndNeverPurchased() throws {
        let payload: [String: Any] = ["volumeList": [["chapterList": [
            ["chapId": 1, "isVip": true, "needFireMoney": 0],
            ["chapId": 2, "isVip": true, "has": 1, "needFireMoney": 0],
            ["chapId": 3, "isVip": true, "has": "true"],
            ["chapId": 4, "isVip": true, "has": NSNull()],
            ["chapId": 5, "isVip": true, "has": true, "needFireMoney": 0],
            ["chapId": 6, "isVip": true, "has": false, "needFireMoney": 0],
            ["chapId": 7, "isVip": true, "has": false, "needFireMoney": 26]
        ]]]]
        let result = try ChapterPurchaseParser.states(from: payload)
        XCTAssertEqual(result[1], .available)
        XCTAssertEqual(result[2], .available, "An invalid has value never creates a purchase; the independent numeric quote may confirm readability")
        XCTAssertEqual(result[3], .unknown)
        XCTAssertEqual(result[4], .unknown)
        XCTAssertEqual(result[5], .purchased, "Explicit ownership takes precedence")
        XCTAssertEqual(result[6], .available, "Not purchased can still be readable during a promotion")
        XCTAssertEqual(result[7], .notPurchased)
    }

    func testInvalidOrPositiveQuotesCannotUnlockAChapter() throws {
        let rows: [[String: Any]] = [
            ["chapId": 1, "isVip": true, "needFireMoney": 26],
            ["chapId": 2, "isVip": true, "needFireMoney": -1],
            ["chapId": 3, "isVip": true, "needFireMoney": false],
            ["chapId": 4, "isVip": true, "needFireMoney": 0.25],
            ["chapId": 5, "isVip": true],
            ["chapId": 6, "isVip": true, "needFireMoney": "0"],
            ["chapId": 7, "isVip": true, "needFireMoney": NSNull()]
        ]
        let result = try ChapterPurchaseParser.states(from: ["volumeList": [["chapterList": rows]]])
        XCTAssertEqual(result.count, rows.count)
        XCTAssertEqual(result[1], .requiresPurchase, "A positive current quote proves payment is required, not transaction history")
        XCTAssertTrue(result.filter { $0.key != 1 }.values.allSatisfy { $0 == .unknown })
    }

    func testCurrentCataloguePermissionsWinOverEarlierSuccessfulReads() {
        let fresh: [Int: ChapterPurchaseState] = [1: .requiresPurchase, 2: .notPurchased, 3: .purchased, 4: .available, 5: .unknown]
        let verified = Dictionary(uniqueKeysWithValues: (1...6).map { ($0, ChapterPurchaseState.available) })
        let merged = ChapterPurchaseParser.merging(verified: verified, into: fresh)
        XCTAssertEqual(merged[1], .requiresPurchase)
        XCTAssertEqual(merged[2], .notPurchased)
        XCTAssertEqual(merged[3], .purchased)
        XCTAssertEqual(merged[4], .available)
        XCTAssertEqual(merged[5], .available)
        XCTAssertEqual(merged[6], .available)
    }

    func testMalformedCatalogueCannotConfirmAnEmptyPurchaseList() {
        XCTAssertThrowsError(try ChapterPurchaseParser.states(from: [:]))
        XCTAssertThrowsError(try ChapterPurchaseParser.states(from: ["volumeList": "login-required"]))
    }

    func testLegacyFalseOwnershipAndSavedNewPermissionsDecodeAsUnknown() throws {
        let old = Data(#"{"id":1,"bookID":42,"volumeID":2,"volumeTitle":"卷","title":"章","order":0,"isVIP":true,"isOwned":false}"#.utf8)
        var chapter = try JSONDecoder().decode(Chapter.self, from: old)
        XCTAssertEqual(chapter.purchaseState(for: UUID()), .unknown)
        let generation = UUID()
        chapter.confirmedPurchaseState = .purchased
        chapter.purchaseSessionGeneration = generation
        let saved = try JSONEncoder().encode(chapter)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNil(fields["confirmedPurchaseState"])
        XCTAssertNil(fields["purchaseSessionGeneration"])
        let restored = try JSONDecoder().decode(Chapter.self, from: saved)
        XCTAssertEqual(restored.purchaseState(for: generation), .unknown)
    }

    func testAccountSwitchInvalidatesAnInMemoryPurchasedBadge() {
        let generation = UUID()
        var chapter = Chapter(id: 1, bookID: 42, volumeID: 2, volumeTitle: "卷", title: "章", order: 0, isVIP: true)
        chapter.confirmedPurchaseState = .purchased
        chapter.purchaseSessionGeneration = generation
        XCTAssertEqual(chapter.purchaseState(for: generation), .purchased)
        XCTAssertEqual(chapter.purchaseState(for: UUID()), .unknown)
        XCTAssertEqual(chapter.purchaseState(for: nil), .unknown)
    }

    func testPurchaseLookupRequiresAnAppSessionBeforeAnyNetworkRequest() async {
        let api = SFAPI(loadPersistedSessions: false)
        do {
            _ = try await api.chapterPurchaseStates(bookID: 42)
            XCTFail("An anonymous catalogue cannot confirm purchase state")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("同一账号"))
        }
    }

    func testVerifiedReadableContentIsScopedToBookAndCurrentSession() async throws {
        let api = SFAPI(loadPersistedSessions: false)
        let generation = await api.sessionGeneration()
        let chapter = Chapter(id: 1, bookID: 42, volumeID: 2, volumeTitle: "卷", title: "章", order: 0, isVIP: true)
        await api.recordReadableChapter(chapter, generation: generation)
        let result = try await api.chapterPurchaseStates(bookID: 42)
        XCTAssertEqual(result.states[1], .available)
        XCTAssertEqual(result.generation, generation)
        let otherBook = await api.verifiedReadableChapterStates(bookID: 43, generation: generation)
        XCTAssertTrue(otherBook.isEmpty)
        await api.logout() // In-memory test client never clears persisted Keychain accounts.
        let replacement = await api.sessionGeneration()
        await api.recordReadableChapter(chapter, generation: generation)
        let stale = await api.verifiedReadableChapterStates(bookID: 42, generation: replacement)
        XCTAssertTrue(stale.isEmpty)
    }
}
