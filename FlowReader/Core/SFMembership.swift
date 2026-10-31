import Foundation
import CoreFoundation

/// Account-level benefits are independent from ownership of an individual paid chapter.
enum MembershipSource: String, Sendable { case app, web }

struct MembershipInfo: Equatable, Sendable {
    var source: MembershipSource = .app
    var vipLevel: Int?
    var vipName: String?
    var system: String?
    var isMember: Bool?
    var membershipName: String?
    var expiresAt: String?
    var needsLegacyLevelLookup: Bool { system == "legacy" && vipLevel == nil }
}

extension SFAPI {
    func membership() async throws -> MembershipInfo {
        if hasAppSession() {
            guard let user = try await appData(path: "/user", query: ["expand": "vipInfo,newVip,member,dianyamember"], includeSession: true) as? [String: Any] else { throw SFAPIError.invalidResponse }
            var result = MembershipParser.appUser(user)
            if result.needsLegacyLevelLookup {
                do {
                    if let money = try await appData(path: "/user/money", includeSession: true) as? [String: Any] {
                        result.vipLevel = Self.integer(money["vipLevel"])
                        result.system = result.vipLevel == nil ? result.system : "legacy"
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw error }
                    if let apiError = error as? SFAPIError {
                        switch apiError {
                        case .loginRequired, .authenticationRequired: throw error
                        default: break
                        }
                    }
                    // An unavailable balance endpoint must not invent a VIP level.
                }
            }
            return result
        }
        guard hasWebSession() else { throw SFAPIError.loginRequired }
        let referer = URL(string: "https://pages.sfacg.com/h5/app/common/help/Vip.html")!
        let payload = try await membershipWebData(url: URL(string: "https://pages.sfacg.com/api/User?expand=newVip")!, referer: referer)
        var result = MembershipParser.appUser(payload)
        result.source = .web
        if result.system == "new" { return result }
        guard result.system == "legacy" else { throw SFAPIError.invalidResponse }
        let legacy = try await membershipWebData(url: URL(string: "https://pages.sfacg.com/api/common/vipInfo")!, referer: referer)
        var legacyResult = result
        legacyResult.vipLevel = Self.integer(legacy["vipLevel"])
        legacyResult.system = "legacy"
        return legacyResult
    }

    private func membershipWebData(url: URL, referer: URL) async throws -> [String: Any] {
        var request = webRequest(url: url, referer: referer)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        let (data, _) = try await send(request)
        guard let text = String(data: data, encoding: .utf8) else { throw SFAPIError.invalidResponse }
        return try MembershipParser.webPayload(text)
    }
}

enum MembershipParser {
    static func appUser(_ user: [String: Any]) -> MembershipInfo {
        let expand = user["expand"] as? [String: Any] ?? [:]
        let newVip = expand["newVip"] as? [String: Any] ?? [:]
        let oldVip = expand["vipInfo"] as? [String: Any] ?? [:]
        let isNew = boolean(newVip["isNewVip"])
        let level: Int?
        switch isNew {
        case true: level = integer(newVip["level"])
        case false: level = integer(oldVip["vipLevel"]) ?? integer(user["vipLevel"])
        case nil: level = nil
        }
        return MembershipInfo(
            vipLevel: level,
            vipName: isNew == true ? nonempty(newVip["name"]) : nil,
            system: isNew.map { $0 ? "new" : "legacy" },
            isMember: nil,
            membershipName: nil,
            expiresAt: nil
        )
    }

    static func webPayload(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let status = object["status"] as? [String: Any] else { throw SFAPIError.invalidResponse }
        let code = integer(status["errorCode"]) ?? integer(status["httpCode"])
        if code != 200 {
            let message = nonempty(status["msg"]) ?? nonempty(status["errorMessage"]) ?? nonempty(status["message"])
            if code == 401 || code == 403 || message.map({ ["未登录", "请登录", "请先登录", "登录已过期", "登录状态失效"].contains(where: $0.contains) }) == true { throw SFAPIError.authenticationRequired(message ?? "登录状态已过期，请重新登录。") }
            if let message { throw SFAPIError.server(message) }
            throw SFAPIError.invalidResponse
        }
        guard let data = object["data"] as? [String: Any] else { throw SFAPIError.invalidResponse }
        return data
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0 { return Int(exactly: number.doubleValue) }
        if let string = value as? String, let number = Int(string), number >= 0 { return number }
        return nil
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }
}
