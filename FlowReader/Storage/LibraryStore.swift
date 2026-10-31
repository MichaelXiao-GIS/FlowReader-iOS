import Foundation
import Observation
import CoreFoundation

struct ReadingProgress: Codable, Hashable {
    var chapterID: Int
    var paragraph: Int
    var updatedAt: Date
    var paragraphUTF16Offset: Int? = nil
}

struct LocalBook: Identifiable, Codable, Hashable {
    var id: Int { book.id }
    var book: Book
    var chapters: [Chapter]
    var downloadedIDs: Set<Int> = []
    var progress: ReadingProgress?
    var addedAt = Date()
}

struct DownloadJob: Identifiable, Codable, Hashable {
    enum Status: String, Codable { case queued, downloading, paused, failed, complete }
    var id: Int { book.id }
    var book: Book
    var chapters: [Chapter]
    var completedIDs: Set<Int> = []
    var status: Status = .queued
    var message: String?
    var fraction: Double { chapters.isEmpty ? 0 : Double(completedIDs.count) / Double(chapters.count) }
}

enum LibraryError: LocalizedError {
    case emptyFile, unsupportedEncoding, tooLarge, noChapters
    case outdatedVIPCache(String)
    var errorDescription: String? {
        switch self {
        case .emptyFile: return "文件中没有可阅读的文字。"
        case .unsupportedEncoding: return "无法识别文字编码，请将文件保存为 UTF-8 后重新导入。"
        case .tooLarge: return "请选择小于 50 MB 的文本文件。"
        case .noChapters: return "请先下载至少一个章节再导出。"
        case .outdatedVIPCache(let reason): return "此 VIP 章节的旧缓存需要重新识别，原文件已保留。\(reason)"
        }
    }
}

@MainActor @Observable
final class LibraryStore {
    private(set) var books: [LocalBook] = []
    private(set) var jobs: [DownloadJob] = []
    var errorMessage: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private let jobsURL: URL
    @ObservationIgnored private let fetchContent: (Chapter) async throws -> ChapterContent

