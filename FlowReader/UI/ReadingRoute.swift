import SwiftUI

/// Keeps the selected chapter and catalog independent of subsequent progress updates.
struct ReadingRoute: Hashable {
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

extension View {
    func readingDestinations() -> some View {
        navigationDestination(for: ReadingRoute.self) { route in
            ReaderView(book: route.book, chapters: route.chapters, initialChapter: route.initialChapter)
        }
    }
}
