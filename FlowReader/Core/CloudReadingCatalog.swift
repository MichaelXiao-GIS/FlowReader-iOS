import Foundation
import CoreFoundation

extension SFAPI {
    /// Percentages require a complete directory. The reader's tolerant catalog parser may
    /// skip malformed chapters, which must never silently become a smaller denominator.
    func cloudProgressChapters(bookID: Int) async throws -> [Chapter] {
        guard bookID > 0 else { throw SFAPIError.invalidIdentifier }
        let payload = try await appData(path: "/novels/\(bookID)/dirs")
        return try CloudReadingCatalog.parseChapters(payload, bookID: bookID)
    }
}

/// A chapter location, not a claim that the current chapter has been finished.
struct CloudReadingCatalog: Sendable {
    let positions: [Int: Int]
    var count: Int { positions.count }

    init(bookID: Int, chapters: [Chapter]) throws {
        guard bookID > 0, !chapters.isEmpty,
              chapters.allSatisfy({ $0.bookID == bookID && $0.id > 0 }),
              Set(chapters.map(\.id)).count == chapters.count else { throw SFAPIError.invalidResponse }
        // order comes from the official volume/chapter sequence. IDs are not ordinal positions.
        let ordered = chapters.enumerated().sorted {
            $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order
        }
        positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.element.id, $0.offset) })
    }

    func fraction(chapterID: Int) -> Double? {
        guard let position = positions[chapterID], count > 0 else { return nil }
        return Double(position) / Double(count)
    }

    static func parseChapters(_ payload: Any, bookID: Int) throws -> [Chapter] {
        guard bookID > 0, let object = payload as? [String: Any],
              let volumes = (object["volumeList"] ?? object["volumes"]) as? [[String: Any]], !volumes.isEmpty else {
            throw SFAPIError.invalidResponse
        }
        var result: [Chapter] = []
        var seen = Set<Int>()
        var volumeIDs = Set<Int>()
        for volume in volumes {
            guard let volumeID = integer(volume["volumeId"]), volumeID > 0, volumeIDs.insert(volumeID).inserted,
                  let rows = volume["chapterList"] as? [[String: Any]] else { throw SFAPIError.invalidResponse }
            for row in rows {
                guard let id = integer(row["chapId"]), id > 0, seen.insert(id).inserted else { throw SFAPIError.invalidResponse }
                if let owner = row["novelId"], integer(owner) != bookID { throw SFAPIError.invalidResponse }
                result.append(Chapter(id: id, bookID: bookID, volumeID: volumeID,
                    volumeTitle: volume["title"] as? String ?? "正文", title: row["ntitle"] as? String ?? row["title"] as? String ?? "章节",
                    order: result.count, isVIP: row["isVip"] as? Bool ?? false))
            }
        }
        guard !result.isEmpty else { throw SFAPIError.invalidResponse }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return Int(exactly: number.doubleValue) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

/// Shared by visible-card requests, including requests queued before a fast scroll or account change.
actor CloudCatalogRequestGate {
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(limit: Int = 2) { self.limit = max(1, limit) }

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { active = max(0, active - 1) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
