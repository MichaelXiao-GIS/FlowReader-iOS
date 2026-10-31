import Foundation

struct Book: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var title: String
    var author: String
    var coverURL: URL? = nil
    var summary: String = ""
    var category: String? = nil
    var tags: [String] = []
    var isFinished: Bool = false
    var wordCount: Int? = nil
    var latestChapter: String? = nil
    var updatedAt: String? = nil
    var shelfName: String? = nil
    var officialURL: URL { URL(string: "https://book.sfacg.com/Novel/\(id)/")! }
}

struct Chapter: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var bookID: Int
    var volumeID: Int
    var volumeTitle: String
    var title: String
    var order: Int
    var isVIP: Bool = false
    var isOwned: Bool = false
    var officialURL: URL {
        URL(string: isVIP ? "https://book.sfacg.com/vip/c/\(id)/" : "https://book.sfacg.com/Novel/\(bookID)/\(volumeID)/\(id)/")!
    }
}

struct ChapterContent: Codable, Hashable, Sendable {
    var chapter: Chapter
    var text: String
    var paragraphs: [String] { text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

struct AudioTrack: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var albumID: Int
    var title: String
    var volumeTitle: String
    var order: Int
    var duration: Double? = nil
    var isVIP: Bool = false
    var sourceURL: URL? = nil
}

struct AccountProfile: Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var accountName: String
    var avatarURL: URL? = nil
}

enum SFAPIError: LocalizedError {
    case invalidResponse, loginRequired, subscriptionRequired, emptyContent, noAudio, invalidIdentifier
    case server(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "菠萝包返回的数据暂时无法读取，请稍后重试。"
        case .loginRequired: return "请先登录菠萝包官方账号。"
        case .subscriptionRequired: return "本章需要在菠萝包官方订阅后阅读。"
        case .emptyContent: return "本章暂时没有可读取的文字，请在官方页面查看。"
        case .noAudio: return "这部作品暂时没有可播放的有声专辑。"
        case .invalidIdentifier: return "作品或章节编号无效。"
        case .server(let message): return message
        }
    }
}
