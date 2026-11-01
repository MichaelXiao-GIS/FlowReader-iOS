import XCTest
@testable import FlowReader

final class AuthorProfileStateTests: XCTestCase {
    @MainActor
    func testProfileFailureDoesNotHideWorksAndPreservesServerOrder() async {
        let first = Book(id: 31, title: "原创作品一", author: "测试作者", authorID: 7)
        let second = Book(id: 12, title: "原创作品二", author: "测试作者", authorID: 7)
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in throw SFAPIError.server("资料暂不可用") },
            books: { _ in [first, second, first] }
        ))

        await state.loadIfNeeded()

        XCTAssertNil(state.profile)
        XCTAssertEqual(state.profileError, "资料暂不可用")
        XCTAssertEqual(state.books.map(\.id), [31, 12])
        XCTAssertTrue(state.hasLoadedBooks)
        XCTAssertNil(state.booksError)
        XCTAssertFalse(state.isLoadingProfile)
        XCTAssertFalse(state.isLoadingBooks)
    }

    @MainActor
    func testWorksFailureDoesNotHideProfileOrPretendConfirmedEmpty() async {
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in AuthorProfile(id: 7, accountID: 90, name: "原创作者") },
            books: { _ in throw SFAPIError.server("作品暂不可用") }
        ))

        await state.loadIfNeeded()

        XCTAssertEqual(state.profile?.id, 7)
        XCTAssertEqual(state.profile?.accountID, 90, "Author ID and account ID remain distinct")
        XCTAssertNil(state.profileError)
        XCTAssertEqual(state.booksError, "作品暂不可用")
        XCTAssertFalse(state.hasLoadedBooks)
    }

    @MainActor
    func testRefreshFailuresKeepBothSuccessfulSnapshots() async {
        var profileCalls = 0
        var booksCalls = 0
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in
                profileCalls += 1
                if profileCalls > 1 { throw SFAPIError.server("资料刷新失败") }
                return AuthorProfile(id: 7, name: "原创作者")
            },
            books: { _ in
                booksCalls += 1
                if booksCalls > 1 { throw SFAPIError.server("作品刷新失败") }
                return [Book(id: 31, title: "原创作品", author: "原创作者", authorID: 7)]
            }
        ))

        await state.loadIfNeeded()
        await state.loadIfNeeded()
        XCTAssertEqual(profileCalls, 1)
        XCTAssertEqual(booksCalls, 1)
        await state.refresh()

        XCTAssertEqual(state.profile?.name, "原创作者")
        XCTAssertEqual(state.books.map(\.id), [31])
        XCTAssertTrue(state.hasLoadedBooks)
        XCTAssertEqual(state.profileError, "资料刷新失败")
        XCTAssertEqual(state.booksError, "作品刷新失败")
    }

    @MainActor
    func testCancelledInitialRequestsShowNoErrorAndAllowAnotherLoad() async {
        var profileCalls = 0
        var booksCalls = 0
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in
                profileCalls += 1
                if profileCalls == 1 { throw CancellationError() }
                return AuthorProfile(id: 7, name: "原创作者")
            },
            books: { _ in
                booksCalls += 1
                if booksCalls == 1 { throw URLError(.cancelled) }
                return []
            }
        ))

        await state.loadIfNeeded()
        XCTAssertNil(state.profileError)
        XCTAssertNil(state.booksError)
        XCTAssertFalse(state.hasLoadedBooks)
        XCTAssertFalse(state.isLoadingProfile)
        XCTAssertFalse(state.isLoadingBooks)
        await state.loadIfNeeded()

        XCTAssertEqual(state.profile?.name, "原创作者")
        XCTAssertTrue(state.hasLoadedBooks)
        XCTAssertTrue(state.books.isEmpty)
        XCTAssertEqual(profileCalls, 2)
        XCTAssertEqual(booksCalls, 2)
    }

    @MainActor
    func testOlderProfileSuccessCannotReplaceNewerResponse() async {
        let started = expectation(description: "First profile request started")
        var continuation: CheckedContinuation<AuthorProfile, Never>?
        var calls = 0
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in
                calls += 1
                if calls == 1 {
                    return await withCheckedContinuation { pending in
                        continuation = pending
                        started.fulfill()
                    }
                }
                return AuthorProfile(id: 7, name: "最新资料")
            },
            books: { _ in [] }
        ))
        let first = Task { await state.reloadProfile() }
        await fulfillment(of: [started], timeout: 2)
        await state.reloadProfile()
        continuation?.resume(returning: AuthorProfile(id: 7, name: "较旧资料"))
        await first.value

        XCTAssertEqual(state.profile?.name, "最新资料")
        XCTAssertNil(state.profileError)
        XCTAssertFalse(state.isLoadingProfile)
    }

    @MainActor
    func testOlderWorksFailureCannotEraseNewerSuccess() async {
        let started = expectation(description: "First works request started")
        var continuation: CheckedContinuation<[Book], Error>?
        var calls = 0
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in AuthorProfile(id: 7, name: "原创作者") },
            books: { _ in
                calls += 1
                if calls == 1 {
                    return try await withCheckedThrowingContinuation { pending in
                        continuation = pending
                        started.fulfill()
                    }
                }
                return [Book(id: 31, title: "最新作品", author: "原创作者", authorID: 7)]
            }
        ))
        let first = Task { await state.reloadBooks() }
        await fulfillment(of: [started], timeout: 2)
        await state.reloadBooks()
        continuation?.resume(throwing: SFAPIError.server("旧请求失败"))
        await first.value

        XCTAssertEqual(state.books.map(\.id), [31])
        XCTAssertNil(state.booksError)
        XCTAssertTrue(state.hasLoadedBooks)
        XCTAssertFalse(state.isLoadingBooks)
    }

    @MainActor
    func testCancellationRejectsAClientThatStillReturnsContent() async {
        let started = expectation(description: "Profile request suspended")
        var continuation: CheckedContinuation<AuthorProfile, Never>?
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in await withCheckedContinuation { pending in
                continuation = pending
                started.fulfill()
            } },
            books: { _ in [] }
        ))
        let request = Task { await state.reloadProfile() }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        continuation?.resume(returning: AuthorProfile(id: 7, name: "不应显示的结果"))
        await request.value

        XCTAssertNil(state.profile)
        XCTAssertNil(state.profileError)
        XCTAssertFalse(state.isLoadingProfile)
    }

    @MainActor
    func testMismatchedAuthorResponseIsRejected() async {
        let state = AuthorProfileState(authorID: 7, client: .init(
            profile: { _ in AuthorProfile(id: 90, name: "其他作者") },
            books: { _ in [] }
        ))

        await state.loadIfNeeded()

        XCTAssertNil(state.profile)
        XCTAssertNotNil(state.profileError)
        XCTAssertTrue(state.hasLoadedBooks)
        XCTAssertNil(state.booksError)
    }
}
