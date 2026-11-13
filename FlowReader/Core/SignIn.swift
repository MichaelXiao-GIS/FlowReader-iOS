import Foundation
import CoreFoundation

struct SignInStatus: Equatable, Sendable {
    let signedToday: Bool?
    let consecutiveDays: Int?
}

struct SignInReward: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let quantity: Int
}

struct SignInReceipt: Equatable, Sendable {
    let alreadySigned: Bool
    let rewards: [SignInReward]
}

extension SFAPI {
    func signInStatus() async throws -> SignInStatus {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        let generation = sessionGeneration()
        let status = try await SignInProtocol.loadStatus { plan in
            try await self.signInPayload(plan, generation: generation)
        }
        guard sessionGeneration() == generation else { throw CancellationError() }
        return status
    }

    /// Called only by the user's explicit sign-in button, never on app launch or refresh.
    func signInToday(expectedGeneration: UUID? = nil) async throws -> SignInReceipt {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        let generation = sessionGeneration()
        if let expectedGeneration, expectedGeneration != generation { throw CancellationError() }
        let plan = SignInProtocol.submission(at: Date())
        do {
            let payload = try await signInPayload(plan, generation: generation)
            return SignInProtocol.receipt(from: payload)
        } catch {
            if SignInProtocol.isAlreadySignedError(error) {
                return SignInReceipt(alreadySigned: true, rewards: [])
            }
            throw error
        }
    }

    private func signInPayload(_ plan: SignInProtocol.Request, generation: UUID) async throws -> Any {
        let request = try appRequest(path: plan.path, query: [:], body: plan.body, includeSession: true, method: plan.method)
        let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
        return try Self.parseAppResponse(data, response: response)
    }
}

enum SignInProtocol {
    struct Request: Sendable {
        let path: String
        let method: String
        let body: [String: String]?
    }
    static let statusRequest = Request(path: "/user/signInfo", method: "GET", body: nil)
    static let streakRequest = Request(path: "/user/sign/continueDay", method: "GET", body: nil)

    static func loadStatus(fetch: @Sendable (Request) async throws -> Any) async throws -> SignInStatus {
        async let calendar = signedToday(from: fetch(statusRequest))
        async let total = streak(from: fetch(streakRequest))

        let signed: Bool?
        do { signed = try await calendar }
        catch {
            try propagateSessionOrCancellation(error)
            signed = nil
        }
        let days: Int?
        do { days = try await total }
        catch {
            try propagateSessionOrCancellation(error)
            guard signed != nil else { throw error }
            days = nil
        }
        try Task.checkCancellation()
        return SignInStatus(signedToday: signed, consecutiveDays: days)
    }

    private static func propagateSessionOrCancellation(_ error: Error) throws {
        try Task.checkCancellation()
        if SFAPI.isAuthenticationFailure(error) || AccountShelfState.isCancellation(error) { throw error }
    }

    /// The reference date helper explicitly formats the UTC+8 service day.
    static func submission(at date: Date) -> Request {
        Request(path: "/user/newSignInfo", method: "PUT", body: ["signDate": serviceDay(at: date)])
    }

    static func serviceDay(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func signedToday(from payload: Any) throws -> Bool? {
        // The authenticated legacy endpoint returns a calendar collection (including []).
        // It does not establish today's status for the newer sign-in action.
        if payload is [Any] { return nil }
        guard let object = payload as? [String: Any] else { throw SFAPIError.invalidResponse }
        // Do not treat missing or unrecognised fields as a successful "not signed" response.
        return ["isSigned", "signedToday", "hasSigned", "isSignIn"].compactMap { boolean(object[$0]) }.first
    }

    static func streak(from payload: Any) throws -> Int {
        guard let object = payload as? [String: Any], let days = integer(object["totalContinueDays"]) else {
            throw SFAPIError.invalidResponse
        }
        return days
    }

    static func receipt(from payload: Any) -> SignInReceipt {
        // PUT's successful envelope is authoritative; rewards are optional display metadata.
        let rows = payload as? [[String: Any]] ?? []
        let rewards = rows.enumerated().compactMap { index, row -> SignInReward? in
            guard let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let count = integer(row["num"]) else { return nil }
            return SignInReward(id: "\(index)-\(name)", name: name, quantity: count)
        }
        return SignInReceipt(alreadySigned: false, rewards: rewards)
    }

    static func isAlreadySignedError(_ error: Error) -> Bool {
        guard case SFAPIError.server(let message) = error else { return false }
        return ["该日期已签到", "今日已签到", "今天已经签到"].contains { message.hasPrefix($0) }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0 { return Int(exactly: number.doubleValue) }
        if let text = value as? String, let number = Int(text), number >= 0 { return number }
        return nil
    }
}
