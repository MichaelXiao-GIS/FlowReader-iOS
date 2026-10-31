import SwiftUI

struct DiscoverView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var bookTransition
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var feed = DiscoverLoadState()
    @State private var actionTask: Task<Void, Never>?

    private var books: [Book] { feed.books }
    private var loading: Bool { feed.loading }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    Text(submittedQuery.isEmpty ? "此刻，值得一读" : "搜索结果")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
                if let error = feed.error, books.isEmpty {
                    FlowErrorView(message: error) { startLoad(reset: true) }
                        .frame(minHeight: 240)
                } else if books.isEmpty && !loading {
                    ContentUnavailableView.search(text: submittedQuery)
                } else {
                    if let error = feed.error {
                        HStack(alignment: .top, spacing: 16) {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("重试") { startLoad(reset: true) }.buttonStyle(.glass)
                        }
                        .accessibilityIdentifier("discover-inline-error")
                    }
                    if submittedQuery.isEmpty { featuredShelf }
                    else { searchResults }
                    if feed.hasMore {
                        Button("加载更多") { startLoad(reset: false) }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                            .disabled(loading)
                    }
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, horizontalSizeClass == .regular ? 36 : 24)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(FlowTheme.paper)
        .navigationTitle("现在就读")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名、作者")
        .onSubmit(of: .search) {
            actionTask?.cancel()
            let nextQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if nextQuery == submittedQuery { startLoad(reset: true) }
            else { submittedQuery = nextQuery }
        }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty && !submittedQuery.isEmpty {
                actionTask?.cancel()
                submittedQuery = ""
            }
        }
        .navigationDestination(for: Book.self) { book in
            if reduceMotion { BookDetailView(book: book) }
            else { BookDetailView(book: book).navigationTransition(.zoom(sourceID: book.id, in: bookTransition)) }
        }
        .refreshable { await load(reset: true) }
        .task(id: submittedQuery) {
            if books.isEmpty || feed.query != submittedQuery { await load(reset: true) }
        }
        .onDisappear { actionTask?.cancel() }
    }

    private var featuredShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 26) {
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        VStack(alignment: .leading, spacing: 14) {
                            if reduceMotion {
                                BookCover(book: book, width: 142, height: 201)
                            } else {
                                BookCover(book: book, width: 142, height: 201)
                                    .matchedTransitionSource(id: book.id, in: bookTransition)
                            }
                            Text(book.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 142, alignment: .leading)
                        .padding(.bottom, 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("book-\(book.id)")
                }
            }
            .padding(.top, 3)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var searchResults: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 300 : 280), spacing: 28)], alignment: .leading, spacing: 14) {
            ForEach(books) { book in
                NavigationLink(value: book) { BookRow(book: book, transition: reduceMotion ? nil : bookTransition) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("book-\(book.id)")
            }
        }
    }

    @MainActor private func startLoad(reset: Bool) {
        actionTask?.cancel()
        actionTask = Task { await load(reset: reset) }
    }

    @MainActor private func load(reset: Bool) async {
        guard !Task.isCancelled, let request = feed.begin(query: submittedQuery, reset: reset) else { return }
        if (ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--uitesting")) && request.query.isEmpty {
            library.seedDemoIfNeeded()
            feed.complete(library.books.filter { $0.id == -100 }.map(\.book), for: request)
            return
        }
        do {
            let result: [Book]
            if request.query.isEmpty { result = try await SFAPI.shared.discover() }
            else { result = try await SFAPI.shared.search(query: request.query, page: request.page) }
            try Task.checkCancellation()
            feed.complete(result, for: request)
        } catch {
            feed.fail(error, for: request, taskIsCancelled: Task.isCancelled)
        }
    }
}

/// Owns request identity so cancelled refreshes and stale search responses cannot replace content.
struct DiscoverLoadState {
    struct Request: Equatable {
        let id = UUID()
        let query: String
        let page: Int
    }

    private(set) var books: [Book] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var page = 0
    private(set) var hasMore = false
    private(set) var query = ""
    private var currentRequest: UUID?

    mutating func begin(query: String, reset: Bool) -> Request? {
        if !reset && loading { return nil }
        if self.query != query {
            books = []
            page = 0
            hasMore = false
        }
        self.query = query
        let request = Request(query: query, page: reset ? 0 : page + 1)
        currentRequest = request.id
        loading = true
        error = nil
        return request
    }

    mutating func complete(_ result: [Book], for request: Request) {
        guard currentRequest == request.id else { return }
        if request.page == 0 { books = result }
        else {
            var known = Set(books.map(\.id))
            books.append(contentsOf: result.filter { known.insert($0.id).inserted })
        }
        page = request.page
        hasMore = !request.query.isEmpty && !result.isEmpty
        loading = false
        error = nil
        currentRequest = nil
    }

    mutating func fail(_ failure: Error, for request: Request, taskIsCancelled: Bool = false) {
        guard currentRequest == request.id else { return }
        loading = false
        currentRequest = nil
        // URLSession commonly reports cancellation as NSURLErrorCancelled, not CancellationError.
        if taskIsCancelled || Self.isCancellation(failure) { error = nil }
        else { error = failure.localizedDescription }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorCancelled
        }
        return false
    }
}
