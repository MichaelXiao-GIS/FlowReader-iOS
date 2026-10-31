import Foundation
import Observation

struct ReaderBookmark: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let bookID: Int
    let chapterID: Int
    let chapterTitle: String
    let position: ReaderTextPosition
    let excerpt: String
    let createdAt: Date
}

@MainActor @Observable
final class ReaderBookmarkStore {
    static let shared = ReaderBookmarkStore()
    private(set) var bookmarks: [ReaderBookmark] = []
    private(set) var loadError: String?
    @ObservationIgnored private let fileURL: URL

    init(directory: URL? = nil) {
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let root = directory ?? (testing
            ? FileManager.default.temporaryDirectory.appendingPathComponent("FlowBookmarks-\(UUID().uuidString)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlowLibrary"))
        fileURL = root.appendingPathComponent("bookmarks.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { bookmarks = try JSONDecoder().decode([ReaderBookmark].self, from: Data(contentsOf: fileURL)) }
        catch { loadError = "本机书签暂时无法读取：\(error.localizedDescription)" }
    }

    func bookmarks(bookID: Int) -> [ReaderBookmark] {
        bookmarks.filter { $0.bookID == bookID }.sorted { $0.createdAt > $1.createdAt }
    }

    func bookmark(bookID: Int, chapterID: Int, position: ReaderTextPosition) -> ReaderBookmark? {
        bookmarks.first { $0.bookID == bookID && $0.chapterID == chapterID && $0.position == position }
    }

    /// Writes first, then changes observable state, so a failed disk write never looks saved.
    func toggle(bookID: Int, chapter: Chapter, position: ReaderTextPosition, excerpt: String) throws {
        guard bookID != 0, chapter.id != 0, chapter.bookID == bookID,
              position.paragraph >= 0, position.utf16Offset >= 0 else { throw SFAPIError.invalidIdentifier }
        if let existing = bookmark(bookID: bookID, chapterID: chapter.id, position: position) {
            try remove(id: existing.id)
            return
        }
        var updated = bookmarks
        updated.append(ReaderBookmark(id: UUID(), bookID: bookID, chapterID: chapter.id,
                                      chapterTitle: chapter.title, position: position,
                                      excerpt: String(excerpt.prefix(100)), createdAt: Date()))
        try persist(updated)
    }

    func remove(id: UUID) throws {
        try persist(bookmarks.filter { $0.id != id })
    }

    private func persist(_ updated: [ReaderBookmark]) throws {
        // Preserve a damaged file until the reader can recover it, rather than overwriting it silently.
        if let loadError { throw SFAPIError.server(loadError) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        bookmarks = updated
    }
}
