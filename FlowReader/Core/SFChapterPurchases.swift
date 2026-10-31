import Foundation
import CoreFoundation

struct ChapterPurchaseSnapshot: Sendable {
    let states: [Int: ChapterPurchaseState]
    let generation: UUID
}

extension SFAPI {
    /// Reads explicit ownership from the authenticated catalogue. Never places an order.
    func chapterPurchaseStates(bookID: Int) async throws -> ChapterPurchaseSnapshot {
        guard bookID > 0 else { throw SFAPIError.invalidIdentifier }
        let generation = sessionGeneration()
        let verified = verifiedReadableChapterStates(bookID: bookID, generation: generation)
        guard hasAppSession() else {
            guard !verified.isEmpty else { throw SFAPIError.server("连接同一账号的账号服务后，可确认章节购买状态。") }
            return ChapterPurchaseSnapshot(states: verified, generation: generation)
        }
        _ = try await accountServiceProfile()
        // Purchase facts belong to the primary App account; optional Web authorization is
        // checked separately when opening a paid chapter, not when reading this catalogue.
        let request = try appRequest(path: "/novels/\(bookID)/dirs", query: [:], body: nil, includeSession: true, method: "GET")
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        let payload = try Self.parseAppResponse(data, response: response)
        var states = try ChapterPurchaseParser.states(from: payload)
        for (id, state) in verified where states[id] != .purchased { states[id] = state }
        return ChapterPurchaseSnapshot(states: states, generation: generation)
    }
}

enum ChapterPurchaseParser {
    static func states(from payload: Any) throws -> [Int: ChapterPurchaseState] {
        guard let root = payload as? [String: Any],
              let volumes = (root["volumeList"] ?? root["volumes"]) as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var result: [Int: ChapterPurchaseState] = [:]
        for volume in volumes {
            for row in volume["chapterList"] as? [[String: Any]] ?? [] {
                guard let id = positiveInteger(row["chapId"]), boolean(row["isVip"]) == true else { continue }
                let ownership = boolean(row["has"])
                if ownership == true { result[id] = .purchased }
                // A zero account quote confirms readability, not the transaction that granted it.
                else if nonnegativePrice(row["needFireMoney"]) == 0 { result[id] = .available }
                else if ownership == false { result[id] = .notPurchased }
                else { result[id] = .unknown }
            }
        }
        return result
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let integer = Int(exactly: number.doubleValue), integer > 0 { return integer }
        if let text = value as? String, let integer = Int(text), integer > 0 { return integer }
        return nil
    }

    private static func nonnegativePrice(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue), integer >= 0 else { return nil }
        return integer
    }
}
