import XCTest
@testable import FlowReader

final class AppChapterContentTests: XCTestCase {
    private let chapter = Chapter(id: 123, bookID: 456, volumeID: 7, volumeTitle: "测试卷",
                                  title: "原创测试章节", order: 0, isVIP: true)

    private func payload(text: String = "款裔炯绳瓜因。", encrypted: Any = false, price: Any = 0) -> [String: Any] {
        ["chapId": 123, "novelId": 456, "isVip": true,
         "expand": ["content": text, "isContentEncrypted": encrypted, "needFireMoney": price, "originNeedFireMoney": 20]]
    }

    func testAuthorizedSubstitutionRestoresTextAndMarksOnlyCurrentSessionReadable() throws {
        let generation = UUID()
        let source = "雀曙，咸芹。<A> &amp; 👩🏽‍🚀\r\n款裔炯绳瓜因。\r宦。"
        let content = try AppChapterContentProtocol.parse(payload(text: source), chapter: chapter, generation: generation)
        XCTAssertEqual(content.text, "你好，世界。<A> &amp; 👩🏽‍🚀\n这是测试正文。\n啊。")
        XCTAssertEqual(content.paragraphs.count, 3)
        XCTAssertEqual(content.sourceFormatVersion, 4)
        XCTAssertEqual(content.chapter.purchaseState(for: generation), .available)
        XCTAssertEqual(content.chapter.purchaseState(for: UUID()), .unknown)
        XCTAssertFalse(content.chapter.isOwned, "A zero current quote confirms access, not a purchase transaction")
    }

    func testContentForAnotherChapterOrBookIsRejected() {
        for (key, value) in [("chapId", 124), ("novelId", 457)] {
            var valueObject = payload()
            valueObject[key] = value
            XCTAssertThrowsError(try AppChapterContentProtocol.parse(valueObject, chapter: chapter, generation: UUID()))
        }
        var malformed = payload()
        malformed["chapId"] = true
        XCTAssertThrowsError(try AppChapterContentProtocol.parse(malformed, chapter: chapter, generation: UUID()))
        XCTAssertThrowsError(try AppChapterContentProtocol.parse(["content": "正文"], chapter: chapter, generation: UUID()))
    }

    func testEncryptedMissingAndNonBooleanFlagsNeverEnterTheReader() {
        let invalidFlags: [Any] = [true, 0, "false", NSNull()]
        for value in invalidFlags {
            XCTAssertThrowsError(try AppChapterContentProtocol.parse(payload(encrypted: value), chapter: chapter, generation: UUID()))
        }
        var object = payload()
        var expansion = object["expand"] as! [String: Any]
        expansion.removeValue(forKey: "isContentEncrypted")
        object["expand"] = expansion
        XCTAssertThrowsError(try AppChapterContentProtocol.parse(object, chapter: chapter, generation: UUID()))
    }

    func testNonzeroOrUnprovenAccessPriceCannotExposeContent() {
        XCTAssertThrowsError(try AppChapterContentProtocol.parse(payload(price: 1), chapter: chapter, generation: UUID())) { error in
            guard case SFAPIError.subscriptionRequired = error else { return XCTFail("Expected an access error") }
        }
        let invalidPrices: [Any] = [false, -1, 0.5, NSNull(), "unknown"]
        for value in invalidPrices {
            XCTAssertThrowsError(try AppChapterContentProtocol.parse(payload(price: value), chapter: chapter, generation: UUID()))
        }
        var object = payload()
        var expansion = object["expand"] as! [String: Any]
        expansion.removeValue(forKey: "needFireMoney")
        object["expand"] = expansion
        XCTAssertThrowsError(try AppChapterContentProtocol.parse(object, chapter: chapter, generation: UUID()))
    }

    func testEmptyContentIsAnErrorAndFreeContentDoesNotInventAnAccountPermission() throws {
        XCTAssertThrowsError(try AppChapterContentProtocol.parse(payload(text: " \r\n "), chapter: chapter, generation: UUID())) { error in
            guard case SFAPIError.emptyContent = error else { return XCTFail("Expected empty content error") }
        }
        var free = payload()
        free["isVip"] = false
        let content = try AppChapterContentProtocol.parse(free, chapter: chapter, generation: UUID())
        XCTAssertEqual(content.text, "这是测试正文。", "Free App chapters need the same single-pass restoration")
        XCTAssertEqual(content.sourceFormatVersion, 4)
        XCTAssertFalse(content.chapter.isVIP)
        XCTAssertNil(content.chapter.confirmedPurchaseState)
        XCTAssertNil(content.chapter.purchaseSessionGeneration)
    }

    func testRequestExplicitlyDisablesAutomaticOrderingAndHasNoMutationBody() async throws {
        let plan = try AppChapterContentProtocol.request(for: chapter)
        XCTAssertEqual(plan.path, "/Chaps/123")
        XCTAssertEqual(plan.query, ["expand": "content", "autoOrder": "false"])
        let api = SFAPI(loadPersistedSessions: false)
        let request = try await api.appRequest(path: plan.path, query: plan.query, body: nil, includeSession: true, method: "GET")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "autoOrder" })?.value, "false")
        var invalid = chapter
        invalid.id = 0
        XCTAssertThrowsError(try AppChapterContentProtocol.request(for: invalid))
    }

    func testMissingSessionAndChangedAccountStopBeforeAnyContentRequest() async {
        let api = SFAPI(loadPersistedSessions: false)
        do {
            _ = try await api.appContent(chapter: chapter)
            XCTFail("A verified App account is required")
        } catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected error: \(error)") } }
        do {
            _ = try await api.appContent(chapter: chapter, expectedGeneration: UUID())
            XCTFail("The request must not transfer to another account")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
