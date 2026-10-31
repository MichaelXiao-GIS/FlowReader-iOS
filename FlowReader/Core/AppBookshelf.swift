import Foundation
import CoreFoundation

extension SFAPI {
    /// PocketApi returns the whole collection in one request; it has no page/size parameters.
    func appBookshelfSync(expectedGeneration: UUID? = nil) async throws -> BookshelfSyncResult {
        let generation = sessionGeneration()
        if let expectedGeneration, generation != expectedGeneration { throw CancellationError() }
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        let account = try await accountServiceProfile()
        guard generation == sessionGeneration() else { throw CancellationError() }
        var request = try appRequest(path: "/user/Pockets", query: ["expand": AppBookshelfProtocol.expand],
                                     body: nil, includeSession: true, method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        try Task.checkCancellation()
        return try AppBookshelfProtocol.parse(Self.parseAppResponse(data, response: response), accountID: account.id)
    }
}

enum AppBookshelfProtocol {
    // The Android ShelfViewModel requests this expansion for its complete collection.
    static let expand = "novels,comics,albums,latestchapter"

    static func parse(_ payload: Any, accountID: Int) throws -> BookshelfSyncResult {
        guard accountID > 0, let pockets = payload as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var books: [Book] = []
        var positions: [Int: Int] = [:]
        var seenPockets = Set<Int>()
        var failedSections = 0
        for pocket in pockets {
            guard integer(pocket["accountId"]) == accountID,
                  let pocketID = integer(pocket["pocketId"]), pocketID > 0, seenPockets.insert(pocketID).inserted,
                  let type = integer(pocket["typeId"]) else { throw SFAPIError.invalidResponse }
            // Pocket.build in the APK: 1=comics, 2=novels, 3=albums, 4=chatNovels.
            if [1, 3, 4].contains(type) { continue }
            guard type == 2, let name = text(pocket["name"]),
                  let expansion = pocket["expand"] as? [String: Any],
                  let novels = expansion["novels"] as? [[String: Any]] else {
                failedSections += 1
                continue
            }
            var sectionIsIncomplete = false
            for row in novels {
                guard let book = book(from: row, shelfName: name) else {
                    sectionIsIncomplete = true
                    continue
                }
                if let index = positions[book.id] {
                    // A duplicate in another pocket is the same work, not a second library entry.
                    // Prefer known metadata without discarding the first category and stable order.
                    if books[index].author == "未知作者", book.author != "未知作者" { books[index].author = book.author }
                    if books[index].coverURL == nil { books[index].coverURL = book.coverURL }
                    if books[index].latestChapter == nil { books[index].latestChapter = book.latestChapter }
                } else {
                    positions[book.id] = books.count
                    books.append(book)
                }
            }
            if sectionIsIncomplete { failedSections += 1 }
        }
        // A malformed expansion must never replace an existing library with a false empty result.
        guard failedSections == 0 || !books.isEmpty else { throw SFAPIError.invalidResponse }
        return BookshelfSyncResult(books: books, failedSectionCount: failedSections)
    }

    private static func book(from row: [String: Any], shelfName: String) -> Book? {
        guard let id = integer(row["novelId"]), id > 0, let title = text(row["novelName"]) else { return nil }
        let expansion = row["expand"] as? [String: Any] ?? [:]
        let latest = (expansion["latestchapter"] ?? expansion["latestChapter"]) as? [String: Any]
        return Book(id: id, title: title, author: text(row["authorName"]) ?? "未知作者",
                    coverURL: text(row["novelCover"]).flatMap(remoteURL),
                    isFinished: boolean(row["isFinish"]) ?? false,
                    wordCount: integer(row["charCount"]),
                    latestChapter: text(latest?["title"]) ?? text(latest?["ntitle"]),
                    updatedAt: text(row["lastUpdateTime"]), shelfName: shelfName)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let integer = Int(exactly: number.doubleValue), integer >= 0 { return integer }
        if let text = value as? String, let integer = Int(text), integer >= 0 { return integer }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func remoteURL(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value.hasPrefix("//") ? "https:" + value : value),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.scheme == "https" || parts.scheme == "http" else { return nil }
        if parts.scheme == "http" { parts.scheme = "https" }
        return parts.url
    }
}
