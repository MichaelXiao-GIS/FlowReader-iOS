import Foundation

/// The Android Account model exposes `avatar` directly to its image loader.
/// Keep the same field across profile, wallet and membership responses.
enum AccountProfileParser {
    static func avatarURL(in user: [String: Any]) -> URL? {
        (user["avatar"] as? String).flatMap(avatarURL)
    }

    static func webAvatarURL(in response: String) -> URL? {
        ["avatar", "userAvatar", "portrait", "headImg", "headimg"]
            .compactMap { HTMLParser.jsField($0, in: response).flatMap(avatarURL) }.first
    }

    static func avatarURL(_ source: String) -> URL? {
        let cleaned = HTMLParser.decodeEntities(source)
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = cleaned.hasPrefix("//") ? "https:" + cleaned : cleaned
        guard var parts = URLComponents(string: absolute), let host = parts.host, !host.isEmpty,
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        return parts.url
    }
}
