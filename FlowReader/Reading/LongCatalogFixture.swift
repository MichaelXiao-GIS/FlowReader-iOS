#if DEBUG
import Foundation

/// Original offline text, installed only by the explicit UI-test launch flags.
enum LongCatalogFixture {
    static let chapterCount = 1_200
    static let initialChapterNumber = 876
    static let cachedChapterNumbers = [1, 2, 875, 876, 877, 878, 1_199, 1_200]
    private static let volumeEnds = [200, 400, 600, 870, 876, 1_200]
    private static let volumeTitles = ["海风来信", "沿岸灯火", "海风来信", "群岛记事", "灯塔前夜", "海风来信"]

    // Deliberately non-monotonic IDs: neither sorting nor adjacent navigation may infer order from them.
    static func chapterID(number: Int) -> Int { -20_000 - ((number - 1) * 53 % chapterCount) }

    static let chapters: [Chapter] = (1...chapterCount).map { number in
        let volume = volumeEnds.firstIndex(where: { number <= $0 })!
        return Chapter(id: chapterID(number: number), bookID: -100, volumeID: 10 + volume,
                       volumeTitle: volumeTitles[volume], title: "第\(number)章 沿岸的第\(number)封信", order: number - 1)
    }

    static func text(chapterNumber: Int) -> String {
        "这是长目录离线样书的第\(chapterNumber)章。\n\n林夏把一封写给海风的信放在窗边，纸上记着今天路过的灯塔与归航的小船。\n\n本段为 Flow 原创测试文字，只用于验证目录定位、章节顺序和离线阅读，不连接远端内容服务。"
    }

    @MainActor
    static func install(in library: LibraryStore, book: Book) throws {
        guard book.id == -100 else { throw LibraryError.invalidCachedContent }
        library.save(book: book, chapters: chapters)
        // Eight files suffice for the test routes. Avoid 1,200 repeated index rewrites at launch.
        for number in cachedChapterNumbers {
            try library.store(content: ChapterContent(chapter: chapters[number - 1], text: text(chapterNumber: number)), book: book)
        }
        library.recordProgress(book: book, chapters: chapters, chapterID: chapterID(number: initialChapterNumber), paragraph: 0)
    }
}
#endif
