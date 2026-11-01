import Foundation
import Observation

@MainActor @Observable
final class AuthorProfileState {
    struct Client {
        var profile: @MainActor (Int) async throws -> AuthorProfile
        var books: @MainActor (Int) async throws -> [Book]

        static let live = Client(
            profile: { try await SFAPI.shared.authorProfile(authorID: $0) },
            books: { try await SFAPI.shared.authorBooks(authorID: $0) }
        )
    }

    let authorID: Int
    private(set) var profile: AuthorProfile?
    private(set) var books: [Book] = []
    private(set) var profileError: String?
    private(set) var booksError: String?
    private(set) var isLoadingProfile = false
    private(set) var isLoadingBooks = false
    private(set) var hasLoadedBooks = false
    @ObservationIgnored private let client: Client
    @ObservationIgnored private var profileRequest = UUID()
    @ObservationIgnored private var booksRequest = UUID()
    @ObservationIgnored private var attemptedProfile = false
    @ObservationIgnored private var attemptedBooks = false

    init(authorID: Int, client: Client = .live) {
        self.authorID = authorID
        self.client = client
    }

    func loadIfNeeded() async {
        async let profile: Void = loadProfileIfNeeded()
        async let books: Void = loadBooksIfNeeded()
        _ = await (profile, books)
    }

    func refresh() async {
        async let profile: Void = reloadProfile()
        async let books: Void = reloadBooks()
        _ = await (profile, books)
    }

    func reloadProfile() async {
        let request = UUID()
        profileRequest = request
        attemptedProfile = true
        isLoadingProfile = true
        profileError = nil
        defer { if profileRequest == request { isLoadingProfile = false } }
        do {
            guard authorID > 0 else { throw SFAPIError.invalidIdentifier }
            let result = try await client.profile(authorID)
            try Task.checkCancellation()
            guard profileRequest == request else { return }
            guard result.id == authorID else { throw SFAPIError.invalidResponse }
            profile = result
        } catch {
            guard profileRequest == request else { return }
            if Task.isCancelled || AccountShelfState.isCancellation(error) {
                attemptedProfile = profile != nil
            } else { profileError = error.localizedDescription }
        }
    }

    func reloadBooks() async {
        let request = UUID()
        booksRequest = request
        attemptedBooks = true
        isLoadingBooks = true
        booksError = nil
        defer { if booksRequest == request { isLoadingBooks = false } }
        do {
            guard authorID > 0 else { throw SFAPIError.invalidIdentifier }
            let result = try await client.books(authorID)
            try Task.checkCancellation()
            guard booksRequest == request else { return }
            var known = Set<Int>()
            books = result.filter { known.insert($0.id).inserted }
            hasLoadedBooks = true
        } catch {
            guard booksRequest == request else { return }
            if Task.isCancelled || AccountShelfState.isCancellation(error) {
                attemptedBooks = hasLoadedBooks
            } else { booksError = error.localizedDescription }
        }
    }

    private func loadProfileIfNeeded() async {
        if !attemptedProfile { await reloadProfile() }
    }

    private func loadBooksIfNeeded() async {
        if !attemptedBooks { await reloadBooks() }
    }
}
