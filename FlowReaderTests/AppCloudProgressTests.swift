import XCTest
@testable import FlowReader

final class AppCloudProgressTests: XCTestCase {
    func testAPKContractUsesPUTWithChapterJSONAndDisablesCardDrop() async throws {
        let plan = try AppCloudProgressProtocol.update(bookID: 123, chapterID: 456)
        XCTAssertEqual(plan.path, "/user/NovelViews/123")
        XCTAssertEqual(plan.method, "PUT")
        let api = SFAPI(loadPersistedSessions: false)
        let request = try await api.appRequest(path: plan.path, query: [:], body: plan.body, includeSession: true, method: plan.method)
        XCTAssertEqual(request.url?.absoluteString, "https://api.sfacg.com/user/NovelViews/123")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["chapterId", "triggerCardPieceDrop"])
        XCTAssertEqual(object["chapterId"] as? Int, 456)
        XCTAssertEqual(object["triggerCardPieceDrop"] as? Bool, false)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"), "An unsigned test request must not attach a real session")
    }

    func testInvalidIdentifiersCannotProduceProgressMutation() {
        for (book, chapter) in [(0, 456), (123, 0), (-1, 456), (123, -1)] {
            XCTAssertThrowsError(try AppCloudProgressProtocol.update(bookID: book, chapterID: chapter))
        }
    }

    func testStaleGenerationAndMissingSessionsStopBeforeNetwork() async {
        let api = SFAPI(loadPersistedSessions: false)
        do {
            _ = try await api.recordCloudProgress(bookID: 123, chapterID: 456, expectedGeneration: UUID())
            XCTFail("An old account generation must never submit progress")
        } catch { XCTAssertTrue(error is CancellationError) }
        let generation = await api.sessionGeneration()
        do {
            _ = try await api.recordCloudProgress(bookID: 123, chapterID: 456, expectedGeneration: generation)
            XCTFail("A missing session must never submit progress")
        } catch {
            guard case SFAPIError.authenticationRequired = error else { return XCTFail("Unexpected: \(error)") }
        }
    }
}
