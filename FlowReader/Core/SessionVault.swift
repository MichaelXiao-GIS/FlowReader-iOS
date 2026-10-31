import Foundation
import Security

/// Only official website session cookies are stored; passwords never enter this store.
enum SessionVault {
    private static let service = "app.boluoyue.flow.web-session"
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String = "sfacg") -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, account: String = "sfacg") throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query(account: account)
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SFAPIError.server("无法安全保存登录状态，请重试。")
            }
        } else if result != errSecSuccess {
            throw SFAPIError.server("无法安全保存登录状态，请重试。")
        }
    }

    static func clear(account: String = "sfacg") { SecItemDelete(query(account: account) as CFDictionary) }
}

struct WebSession: Codable, Sendable {
    struct Cookie: Codable, Sendable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
    }
    var cookies: [Cookie]

    init(cookies: [HTTPCookie], app: Bool = false) {
        self.cookies = cookies.filter {
            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (domain == "sfacg.com" || domain.hasSuffix(".sfacg.com")) && [".SFCommunity", app ? "session_APP" : "session_PC"].contains($0.name)
        }.map { Cookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate) }
    }

    var isAppPresent: Bool {
        cookies.contains { $0.name == "session_APP" && ($0.expires == nil || $0.expires! > Date()) }
    }

    var isPresent: Bool {
        cookies.contains { $0.name == "session_PC" && ($0.expires == nil || $0.expires! > Date()) }
    }

    func header(for url: URL) -> String? {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let valid = cookies.filter {
            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matches = host == domain || ($0.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let pathMatches = $0.path == "/" || url.path == $0.path || url.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/")
            return matches && pathMatches && ($0.expires == nil || $0.expires! > Date())
        }
        let pairs = valid.map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
}
