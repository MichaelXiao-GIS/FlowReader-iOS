import Foundation
import CoreFoundation

struct AuthorProfile: Identifiable, Hashable, Sendable {
    let id: Int
    var accountID: Int? = nil
    var name: String
    var biography: String = ""
    var avatarURL: URL? = nil
    var followerCount: Int? = nil
}

extension SFAPI {
    /// Public author metadata; never attaches either of the reader's account sessions.
    func authorProfile(authorID: Int) async throws -> AuthorProfile {
        let plan = try AuthorProtocol.profileRequest(authorID: authorID)
        let payload = try await appData(path: plan.path, query: plan.query, includeSession: false, method: plan.method)
        return try AuthorProtocol.profile(payload, expectedAuthorID: authorID)
    }

    /// The Android novel endpoint returns the full array and has no page/size arguments.
    /// The comic endpoint is separate; its pagination is not applied to novels.
    func authorBooks(authorID: Int) async throws -> [Book] {
        let plan = try AuthorProtocol.booksRequest(authorID: authorID)
        let payload = try await appData(path: plan.path, query: plan.query, includeSession: false, method: plan.method)
        return try AuthorProtocol.books(payload, expectedAuthorID: authorID)
    }
}

/// APK AuthorApi.getAuthorInfo(long,String) / getAuthorNovels(long), corroborated
/// by anonymous public responses. authorId and accountId are separate identifiers.
enum AuthorProtocol {
    struct Request: Equatable, Sendable {
        let path: String
        let query: [String: String]
        var method: String { "GET" }
    }

    static func profileRequest(authorID: Int) throws -> Request {
        guard authorID > 0 else { throw SFAPIError.invalidIdentifier }
        return Request(path: "/authors", query: ["authorId": String(authorID), "expand": "fansNum"])
    }

    static func booksRequest(authorID: Int) throws -> Request {
        guard authorID > 0 else { throw SFAPIError.invalidIdentifier }
        return Request(path: "/authors/\(authorID)/novels", query: [:])
    }

    static func profile(_ payload: Any, expectedAuthorID: Int) throws -> AuthorProfile {
        guard expectedAuthorID > 0, let object = payload as? [String: Any],
              let authorID = positiveIdentifier(object["authorId"]), authorID == expectedAuthorID,
              let name = text(object["authorName"]) else { throw SFAPIError.invalidResponse }
        let user = object["userInfo"] as? [String: Any]
        let expand = user?["expand"] as? [String: Any]
        let accountID = positiveIdentifier(object["accountId"])
        if let accountID, let nestedID = positiveIdentifier(user?["accountId"]), accountID != nestedID {
            throw SFAPIError.invalidResponse
        }
        return AuthorProfile(id: authorID, accountID: accountID, name: name,
                             biography: HTMLParser.plainText(object["introduce"] as? String ?? ""),
                             avatarURL: AccountProfileParser.avatarURL(in: object),
                             followerCount: nonnegativeInteger(expand?["fansNum"]))
    }

    static func books(_ payload: Any, expectedAuthorID: Int) throws -> [Book] {
        guard expectedAuthorID > 0, let rows = payload as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var seen = Set<Int>()
        var result: [Book] = []
        for row in rows {
            guard let book = SFAPI.parseBook(row), book.authorID == expectedAuthorID else {
                throw SFAPIError.invalidResponse
            }
            // Keep the server's order while tolerating an identical duplicate row.
            if seen.insert(book.id).inserted { result.append(book) }
        }
        return result
    }

    static func positiveIdentifier(_ value: Any?) -> Int? {
        nonnegativeInteger(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number), let value = Int(number.stringValue), value >= 0 else { return nil }
        return value
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
