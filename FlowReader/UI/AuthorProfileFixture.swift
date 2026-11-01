#if DEBUG
import Foundation

/// Explicit offline navigation coverage; all identity and book data is original test content.
@MainActor
enum AuthorProfileFixture {
    static let authorID = 900_701
    static let name = "海岸来信"
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--author-profile-fixture")
    }

    static func contains(bookID: Int) -> Bool { (-706 ... -701).contains(bookID) }

    static func authorID(for book: Book) -> Int? {
        book.id == -100 || contains(bookID: book.id) ? authorID : book.authorID
    }

    static func client() -> AuthorProfileState.Client {
        .init(profile: { id in
            guard id == authorID else { throw SFAPIError.invalidIdentifier }
            return AuthorProfile(id: authorID, accountID: 900_702, name: name,
                biography: "在海风与书页之间，写下普通日子里的奇妙故事。\n愿每一位读者都能在故事中找到属于自己的微光。",
                avatarURL: URL(string: "https://avatar.invalid/original.png"), followerCount: 128)
        }, books: { id in
            guard id == authorID else { throw SFAPIError.invalidIdentifier }
            return ["沿海慢车", "雨天的书店", "灯塔来信", "云端花园", "星光邮局", "下一站，夏天"].enumerated().map { index, title in
                Book(id: -701 - index, title: title, author: name,
                     summary: "原创离线导航示例，用于验证作者作品与书籍详情之间的原生导航。",
                     isFinished: index % 2 == 0, wordCount: (index + 1) * 20_000, authorID: authorID)
            }
        })
    }
}
#endif
