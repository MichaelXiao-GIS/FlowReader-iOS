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
    /// The author's public profile ID, distinct from their account ID. Missing in old local indexes.
    var authorID: Int? = nil
    var officialURL: URL { URL(string: "https://book.sfacg.com/Novel/\(id)/")! }
}

enum ChapterPurchaseState: String, Codable, Hashable, Sendable {
    case unknown, purchased, notPurchased, available, requiresPurchase
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
    // A missing field in older downloads is unknown; legacy isOwned=false was only a VIP default.
    var confirmedPurchaseState: ChapterPurchaseState? = nil
    var purchaseSessionGeneration: UUID? = nil
    func purchaseState(for generation: UUID?) -> ChapterPurchaseState {
        guard let generation, generation == purchaseSessionGeneration else { return .unknown }
        return confirmedPurchaseState ?? .unknown
    }
    // Authentication-specific permissions never survive a saved catalog or app launch.
    enum CodingKeys: String, CodingKey {
        case id, bookID, volumeID, volumeTitle, title, order, isVIP, isOwned
    }
    var officialURL: URL {
        URL(string: isVIP ? "https://book.sfacg.com/vip/c/\(id)/" : "https://book.sfacg.com/Novel/\(bookID)/\(volumeID)/\(id)/")!
    }
}

struct ChapterContent: Codable, Hashable, Sendable {
    var chapter: Chapter
    var text: String
    var sourceFormatVersion: Int? = nil
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

extension AccountProfile {
    func matchesAccountIdentity(_ other: AccountProfile) -> Bool {
        let lhs = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = other.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lhs.isEmpty && !rhs.isEmpty {
            guard lhs == rhs else { return false }
            return id <= 0 || other.id <= 0 || id == other.id
        }
        return id > 0 && other.id > 0 && id == other.id
    }
}

enum SFAPIError: LocalizedError {
    case invalidResponse, loginRequired, subscriptionRequired, emptyContent, noAudio, invalidIdentifier
    case server(String)
    case httpStatus(Int)
    case authenticationRequired(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "菠萝包返回的数据暂时无法读取，请稍后重试。"
        case .loginRequired: return "请先登录菠萝包官方账号。"
        case .subscriptionRequired: return "本章需要在菠萝包官方订阅后阅读。"
        case .emptyContent: return "本章暂时没有可读取的文字，请在官方页面查看。"
        case .noAudio: return "这部作品暂时没有可播放的有声专辑。"
        case .invalidIdentifier: return "作品或章节编号无效。"
        case .server(let message): return message
        case .httpStatus(let code): return "菠萝包服务暂时不可用（\(code)）。"
        case .authenticationRequired(let message): return message
        }
    }
}

struct BookshelfSyncResult: Sendable {
    let books: [Book]
    let failedSectionCount: Int
    var isComplete: Bool { failedSectionCount == 0 }
    var notice: String? {
        guard failedSectionCount > 0 else { return nil }
        return "有 \(failedSectionCount) 个书架分类暂未同步，可稍后重试。"
    }
}
