import XCTest
@testable import FlowReader

final class AuthorProtocolTests: XCTestCase {
    private var author: [String: Any] {
        ["authorId": 73, "accountId": 940, "authorName": "原创测试作者", "introduce": "<p>写下新的故事。</p>",
         "avatar": "//avatar.sfacg.com/fixture-author.jpg", "userInfo": ["accountId": 940, "expand": ["fansNum": 16]]]
    }

    private func book(_ id: Int, authorID: Int = 73) -> [String: Any] {
        ["novelId": id, "novelName": "原创作品\(id)", "authorId": authorID, "authorName": "原创测试作者",
         "novelCover": "https://book.sfacg.com/fixture-cover.jpg", "charCount": 1_500, "isFinish": true]
    }

    func testAPKPublicGETContractsDoNotInventNovelPagination() throws {
        let profile = try AuthorProtocol.profileRequest(authorID: 73)
        XCTAssertEqual(profile.method, "GET")
        XCTAssertEqual(profile.path, "/authors")
        XCTAssertEqual(profile.query, ["authorId": "73", "expand": "fansNum"])
        let works = try AuthorProtocol.booksRequest(authorID: 73)
        XCTAssertEqual(works.method, "GET")
        XCTAssertEqual(works.path, "/authors/73/novels")
        XCTAssertTrue(works.query.isEmpty)
        XCTAssertThrowsError(try AuthorProtocol.profileRequest(authorID: 0))
        XCTAssertThrowsError(try AuthorProtocol.booksRequest(authorID: -1))
    }

    func testAuthorIdentityIsNotAccountIdentityAndOnlyConfirmedFieldsAreDisplayed() throws {
        let profile = try AuthorProtocol.profile(author, expectedAuthorID: 73)
        XCTAssertEqual(profile.id, 73)
        XCTAssertEqual(profile.accountID, 940)
        XCTAssertEqual(profile.name, "原创测试作者")
        XCTAssertEqual(profile.biography, "写下新的故事。")
        XCTAssertEqual(profile.avatarURL?.absoluteString, "https://avatar.sfacg.com/fixture-author.jpg")
        XCTAssertEqual(profile.followerCount, 16)
        var minimal = author
        for key in ["accountId", "introduce", "avatar", "userInfo"] { minimal.removeValue(forKey: key) }
        let missing = try AuthorProtocol.profile(minimal, expectedAuthorID: 73)
        XCTAssertNil(missing.accountID)
        XCTAssertNil(missing.avatarURL)
        XCTAssertNil(missing.followerCount)
        XCTAssertEqual(missing.biography, "")
    }

    func testMalformedIdentityOrMismatchedProfileCannotNavigateToDifferentAuthor() {
        XCTAssertThrowsError(try AuthorProtocol.profile(author, expectedAuthorID: 940))
        for id: Any in [0, -1, true, "73", 73.5, NSNull()] {
            var row = author; row["authorId"] = id
            XCTAssertThrowsError(try AuthorProtocol.profile(row, expectedAuthorID: 73))
        }
        var conflicting = author
        conflicting["userInfo"] = ["accountId": 941]
        XCTAssertThrowsError(try AuthorProtocol.profile(conflicting, expectedAuthorID: 73))
    }

    func testMalformedFollowerCountRemainsUnknownInsteadOfZero() throws {
        for count: Any in [true, -1, "16", 2.5, NSNull()] {
            var row = author
            row["userInfo"] = ["accountId": 940, "expand": ["fansNum": count]]
            XCTAssertNil(try AuthorProtocol.profile(row, expectedAuthorID: 73).followerCount)
        }
        var zero = author
        zero["userInfo"] = ["expand": ["fansNum": 0]]
        XCTAssertEqual(try AuthorProtocol.profile(zero, expectedAuthorID: 73).followerCount, 0)
    }

    func testCompleteNovelArrayKeepsServerOrderAndRejectsMixedAuthorRows() throws {
        let books = try AuthorProtocol.books([book(62), book(8), book(62)], expectedAuthorID: 73)
        XCTAssertEqual(books.map(\.id), [62, 8])
        XCTAssertEqual(books.map(\.authorID), [73, 73])
        XCTAssertTrue(books[0].isFinished)
        XCTAssertEqual(books[0].wordCount, 1_500)
        XCTAssertTrue(try AuthorProtocol.books([], expectedAuthorID: 73).isEmpty)
        XCTAssertThrowsError(try AuthorProtocol.books([book(62), book(8, authorID: 74)], expectedAuthorID: 73))
        XCTAssertThrowsError(try AuthorProtocol.books(["items": [book(62)]], expectedAuthorID: 73))
        XCTAssertThrowsError(try AuthorProtocol.books([book(62), ["authorId": 73]], expectedAuthorID: 73))
    }

    func testBookMetadataReadsAuthorIDButDoesNotDeriveItFromNameOrAccountID() throws {
        XCTAssertEqual(SFAPI.parseBook(book(62))?.authorID, 73)
        var row = book(62)
        row.removeValue(forKey: "authorId")
        row["accountId"] = 940
        XCTAssertNil(try XCTUnwrap(SFAPI.parseBook(row)).authorID)
        for id: Any in [0, -1, true, "73", NSNull()] {
            row["authorId"] = id
            XCTAssertNil(try XCTUnwrap(SFAPI.parseBook(row)).authorID)
        }
    }

    func testExistingBookIndexesWithoutAuthorIDRemainDecodable() throws {
        let original = try XCTUnwrap(SFAPI.parseBook(book(62)))
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Book.self, from: encoded).authorID, 73)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "authorID")
        let restored = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.author, original.author)
        XCTAssertNil(restored.authorID)
    }

    func testPublicAuthorRequestCarriesNoReaderSessionOrMutationBody() async throws {
        let api = SFAPI(loadPersistedSessions: false)
        for plan in [try AuthorProtocol.profileRequest(authorID: 73), try AuthorProtocol.booksRequest(authorID: 73)] {
            let request = try await api.appRequest(path: plan.path, query: plan.query, body: nil,
                                                  includeSession: false, method: plan.method)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "api.sfacg.com")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
    }
}
