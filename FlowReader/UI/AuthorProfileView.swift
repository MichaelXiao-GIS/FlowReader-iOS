import SwiftUI

struct AuthorProfileView: View {
    private let fallbackName: String
    @State private var state: AuthorProfileState
    @State private var expandedBiography = false
    @State private var profileRetryTask: Task<Void, Never>?
    @State private var booksRetryTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var bookTransition

    init(authorID: Int, fallbackName: String = "作者", client: AuthorProfileState.Client = .live) {
        self.fallbackName = fallbackName
        _state = State(initialValue: AuthorProfileState(authorID: authorID, client: client))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, LibraryShelfLayout.maximumWidth)
            let layout = LibraryShelfLayout(availableWidth: width, dynamicTypeSize: dynamicTypeSize)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    profileHeader
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("全部作品").font(.title3.weight(.semibold))
                        Spacer()
                        if state.isLoadingBooks { ProgressView().controlSize(.small) }
                    }
                    if let error = state.booksError {
                        if state.books.isEmpty {
                            ContentUnavailableView {
                                Label("作品暂时无法读取", systemImage: "wifi.exclamationmark")
                            } description: { Text(error) } actions: {
                                Button("重试", action: reloadBooks)
                                    .buttonStyle(.glass)
                                    .disabled(state.isLoadingBooks)
                                    .accessibilityIdentifier("author-books-error-retry")
                            }
                            .frame(minHeight: 200)
                            .accessibilityIdentifier("author-books-error")
                        } else {
                            inlineError(error, identifier: "author-books-error", loading: state.isLoadingBooks, retry: reloadBooks)
                        }
                    }
                    if state.hasLoadedBooks && state.books.isEmpty && state.booksError == nil {
                        ContentUnavailableView("暂无公开作品", systemImage: "books.vertical")
                            .accessibilityIdentifier("author-books-empty")
                    } else if !state.books.isEmpty {
                        works(layout: layout)
                    } else if state.isLoadingBooks {
                        ProgressView("正在读取作者作品…")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 20)
                .padding(.bottom, 36)
                .frame(maxWidth: width, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(FlowTheme.paper)
        }
        .navigationTitle("作者")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("author-profile-content")
        .task { await state.loadIfNeeded() }
        .refreshable { profileRetryTask?.cancel(); booksRetryTask?.cancel(); await state.refresh() }
        .onDisappear { profileRetryTask?.cancel(); booksRetryTask?.cancel() }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                AccountAvatar(profile: avatarProfile, sessionGeneration: nil, loader: avatarLoader)
                    .accessibilityLabel("作者头像")
                    .accessibilityIdentifier("author-avatar")
                Text(state.profile?.name ?? fallbackName)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("author-name")
                Spacer(minLength: 0)
            }
            if state.profile?.followerCount != nil || state.hasLoadedBooks {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 32) { statistics }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 14) { statistics }
                }
            }
            if let biography = state.profile?.biography, !biography.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(biography)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                        .lineLimit(expandedBiography ? nil : 4)
                        .accessibilityIdentifier("author-biography")
                    Button(expandedBiography ? "收起简介" : "展开简介") { expandedBiography.toggle() }
                        .font(.caption)
                        .accessibilityIdentifier("author-biography-expand")
                }
            }
            if state.isLoadingProfile && state.profile == nil {
                ProgressView("正在读取作者资料…").font(.subheadline)
            }
            if let error = state.profileError {
                inlineError(error, identifier: "author-profile-error", loading: state.isLoadingProfile) {
                    profileRetryTask?.cancel()
                    profileRetryTask = Task { await state.reloadProfile() }
                }
            }
        }
    }

    private var avatarProfile: AccountProfile? {
        guard let profile = state.profile else { return nil }
        return AccountProfile(id: profile.id, name: profile.name, accountName: String(profile.id), avatarURL: profile.avatarURL)
    }

    private var avatarLoader: CoverThumbnailLoader {
        #if DEBUG
        if AuthorProfileFixture.isEnabled { return AccountAvatarFixture.loader }
        #endif
        return .shared
    }

    @ViewBuilder private var statistics: some View {
        if let count = state.profile?.followerCount {
            statistic(value: count, title: "粉丝", identifier: "author-followers")
        }
        if state.hasLoadedBooks {
            statistic(value: state.books.count, title: "作品", identifier: "author-work-count")
        }
    }

    private func statistic(value: Int, title: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value.formatted()).font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func works(layout: LibraryShelfLayout) -> some View {
        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: layout.rowSpacing) {
            ForEach(state.books) { book in
                NavigationLink {
                    if reduceMotion { BookDetailView(book: book) }
                    else {
                        BookDetailView(book: book)
                            .navigationTransition(.zoom(sourceID: book.id, in: bookTransition))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if reduceMotion {
                            BookCover(book: book, width: layout.cardWidth, height: layout.coverHeight)
                        } else {
                            BookCover(book: book, width: layout.cardWidth, height: layout.coverHeight)
                                .matchedTransitionSource(id: book.id, in: bookTransition)
                        }
                        Text(book.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                        Text(book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                    .frame(width: layout.cardWidth, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("author-book-\(book.id)")
            }
        }
        .accessibilityIdentifier("author-works-grid")
    }

    private func inlineError(_ message: String, identifier: String, loading: Bool, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retry).buttonStyle(.glass).disabled(loading)
                .accessibilityIdentifier("\(identifier)-retry")
        }
        .accessibilityIdentifier(identifier)
    }

    private func reloadBooks() {
        booksRetryTask?.cancel()
        booksRetryTask = Task { await state.reloadBooks() }
    }
}
