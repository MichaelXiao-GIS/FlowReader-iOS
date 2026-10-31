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
    var route: ReadingRoute?
    func open(_ route: ReadingRoute) { self.route = route }
}
