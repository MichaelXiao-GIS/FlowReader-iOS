import Foundation

/// A measured, unsubmitted interval of foreground reading, owned by one App account.
/// `seconds` is a delta, never a day's accumulated reading total.
struct ReadingTimeSubmission: Equatable, Sendable {
    let id: UUID
    let account: AccountProfile
    let generation: UUID
    let bookID: Int
    let chapterID: Int
    let seconds: Int
    let readingDate: String
}

struct ReadingTimeReceipt: Equatable, Sendable {
    let submissionID: UUID
    let generation: UUID
    let confirmedAt: Date
}

enum ReadingTimeSubmissionError: LocalizedError {
    /// Validation, identity preflight, or the transport's explicit pre-dispatch failure.
    case notSent(Error)
    /// The increment may have reached the server. Never replay it automatically.
    case resultUnknown(String)

    var errorDescription: String? {
        switch self {
        case .notSent(let error): return error.localizedDescription
        case .resultUnknown(let message): return "阅读时长提交结果未确认：\(message)"
        }
    }
}

extension SFAPI {
    /// Reports one measured interval only; it neither accepts tasks nor claims rewards.
    func reportReadingTime(_ submission: ReadingTimeSubmission,
                           expectedGeneration: UUID? = nil) async throws -> ReadingTimeReceipt {
        try await ReadingTimeProtocol.submit(submission, expectedGeneration: expectedGeneration,
            currentGeneration: { await self.sessionGeneration() },
            currentAccount: {
                guard await self.hasAppSession() else { throw SFAPIError.loginRequired }
                return try await self.accountServiceProfile()
            }, send: { plan, generation in
                let request: URLRequest
                do {
                    var authenticated = try await self.appRequest(path: plan.path, query: [:], body: plan.body,
                                                                  includeSession: true, method: plan.method)
                    authenticated.cachePolicy = .reloadIgnoringLocalCacheData
                    request = authenticated
                } catch {
                    throw SFRequestNotSent(underlying: error)
                }
                return try await self.send(request, acceptServerErrors: true, expectedGeneration: generation,
                                           reportUnsentFailure: true)
            })
    }
}

/// APK CommonApi.updateReadingTime: PUT /user/readingtime with a JSON body.
/// lw.aa.E0 supplies five fields. lw.qf submits totalSeconds - submittedSeconds,
/// entityType=2 for novels, and formats readingDate with yyyy-MM-dd in GMT+08.
enum ReadingTimeProtocol {
    struct Request: Equatable, Sendable {
        let seconds: Int
        let readingDate: String
        let bookID: Int
        let chapterID: Int
        var method: String { "PUT" }
        var path: String { "/user/readingtime" }
        var body: [String: Any] {
            ["seconds": seconds, "readingDate": readingDate, "entityType": 2,
             "entityId": bookID, "chapterId": chapterID]
        }
    }

    static func serviceDate(for date: Date) -> String { dateFormatter().string(from: date) }

    static func request(for submission: ReadingTimeSubmission) throws -> Request {
        guard submission.account.id > 0, submission.bookID > 0, submission.chapterID > 0 else {
            throw SFAPIError.invalidIdentifier
        }
        // One service-day interval cannot contain more than a day's measured seconds.
        guard (1...86_400).contains(submission.seconds), isServiceDate(submission.readingDate) else {
            throw SFAPIError.invalidResponse
        }
        return Request(seconds: submission.seconds, readingDate: submission.readingDate,
                       bookID: submission.bookID, chapterID: submission.chapterID)
    }

    static func submit(_ submission: ReadingTimeSubmission, expectedGeneration: UUID? = nil,
                       gate: ReadingTimeSubmissionGate = .shared,
                       currentGeneration: @Sendable () async -> UUID,
                       currentAccount: @Sendable () async throws -> AccountProfile,
                       send: @Sendable (Request, UUID) async throws -> (Data, HTTPURLResponse),
                       now: @Sendable () -> Date = { Date() }) async throws -> ReadingTimeReceipt {
        let plan: Request
        do {
            plan = try request(for: submission)
            try Task.checkCancellation()
            if let expectedGeneration, expectedGeneration != submission.generation { throw CancellationError() }
            guard await currentGeneration() == submission.generation else { throw CancellationError() }
            guard await gate.begin(submission.id) else {
                throw SFAPIError.server("这段阅读时长已经尝试提交，不会重复上报。")
            }
            let account = try await currentAccount()
            guard account.id == submission.account.id, account.matchesAccountIdentity(submission.account) else {
                throw SFAPIError.authenticationRequired("阅读账号已变化，这段时长不会转记到其他账号。")
            }
            try Task.checkCancellation()
            guard await currentGeneration() == submission.generation else { throw CancellationError() }
        } catch {
            throw ReadingTimeSubmissionError.notSent(error)
        }

        do {
            let (data, response) = try await send(plan, submission.generation)
            try requireAcknowledgment(data, response: response)
            try Task.checkCancellation()
            guard await currentGeneration() == submission.generation else { throw CancellationError() }
            return ReadingTimeReceipt(submissionID: submission.id, generation: submission.generation, confirmedAt: now())
        } catch let error as SFRequestNotSent {
            throw ReadingTimeSubmissionError.notSent(error.underlying)
        } catch {
            // No idempotency key exists in the APK contract. HTTP errors, malformed
            // envelopes and cancellation after dispatch do not authorize a replay.
            throw ReadingTimeSubmissionError.resultUnknown(error.localizedDescription)
        }
    }

    static func requireAcknowledgment(_ data: Data, response: HTTPURLResponse) throws {
        _ = try SFAPI.parseAppResponse(data, response: response)
    }

    private static func isServiceDate(_ value: String) -> Bool {
        guard value.utf8.count == 10, value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let date = dateFormatter().date(from: value) else { return false }
        return serviceDate(for: date) == value
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

/// Process-local duplicate protection. The caller also consumes each measured delta
/// once; uncertain increments are not persisted for replay after a restart.
actor ReadingTimeSubmissionGate {
    static let shared = ReadingTimeSubmissionGate()
    private let capacity: Int
    private var seen = Set<UUID>()
    private var order: [UUID] = []

    init(capacity: Int = 2_048) { self.capacity = max(1, capacity) }

    func begin(_ id: UUID) -> Bool {
        guard seen.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity { seen.remove(order.removeFirst()) }
        return true
    }
}
