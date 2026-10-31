import Foundation

/// A public pocket may return HTTP 500 for audio/video collections. Keep usable text
/// sections while reporting incomplete sync; authentication and cancellation remain fatal.
struct WebBookshelfLoader {
    typealias Fetch = @Sendable (URL, URL) async throws -> String

    static func load(accountName: String, publicFetch: Fetch? = nil, fetch: Fetch) async throws -> BookshelfSyncResult {
        guard !accountName.isEmpty, accountName.count <= 80,
              accountName.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else {
            throw SFAPIError.invalidResponse
        }
        let root = URL(string: "https://p.sfacg.com/u/\(accountName)/")!
        let index = URL(string: "https://p.sfacg.com/u/content/\(accountName)-0-1")!
        let catalog: String
        do { catalog = try await fetch(index, root) }
        catch {
            try propagateSessionOrCancellation(error)
            throw SFAPIError.server("网页书架分类列表读取失败。\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let sections = pockets(in: catalog)
        var books: [Book] = []
        var known = Set<Int>()
        var loadedSections = 0
        var failedSections = 0
        var firstFailure: Error?

        for (id, name) in sections {
            try Task.checkCancellation()
            let firstURL = URL(string: "https://p.sfacg.com/p/\(id)/")!
            do {
                let firstPage = try await fetch(firstURL, root)
                try Task.checkCancellation()
                loadedSections += 1
                append(try await booksWithAuthors(firstPage, shelfName: name, url: firstURL, referer: root, publicFetch: publicFetch), to: &books, known: &known)
                let pages = pageCount(in: firstPage, pocketID: id)
                if pages > 1 {
                    for page in 2...pages {
                        let url = URL(string: "https://p.sfacg.com/p/\(id)/\(page)/")!
                        let html = try await fetch(url, firstURL)
                        try Task.checkCancellation()
                        append(try await booksWithAuthors(html, shelfName: name, url: url, referer: firstURL, publicFetch: publicFetch), to: &books, known: &known)
                    }
                }
            } catch {
                try propagateSessionOrCancellation(error)
                failedSections += 1
                if firstFailure == nil { firstFailure = error }
            }
        }
        if !sections.isEmpty, loadedSections == 0 {
            throw SFAPIError.server("网页书架的 \(failedSections) 个分类均未能读取。\(firstFailure?.localizedDescription ?? "请稍后重试。")")
        }
        return BookshelfSyncResult(books: books, failedSectionCount: failedSections)
    }

    private static func append(_ incoming: [Book], to books: inout [Book], known: inout Set<Int>) {
        books.append(contentsOf: incoming.filter { known.insert($0.id).inserted })
    }

    private static func booksWithAuthors(_ html: String, shelfName: String, url: URL, referer: URL, publicFetch: Fetch?) async throws -> [Book] {
        let books = parseBooks(html, shelfName: shelfName)
        guard let publicFetch, books.contains(where: { $0.author == "未知作者" }) else { return books }
        do {
            // Signed-in pockets may use a compact template that omits authors entirely.
            // The public view of the same page supplies names without one detail request per book.
            let publicHTML = try await publicFetch(url, referer)
            try Task.checkCancellation()
            let authors = Dictionary(parseBooks(publicHTML, shelfName: shelfName)
                .filter { $0.author != "未知作者" }.map { ($0.id, $0.author) }, uniquingKeysWith: { first, _ in first })
            return books.map { book in
                var enriched = book
                if enriched.author == "未知作者", let author = authors[book.id] { enriched.author = author }
                return enriched
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // Failure of optional public metadata must not erase an authenticated private shelf.
            return books
        }
    }

    private static func propagateSessionOrCancellation(_ error: Error) throws {
        if Task.isCancelled { throw CancellationError() }
        if error is CancellationError { throw error }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { throw error }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorCancelled { throw error }
        if case SFAPIError.loginRequired = error { throw error }
        if case SFAPIError.authenticationRequired = error { throw error }
        if case SFAPIError.httpStatus(let code) = error, code == 401 || code == 403 { throw error }
    }

    static func pockets(in html: String) -> [(Int, String)] {
        var sections: [(Int, String)] = []
        for match in HTMLParser.matches("href=['\"]/p/(\\d+)/['\"][^>]*>(.*?)</a>", in: html) {
            guard let id = Int(match[1]), id > 0, !sections.contains(where: { $0.0 == id }) else { continue }
            let name = HTMLParser.plainText(match[2])
            sections.append((id, name.isEmpty ? "未分类" : name))
        }
        return sections
    }

    static func pageCount(in html: String, pocketID: Int) -> Int {
        min(100, max(1, HTMLParser.matches("/p/\(pocketID)/(\\d+)/", in: html).compactMap { Int($0[1]) }.max() ?? 1))
    }

    static func parseBooks(_ html: String, shelfName: String) -> [Book] {
        HTMLParser.matches("<ul\\b[^>]*>.*?</ul>", in: html).compactMap { card in
            let markup = card[0]
            guard let idString = HTMLParser.first("(?:https?:)?//book\\.sfacg\\.com/Novel/(\\d+)/", in: markup),
                  let id = Int(idString), id > 0,
                  let titleHTML = HTMLParser.first("<b>\\s*<a\\b[^>]*>(.*?)</a>", in: markup) else { return nil }
            let title = HTMLParser.plainText(titleHTML)
            guard !title.isEmpty else { return nil }
            let author = authorName(in: markup) ?? "未知作者"
            let cover = HTMLParser.first("<img\\b[^>]*src=['\"]([^'\"]+)", in: markup).flatMap(coverURL)
            return Book(id: id, title: title, author: author, coverURL: cover, shelfName: shelfName)
        }
    }

    private static func authorName(in markup: String) -> String? {
        // Public pocket pages place the author in a link, followed by a separate rating link.
        let linked = HTMLParser.first("作者\\s*[：:]\\s*<a\\b[^>]*>(.*?)</a>", in: markup).map(HTMLParser.plainText)
        let text = HTMLParser.plainText(markup)
        let line = HTMLParser.first("作者\\s*[：:]\\s*([^\\n]+)", in: text)
        let plain = line.map { HTMLParser.replace("\\s*/\\s*综合信息[：:].*$", in: $0, with: "") }
        guard let name = (linked ?? plain)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    private static func coverURL(_ raw: String) -> URL? {
        let value = HTMLParser.decodeEntities(raw)
        guard var components = URLComponents(string: value.hasPrefix("//") ? "https:" + value : value),
              components.scheme == "https" || components.scheme == "http", components.host != nil else { return nil }
        components.scheme = "https"
        return components.url
    }
}
