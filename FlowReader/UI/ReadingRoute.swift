import SwiftUI

/// Keeps the selected chapter and catalog independent of subsequent progress updates.
struct ReadingRoute: Hashable, Identifiable {
    var id: String { "\(book.id):\(initialChapter.id)" }
    let book: Book
    let chapters: [Chapter]
    let initialChapter: Chapter

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.book.id == rhs.book.id && lhs.initialChapter.id == rhs.initialChapter.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(book.id)
        hasher.combine(initialChapter.id)
    }
}

/// Present reading outside the tab/sidebar hierarchy so system navigation cannot cover a page.
@MainActor @Observable
final class ReadingSession {
    var route: ReadingRoute? {
        didSet {
            // SwiftUI also clears this binding when the full-screen reader is dismissed.
            if route == nil, oldValue != nil { persist(nil) }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saved: ReadingSessionCheckpoint?
    @ObservationIgnored private var attemptedRestoration = false
    private static let storageKey = "navigation.activeReadingSession"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            saved = try? JSONDecoder().decode(ReadingSessionCheckpoint.self, from: data)
            if saved == nil { defaults.removeObject(forKey: Self.storageKey) }
        }
    }

    func open(_ route: ReadingRoute) {
        attemptedRestoration = true
        self.route = route
        checkpoint(bookID: route.book.id, chapterID: route.initialChapter.id)
    }

    /// Progress itself remains in LibraryStore. Only IDs are saved here, without content or permissions.
    /// Updating a page or changing chapter must not replace the presented SwiftUI route.
    func checkpoint(bookID: Int, chapterID: Int) {
        guard let route, route.book.id == bookID,
              route.chapters.contains(where: { $0.id == chapterID && $0.bookID == bookID }) else { return }
        persist(ReadingSessionCheckpoint(bookID: bookID, chapterID: chapterID))
    }

    func close() {
        attemptedRestoration = true
        route = nil
        persist(nil)
    }

    /// A foreground transition keeps the current route; restoration runs once after a process restart.
    func restoreIfNeeded(from library: LibraryStore) {
        guard !attemptedRestoration else { return }
        attemptedRestoration = true
        guard route == nil, let saved else { return }
        guard let local = library.localBook(id: saved.bookID),
              let chapter = local.chapters.first(where: { $0.id == saved.chapterID && $0.bookID == saved.bookID }) else {
            persist(nil)
            return
        }
        route = ReadingRoute(book: local.book, chapters: local.chapters, initialChapter: chapter)
    }

    private func persist(_ value: ReadingSessionCheckpoint?) {
        guard saved != value else { return }
        saved = value
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.storageKey) }
        else { defaults.removeObject(forKey: Self.storageKey) }
    }
}

private struct ReadingSessionCheckpoint: Codable, Equatable {
    let bookID: Int
    let chapterID: Int
}