    init(directory: URL? = nil, fetchContent: @escaping (Chapter) async throws -> ChapterContent = { try await SFAPI.shared.content(chapter: $0) }) {
        self.fetchContent = fetchContent
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlowLibrary", isDirectory: true)
        indexURL = root.appendingPathComponent("library.json")
        jobsURL = root.appendingPathComponent("downloads.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                books = try JSONDecoder().decode([LocalBook].self, from: Data(contentsOf: indexURL))
            }
            if FileManager.default.fileExists(atPath: jobsURL.path) {
                jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: jobsURL))
                for index in jobs.indices where jobs[index].status == .downloading || jobs[index].status == .queued {
                    jobs[index].status = .paused
                }
            }
        } catch {
            errorMessage = "本地书库暂时无法读取：\(error.localizedDescription)"
        }
    }

    func localBook(id: Int) -> LocalBook? { books.first { $0.id == id } }

    func save(book: Book, chapters: [Chapter]) {
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index].book = book
            if !chapters.isEmpty {
                var merged = Dictionary(books[index].chapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                merged.merge(Dictionary(chapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })) { _, new in new }
                books[index].chapters = merged.values.sorted { $0.order < $1.order }
            }
        } else {
            books.insert(LocalBook(book: book, chapters: chapters), at: 0)
        }
        persist()
    }

    func cachedContent(chapter: Chapter) -> ChapterContent? {
        guard let data = try? Data(contentsOf: contentURL(bookID: chapter.bookID, chapterID: chapter.id)) else { return nil }
        return try? JSONDecoder().decode(ChapterContent.self, from: data)
    }

    func content(chapter: Chapter) async throws -> ChapterContent {
        if let cached = cachedContent(chapter: chapter) {
            guard chapter.bookID > 0, chapter.id > 0, chapter.isVIP,
                  (cached.sourceFormatVersion ?? 0) < 2 else { return cached }
            do {
                let refreshed = try await fetchContent(chapter)
                try Task.checkCancellation()
                // Replace only after a successful decode; an offline failure leaves the original file intact.
                try JSONEncoder().encode(refreshed).write(to: contentURL(bookID: chapter.bookID, chapterID: chapter.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return refreshed
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { throw LibraryError.outdatedVIPCache(error.localizedDescription) }
        }
        return try await fetchContent(chapter)
    }

    func store(content: ChapterContent, book: Book) throws {
        let folder = root.appendingPathComponent(String(book.id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(content).write(to: contentURL(bookID: book.id, chapterID: content.chapter.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index].downloadedIDs.insert(content.chapter.id)
        }
        persist()
    }

    func recordProgress(book: Book, chapters: [Chapter], chapterID: Int, paragraph: Int, paragraphUTF16Offset: Int? = nil) {
        if books.firstIndex(where: { $0.id == book.id }) == nil { save(book: book, chapters: chapters) }
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index].progress = ReadingProgress(chapterID: chapterID, paragraph: max(0, paragraph), updatedAt: Date(), paragraphUTF16Offset: paragraphUTF16Offset.map { max(0, $0) })
        persist()
    }

    func download(book: Book, chapters: [Chapter]) {
        guard !chapters.isEmpty else { return }
        save(book: book, chapters: chapters)
        let stored = localBook(id: book.id)?.downloadedIDs ?? []
        if let index = jobs.firstIndex(where: { $0.id == book.id }) {
            let merged = Dictionary(chapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var combined = Dictionary(jobs[index].chapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            combined.merge(merged) { _, new in new }
            jobs[index].chapters = combined.values.sorted { $0.order < $1.order }
            jobs[index].completedIDs = Set(jobs[index].chapters.map(\.id)).intersection(stored)
            if jobs[index].status != .downloading { jobs[index].status = .queued }
            jobs[index].message = nil
        } else {
            jobs.append(DownloadJob(book: book, chapters: chapters, completedIDs: Set(chapters.map(\.id)).intersection(stored)))
        }
        persist()
        startNext()
    }

    func pause(jobID: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let wasActive = jobs[index].status == .downloading
        jobs[index].status = .paused
        if wasActive { worker?.cancel() }
        persist()
    }

    func resume(jobID: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = .queued
        jobs[index].message = nil
        persist()
        startNext()
    }

    func cancel(jobID: Int) {
        if jobs.first(where: { $0.id == jobID })?.status == .downloading { worker?.cancel() }
        jobs.removeAll { $0.id == jobID }
        persist()
    }

    func remove(bookID: Int) {
        cancel(jobID: bookID)
        do {
            let folder = root.appendingPathComponent(String(bookID))
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            books.removeAll { $0.id == bookID }
            persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func downloadedContent(bookID: Int) -> [ChapterContent] {
        guard let local = localBook(id: bookID) else { return [] }
        return local.chapters.sorted { $0.order < $1.order }.compactMap { chapter in
            guard local.downloadedIDs.contains(chapter.id) else { return nil }
            return cachedContent(chapter: chapter)
        }
    }

    func importText(url: URL) throws -> Book {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50_000_000 else { throw LibraryError.tooLarge }
        let data = try Data(contentsOf: url)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: gb18030) else { throw LibraryError.unsupportedEncoding }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyFile }
        let id = -Int(Date().timeIntervalSince1970 * 1000)
        let title = url.deletingPathExtension().lastPathComponent
        let book = Book(id: id, title: title, author: "本地导入", coverURL: nil, summary: "从文件导入的个人藏书")
        let heading = try NSRegularExpression(pattern: "(?m)^[\\t 　]*(?:第[零〇一二三四五六七八九十百千万两0-9]+[章节回卷部]|Chapter\\s+[0-9]+)[^\\n]{0,65}$", options: [.caseInsensitive])
        let ns = text as NSString
        let matches = heading.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var sections: [(String, String)] = []
        if matches.isEmpty {
            sections = [(title, text)]
        } else {
            if matches[0].range.location > 0 {
                let prefix = ns.substring(to: matches[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty { sections.append(("前言", prefix)) }
            }
            for (index, match) in matches.enumerated() {
                let start = match.range.location + match.range.length
                let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
                sections.append((ns.substring(with: match.range).trimmingCharacters(in: .whitespaces), ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        let chapters = sections.enumerated().map { index, section in Chapter(id: id - index, bookID: id, volumeID: 0, volumeTitle: "本地文本", title: section.0, order: index) }
        save(book: book, chapters: chapters)
        do {
            for (index, chapter) in chapters.enumerated() { try store(content: ChapterContent(chapter: chapter, text: sections[index].1), book: book) }
        } catch { remove(bookID: id); throw error }
        return book
    }

    func seedDemoIfNeeded() {
        guard localBook(id: -100) == nil else { return }
        let book = Book(id: -100, title: "在风抵达之前", author: "Flow 原创示例", coverURL: nil, summary: "海边的小镇，一间只在黄昏开门的书店，与一封尚未寄出的信。此书为应用原创演示内容。", category: "治愈日常", tags: ["原创示例", "海边", "日常"], isFinished: true)
        let titles = ["第一章 海边的书店", "第二章 风从远方来", "第三章 留给明天的一页"]
        var texts = [
            "海风穿过街角时，书店的铜铃轻轻响了一声。\n\n林夏抬起头，看见门口站着一个抱着旧地图的女孩。地图的边缘已经磨软，上面用蓝色铅笔圈着一座不存在的灯塔。\n\n“我想找一本书。”女孩说。\n\n小镇的书店不大。木架贴着墙壁，从地面一直伸向屋顶；下午的光落在书脊上，仿佛有人把整个夏天收进了这里。\n\n林夏合上手中的笔记：“书名呢？”\n\n女孩摇了摇头，把地图摊在桌上。那座灯塔旁边有一行很小的字：如果你不知道下一站去哪里，就先听一听风。\n\n他认得那行字。那是祖父的笔迹。\n\n窗外，最后一班渡船驶离码头，水面留下长长的白色痕迹。林夏忽然觉得，这个原本平凡的黄昏，正在慢慢翻向新的一页。",
            "第二天清晨，林夏在书店门口发现了一个纸包。\n\n里面是一枚黄铜书签，一张褪色的船票，以及半封没有署名的信。信纸上只写着一句话：潮水会带走足迹，但不会带走约定。\n\n他沿着海岸走了很久。渔人们修补着网，孩子们在浅滩追逐，云影一片片掠过平静的水面。\n\n直到午后，他才在废弃的车站旁找到地图上的路。那条路早已不通向灯塔，只通向一片开满小花的山坡。\n\n女孩坐在坡顶，手里捧着一本没有封面的书。\n\n“找到了吗？”林夏问。\n\n“也许。”她翻开第一页，“但我还不知道，它是不是写给我的。”\n\n远处响起汽笛声。风从两人之间经过，带着盐、青草和很久以前的夏天的味道。",
            "书店重新开门的那个下午，林夏把黄铜书签放在了柜台边。\n\n女孩已经离开小镇。她留下一张新的地图，上面没有灯塔，也没有终点，只有许多空白的地方。\n\n“留给以后。”纸条上写着。\n\n林夏笑了。他取出那封未寄出的信，在背面写下书店的地址，然后仔细地折好。\n\n有些故事不必急着写完。就像有些人走得很远，只是为了在一个恰好的黄昏，重新推开熟悉的门。\n\n海风再次吹过街角，铜铃响起。\n\n他抬头，看见阳光正落在新的一页上。"
        ]
        #if DEBUG
        // Keep the UI fixture long enough to exercise multiple spreads on the Duo inner display.
        // Normal demo content and users' stored books are unaffected.
        if ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--long-reader-fixture") {
            texts[0] = Array(repeating: texts[0], count: 6).joined(separator: "\n\n")
        }
        #endif
        let chapters = titles.enumerated().map { Chapter(id: -1000 - $0.offset, bookID: -100, volumeID: 0, volumeTitle: "海风来信", title: $0.element, order: $0.offset) }
        save(book: book, chapters: chapters)
        for (index, chapter) in chapters.enumerated() {
            do { try store(content: ChapterContent(chapter: chapter, text: texts[index]), book: book) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func startNext() {
        guard worker == nil, let next = jobs.first(where: { $0.status == .queued }) else { return }
        if let index = jobs.firstIndex(where: { $0.id == next.id }) { jobs[index].status = .downloading }
        persist()
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.persist(); self.startNext() }
            do {
                while let index = self.jobs.firstIndex(where: { $0.id == next.id }), self.jobs[index].status == .downloading {
                    try Task.checkCancellation()
                    guard let chapter = self.jobs[index].chapters.first(where: { !self.jobs[index].completedIDs.contains($0.id) }) else {
                        self.jobs[index].status = .complete
                        return
                    }
                    let result = try await self.content(chapter: chapter)
                    try Task.checkCancellation()
                    guard let current = self.jobs.firstIndex(where: { $0.id == next.id }), self.jobs[current].status == .downloading else { return }
                    try self.store(content: result, book: next.book)
                    self.jobs[current].completedIDs.insert(chapter.id)
                    self.persist()
                    try await Task.sleep(for: .milliseconds(600))
                }
            } catch is CancellationError {
                // Pausing and cancellation preserve completed chapters.
            } catch {
                if let index = self.jobs.firstIndex(where: { $0.id == next.id }), self.jobs[index].status == .downloading {
                    self.jobs[index].status = .failed
                    self.jobs[index].message = error.localizedDescription
                }
            }
        }
    }

    private func contentURL(bookID: Int, chapterID: Int) -> URL {
        root.appendingPathComponent(String(bookID), isDirectory: true).appendingPathComponent("\(chapterID).json")
    }

    private func persist() {
        do {
            try JSONEncoder().encode(books).write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try JSONEncoder().encode(jobs).write(to: jobsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { errorMessage = "保存书库失败：\(error.localizedDescription)" }
    }
}
