import Foundation
import CoreFoundation

struct CloudReadingProgress: Identifiable, Hashable, Sendable {
    var id: Int { bookID }
    let bookID: Int
    let chapterID: Int
    var chapterTitle: String? = nil
    let updatedAt: Date?
}

struct CloudReadingSnapshot: Sendable {
    let records: [CloudReadingProgress]
    let generation: UUID
}

struct CloudProgressReceipt: Equatable, Sendable {
    let bookID: Int
    let chapterID: Int
    /// Time this client received the acknowledgment, not a server modification timestamp.
    let confirmedAt: Date
}

extension SFAPI {
    /// The App endpoint returns chapter positions; mobile Web history contains book visits only.
    func cloudReadingHistory() async throws -> CloudReadingSnapshot {
        guard hasAppSession() else { throw SFAPIError.authenticationRequired("连接同一账号的账号服务后，可读取云端阅读位置。") }
        let generation = sessionGeneration()
        let account = try await accountServiceProfile()
        // History belongs to the primary App account. An optional expired Web login must not block it.
        guard generation == sessionGeneration() else { throw CancellationError() }
        var request = try appRequest(path: "/user/NovelViews", query: [:], body: nil, includeSession: true, method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        let payload = try Self.parseAppResponse(data, response: response)
        return CloudReadingSnapshot(records: try CloudProgressParser.readingHistory(payload, accountID: account.id), generation: generation)
    }

    /// Call only for a newly chosen reading position, never when importing local history.
    /// The primary App account is authoritative; Web-only accounts retain the official mobile fallback.
    func recordCloudProgress(bookID: Int, chapterID: Int, expectedGeneration: UUID) async throws -> CloudProgressReceipt {
        guard bookID > 0, chapterID > 0 else { throw SFAPIError.invalidResponse }
        guard sessionGeneration() == expectedGeneration else { throw CancellationError() }
        if hasSavedAppLogin() {
            _ = try await accountServiceProfile()
            try Task.checkCancellation()
            guard sessionGeneration() == expectedGeneration else { throw CancellationError() }
            let plan = try AppCloudProgressProtocol.update(bookID: bookID, chapterID: chapterID)
            let request = try appRequest(path: plan.path, query: [:], body: plan.body, includeSession: true, method: plan.method)
            let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: expectedGeneration)
            _ = try Self.parseAppResponse(data, response: response)
            try Task.checkCancellation()
            guard sessionGeneration() == expectedGeneration else { throw CancellationError() }
            return CloudProgressReceipt(bookID: bookID, chapterID: chapterID, confirmedAt: Date())
        }
        guard hasWebSession() else { throw SFAPIError.authenticationRequired("请先连接账号服务，再同步阅读位置。") }
        let url = URL(string: "https://m.sfacg.com/API/Book.ashx?op=addviewrecord")!
        var request = webRequest(url: url, referer: URL(string: "https://m.sfacg.com/c/\(chapterID)/"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = Data("bookid=\(bookID)&articleid=\(chapterID)".utf8)
        let (data, _) = try await send(request, expectedGeneration: expectedGeneration)
        try Task.checkCancellation()
        guard sessionGeneration() == expectedGeneration else { throw CancellationError() }
        try CloudProgressParser.requireAcknowledgment(data)
        return CloudProgressReceipt(bookID: bookID, chapterID: chapterID, confirmedAt: Date())
    }
}

enum AppCloudProgressProtocol {
    struct Request: Sendable {
        let path: String
        let method: String
        let chapterID: Int
        var body: [String: Any] {
            // The official Android request also supplies this flag. Disable the optional
            // card-drop action: this reader only reports the chapter actually opened.
            ["chapterId": chapterID, "triggerCardPieceDrop": false]
        }
    }

    static func update(bookID: Int, chapterID: Int) throws -> Request {
        guard bookID > 0, chapterID > 0 else { throw SFAPIError.invalidIdentifier }
        return Request(path: "/user/NovelViews/\(bookID)", method: "PUT", chapterID: chapterID)
    }
}

enum CloudProgressParser {
    static func readingHistory(_ payload: Any, accountID: Int) throws -> [CloudReadingProgress] {
        guard accountID > 0, let rows = payload as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var order: [Int] = []
        var records: [Int: CloudReadingProgress] = [:]
        for row in rows {
            guard integer(row["accountId"]) == accountID else { throw SFAPIError.invalidResponse }
            guard let bookID = integer(row["novelId"]), bookID > 0 else { throw SFAPIError.invalidResponse }
            // A visit with no chapter is not a reading position.
            guard let chapterID = integer(row["chapterId"]), chapterID > 0 else { continue }
            let position = CloudReadingProgress(bookID: bookID, chapterID: chapterID, updatedAt: parseTimestamp(row["lastViewTime"] as? String))
            if let previous = records[bookID] {
                if let previousDate = previous.updatedAt, let date = position.updatedAt, date > previousDate { records[bookID] = position }
            } else {
                order.append(bookID)
                records[bookID] = position
            }
        }
        return order.compactMap { records[$0] }
    }

    /// Unzoned server dates cannot safely be compared with this device's local progress dates.
    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: "(?:Z|[+-][0-9]{2}:?[0-9]{2})$", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    static func requireAcknowledgment(_ data: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = integer(object["status"]) else { throw SFAPIError.invalidResponse }
        let message = (object["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 401 || status == 403 || status == 502 {
            throw SFAPIError.authenticationRequired(message.flatMap { $0.isEmpty ? nil : $0 } ?? "网页登录已过期，请重新连接。")
        }
        guard status == 200 else {
            throw SFAPIError.server(message.flatMap { $0.isEmpty ? nil : $0 } ?? "阅读位置尚未同步，请稍后重试。")
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return Int(exactly: number.doubleValue) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
