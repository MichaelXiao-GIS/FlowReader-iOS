import Foundation
import CoreFoundation

extension SFAPI {
    /// Reads only content that the App server already authorizes. Never creates an order.
    func appContent(chapter: Chapter, expectedGeneration: UUID? = nil) async throws -> ChapterContent {
        let generation = sessionGeneration()
        if let expectedGeneration, generation != expectedGeneration { throw CancellationError() }
        let plan = try AppChapterContentProtocol.request(for: chapter)
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        _ = try await accountServiceProfile()
        guard sessionGeneration() == generation else { throw CancellationError() }
        var request = try appRequest(path: plan.path, query: plan.query, body: nil, includeSession: true, method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        let payload = try Self.parseAppResponse(data, response: response)
        let content = try AppChapterContentProtocol.parse(payload, chapter: chapter, generation: generation)
        try Task.checkCancellation()
        guard sessionGeneration() == generation else { throw CancellationError() }
        if content.chapter.isVIP { recordReadableChapter(content.chapter, generation: generation) }
        return content
    }
}

enum AppChapterContentProtocol {
    struct Request: Equatable, Sendable {
        let path: String
        let query: [String: String]
    }

    static func request(for chapter: Chapter) throws -> Request {
        guard chapter.id > 0, chapter.bookID > 0 else { throw SFAPIError.invalidIdentifier }
        // GET can have purchase side effects when autoOrder is enabled, so false is mandatory.
        return Request(path: "/Chaps/\(chapter.id)", query: ["expand": "content", "autoOrder": "false"])
    }

    static func parse(_ payload: Any, chapter: Chapter, generation: UUID) throws -> ChapterContent {
        guard chapter.id > 0, chapter.bookID > 0,
              let object = payload as? [String: Any],
              integer(object["chapId"]) == chapter.id,
              integer(object["novelId"]) == chapter.bookID,
              let isVIP = boolean(object["isVip"]),
              let expansion = object["expand"] as? [String: Any] else { throw SFAPIError.invalidResponse }
        guard let encrypted = boolean(expansion["isContentEncrypted"]) else { throw SFAPIError.invalidResponse }
        guard !encrypted else {
            throw SFAPIError.server("本章使用暂不支持的加密正文格式，请在菠萝包官方应用阅读。")
        }
        guard let price = integer(expansion["needFireMoney"]) else { throw SFAPIError.invalidResponse }
        guard price == 0 else { throw SFAPIError.subscriptionRequired }
        guard let raw = expansion["content"] as? String else { throw SFAPIError.invalidResponse }
        // expand.content is plaintext. Preserve literal angle brackets, entities, emoji and punctuation.
        // Converting it through an HTML stripper would silently remove legitimate story text.
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SFAPIError.emptyContent }
        var authorized = chapter
        authorized.isVIP = isVIP
        if isVIP {
            authorized.confirmedPurchaseState = .available
            authorized.purchaseSessionGeneration = generation
        } else {
            authorized.confirmedPurchaseState = nil
            authorized.purchaseSessionGeneration = nil
        }
        return ChapterContent(chapter: authorized, text: text, sourceFormatVersion: 3)
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
}
