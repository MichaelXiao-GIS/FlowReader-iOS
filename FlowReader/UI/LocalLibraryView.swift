import SwiftUI
import UniformTypeIdentifiers

struct LocalLibraryView: View {
    private enum Scope: String, CaseIterable { case cloud = "云端书架", local = "本机书籍" }
    @Environment(LibraryStore.self) private var library
    @Environment(CloudLibraryStore.self) private var cloud
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scope: Scope = .cloud
    @State private var choseInitialScope = false
    @State private var cloudCategory = ""
    @State private var importing = false
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var showingShare = false
    @State private var showingLogin = false
    @State private var showingServiceLogin = false
    @State private var openingCloudBook: Int?
    @State private var deleting: LocalBook?
    @State private var filter = ""
    @State private var path = NavigationPath()
    @Namespace private var covers
    @State private var savedAudio = AudioLibrary.shared

    private var filteredLocal: [LocalBook] { library.books.filter { matches($0.book) } }
    private var filteredCloud: [Book] {
        cloud.books.filter { matches($0) && (cloudCategory.isEmpty || $0.shelfName == cloudCategory) }
    }
    private var categories: [String] { Array(Set(cloud.books.compactMap(\.shelfName).filter { !$0.isEmpty })).sorted() }
    private var recent: LocalBook? {
        library.books.filter { $0.progress != nil }.max { ($0.progress?.updatedAt ?? .distantPast) < ($1.progress?.updatedAt ?? .distantPast) }
    }
    private var cloudResumeBooks: [Book] {
        let known = Dictionary(cloud.books.map { ($0.id, $0) } + library.books.map { ($0.id, $0.book) }, uniquingKeysWith: { first, _ in first })
        return Array(cloud.readingHistory.compactMap { known[$0.bookID] }.prefix(3))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    Picker("书库来源", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("library-scope")
                    .onChange(of: scope) { _, _ in choseInitialScope = true }
                    if filter.isEmpty {
                        if scope == .cloud { cloudContinueReading }
                        if let recent { continueReading(recent) }
                    }
                    if scope == .cloud { cloudContent } else { localContent }
                }
                .padding(24)
                .frame(maxWidth: 1040, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(FlowTheme.paper)
            .accessibilityIdentifier("library-content")
            .navigationTitle("书库")
            .navigationDestination(for: Book.self) { book in
                if reduceMotion { BookDetailView(book: book) }
                else { BookDetailView(book: book).navigationTransition(.zoom(sourceID: book.id, in: covers)) }
            }
            .readingDestinations()
            .searchable(text: $filter, prompt: "搜索书名、作者")
            .refreshable { if scope == .cloud { await cloud.refresh() } }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if scope == .cloud && cloud.isConnected {
                        Button("同步云端书架", systemImage: "arrow.clockwise") { Task { await cloud.refresh() } }
                            .disabled(cloud.shelf.loading || cloud.accountLoading)
                            .accessibilityIdentifier("cloud-library-refresh")
                    }
                    Menu {
                        Button("导入文本", systemImage: "doc.badge.plus") { importing = true }
                        Button("阅读原创示例", systemImage: "book") { library.seedDemoIfNeeded(); scope = .local }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("添加书籍")
                }
            }
            .task {
                await cloud.loadIfNeeded()
                if !choseInitialScope {
                    scope = cloud.isConnected ? .cloud : .local
                    choseInitialScope = true
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .utf8PlainText, .text]) { result in
                do { _ = try library.importText(url: result.get()); scope = .local } catch { self.error = error.localizedDescription }
            }
            .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
            .confirmationDialog("移除《\(deleting?.book.title ?? "")》及其下载的章节？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("移除藏书", role: .destructive) { if let deleting { library.remove(bookID: deleting.id) }; deleting = nil }
            }
            .sheet(isPresented: $showingShare) { if let exportURL { ActivitySheet(items: [exportURL]) } }
            .sheet(isPresented: $showingLogin, onDismiss: { Task { await cloud.refresh(); scope = .cloud } }) { WebLoginView() }
            .sheet(isPresented: $showingServiceLogin, onDismiss: { Task { await cloud.refresh() } }) { AccountServiceLoginView() }
            .onChange(of: savedAudio.errorMessage) { _, message in if let message { error = message; savedAudio.errorMessage = nil } }
            .onChange(of: cloud.sessionGeneration) { _, _ in cloudCategory = ""; path = NavigationPath() }
        }
    }

    @ViewBuilder private var cloudContent: some View {
        if !cloud.hasCheckedAccount {
            ProgressView("正在连接云端书架").frame(maxWidth: .infinity).padding(40)
        } else if !cloud.isConnected {
            ContentUnavailableView {
                Label("让书架与你同步", systemImage: "cloud")
            } description: {
                Text("登录菠萝包，在这里查看云端收藏。本机下载与导入的作品保留在“本机书籍”。")
            } actions: {
                Button("登录菠萝包") { showingLogin = true }.buttonStyle(.glassProminent)
                    .accessibilityIdentifier("cloud-library-login")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("云端收藏").font(.title2.bold())
                    Spacer()
                    if !cloud.books.isEmpty { Text("\(filteredCloud.count) 本").font(.subheadline).foregroundStyle(.secondary) }
                }
                if let account = cloud.account { Text(account.name).font(.subheadline).foregroundStyle(.secondary) }
            }
            if !categories.isEmpty {
                Menu {
                    Picker("书架分类", selection: $cloudCategory) {
                        Text("全部分类").tag("")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(cloudCategory.isEmpty ? "全部分类" : cloudCategory, systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline).lineLimit(1)
                }
            }
            if cloud.shelf.loading { ProgressView("正在同步书架").accessibilityIdentifier("shelf-loading") }
            if let error = cloud.shelf.error {
                cloudMessage(title: "书架暂时无法同步", message: error, identifier: "shelf-error")
            } else if let notice = cloud.shelf.notice {
                cloudMessage(title: "部分书架未能更新", message: notice, identifier: "shelf-partial")
            }
            if cloud.webNeedsLogin {
                Button("重新连接网页账号") { showingLogin = true }.buttonStyle(.glass)
            }
            if cloud.shelf.isConfirmedEmpty {
                ContentUnavailableView("暂无可读取的文字小说", systemImage: "books.vertical", description: Text("在菠萝包收藏喜欢的文字作品后，下拉即可同步。"))
                    .accessibilityIdentifier("shelf-empty")
            } else if !cloud.shelf.hasSnapshot && !cloud.shelf.loading && cloud.shelf.error == nil {
                cloudMessage(title: "书架尚未同步", message: "轻点重试，读取云端收藏。", identifier: "shelf-not-loaded")
            }
            LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 30) {
                ForEach(filteredCloud) { book in
                    NavigationLink(value: book) { coverCard(book, subtitle: book.author) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library-cloud-\(book.id)")
                }
            }
            .accessibilityIdentifier("cloud-library-books")
            if filteredCloud.isEmpty && cloud.shelf.hasSnapshot && (!filter.isEmpty || !cloudCategory.isEmpty) {
                ContentUnavailableView.search(text: filter.isEmpty ? cloudCategory : filter)
            }
        }
    }

    @ViewBuilder private var localContent: some View {
        if library.books.isEmpty && savedAudio.entries.isEmpty {
            ContentUnavailableView {
                Label("为故事留一个位置", systemImage: "books.vertical")
            } description: { Text("下载喜欢的章节，或导入自己的文本，随时离线阅读。") } actions: {
                Button("导入文本", systemImage: "plus") { importing = true }.buttonStyle(.glassProminent)
            }
        } else {
            HStack {
                Text("我的藏书").font(.title2.bold())
                Spacer()
                Text("\(filteredLocal.count) 本").font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 30) {
                ForEach(filteredLocal) { local in
                    NavigationLink(value: local.book) {
                        coverCard(local.book, subtitle: local.downloadedIDs.isEmpty ? "最近阅读" : "已下载 \(local.downloadedIDs.count) 章")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library-local-\(local.id)")
                    .contextMenu {
                        ForEach(ExportFormat.allCases) { format in
                            Button("导出 \(format.rawValue)", systemImage: "square.and.arrow.up") { export(local, as: format) }.disabled(local.downloadedIDs.isEmpty)
                        }
                        Button("移除本机藏书", systemImage: "trash", role: .destructive) { deleting = local }
                    }
                }
            }
            if filteredLocal.isEmpty && !filter.isEmpty { ContentUnavailableView.search(text: filter) }
            if !savedAudio.entries.isEmpty { offlineAudio }
        }
    }

    private var coverColumns: [GridItem] { [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 24)] }

    @ViewBuilder private var cloudContinueReading: some View {
        if !cloudResumeBooks.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Label("云端续读", systemImage: "icloud").font(.title2.bold())
                ForEach(cloudResumeBooks) { book in
                    if let progress = cloud.readingProgress(bookID: book.id) {
                        Button { Task { await openCloudPosition(book: book, progress: progress) } } label: {
                            HStack(spacing: 18) {
                                BookCover(book: book, width: 56, height: 80)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(book.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text(progress.chapterTitle ?? library.localBook(id: book.id)?.chapters.first(where: { $0.id == progress.chapterID })?.title ?? "继续官网保存的章节")
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    if let date = progress.updatedAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                if openingCloudBook == book.id { ProgressView() }
                                else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                            }
                            .padding(18).background(FlowTheme.card, in: .rect(cornerRadius: 20))
                        }
                        .buttonStyle(.plain).disabled(openingCloudBook != nil)
                        .accessibilityIdentifier("library-cloud-continue-\(book.id)")
                    }
                }
                Text("云端保留章节位置；同一章节会沿用本机段落。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if cloud.historyLoading { ProgressView("正在同步阅读位置").font(.subheadline) }
        if let message = cloud.historyError {
            HStack(alignment: .top, spacing: 12) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重试") { Task { await cloud.refreshHistory() } }.buttonStyle(.glass).disabled(cloud.historyLoading)
            }
        } else if cloud.hasCheckedAccount && cloud.isConnected && !cloud.appConnected {
            Button("连接账号服务以读取云端阅读位置", systemImage: "icloud") { showingServiceLogin = true }
                .font(.subheadline).buttonStyle(.glass)
        }
    }

    @MainActor private func openCloudPosition(book: Book, progress: CloudReadingProgress) async {
        guard let generation = cloud.sessionGeneration else { return }
        openingCloudBook = book.id
        defer { openingCloudBook = nil }
        do {
            let catalog: [Chapter]
            do { catalog = try await SFAPI.shared.chapters(bookID: book.id) }
            catch {
                guard !Task.isCancelled, let local = library.localBook(id: book.id),
                      local.chapters.contains(where: { $0.id == progress.chapterID }) else { throw error }
                catalog = local.chapters
            }
            guard !Task.isCancelled, await SFAPI.shared.sessionGeneration() == generation else { return }
            guard let chapter = catalog.first(where: { $0.id == progress.chapterID && $0.bookID == book.id }) else {
                throw SFAPIError.server("云端记录的章节暂时不在当前目录中，请在作品页选择章节。")
            }
            path.append(ReadingRoute(book: book, chapters: catalog, initialChapter: chapter))
        } catch {
            guard !Task.isCancelled, !AccountShelfState.isCancellation(error),
                  await SFAPI.shared.sessionGeneration() == generation else { return }
            self.error = error.localizedDescription
        }
    }

    private func coverCard(_ book: Book, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BookCover(book: book, width: 140, height: 200).matchedTransitionSource(id: book.id, in: covers)
            Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cloudMessage(title: String, message: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") { Task { await cloud.refresh() } }
                .buttonStyle(.glass).disabled(cloud.shelf.loading || cloud.accountLoading)
                .accessibilityIdentifier("shelf-retry")
        }
        .accessibilityIdentifier(identifier)
    }

    private var offlineAudio: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("离线有声").font(.title2.bold())
            ForEach(savedAudio.entries.filter { filter.isEmpty || $0.book.title.localizedCaseInsensitiveContains(filter) || $0.track.title.localizedCaseInsensitiveContains(filter) }) { entry in
                NavigationLink {
                    let tracks = savedAudio.entries.filter { $0.book.id == entry.book.id }.map(\.track).sorted { $0.order < $1.order }
                    AudioPlayerView(book: entry.book, tracks: tracks, initialIndex: tracks.firstIndex(where: { $0.id == entry.track.id }) ?? 0)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(FlowTheme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.track.title).font(.headline).foregroundStyle(.primary)
                            Text(entry.book.title).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle").foregroundStyle(FlowTheme.accent)
                    }.padding(18).background(FlowTheme.card, in: .rect(cornerRadius: 18))
                }.buttonStyle(.plain).contextMenu {
                    Button("导出音频", systemImage: "square.and.arrow.up") {
                        do { exportURL = try savedAudio.export(entry); showingShare = true } catch { self.error = error.localizedDescription }
                    }
                    Button("移除音频", systemImage: "trash", role: .destructive) { savedAudio.remove(entry) }
                }
            }
        }
    }

    private func continueReading(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("接着读").font(.title2.bold())
            if let chapter = local.chapters.first(where: { $0.id == local.progress?.chapterID }) ?? local.chapters.first {
                NavigationLink(value: ReadingRoute(book: local.book, chapters: local.chapters, initialChapter: chapter)) {
                    HStack(spacing: 20) {
                        BookCover(book: local.book, width: 76, height: 108)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(local.book.title).font(.headline).foregroundStyle(.primary)
                            Text(chapter.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Label("本机阅读位置", systemImage: "book.pages").font(.caption).foregroundStyle(FlowTheme.accent)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(20).background(FlowTheme.card, in: .rect(cornerRadius: 22))
                }.buttonStyle(.plain).accessibilityIdentifier("library-continue-reading")
            }
        }
    }

    private func matches(_ book: Book) -> Bool { filter.isEmpty || book.title.localizedCaseInsensitiveContains(filter) || book.author.localizedCaseInsensitiveContains(filter) }

    private func export(_ local: LocalBook, as format: ExportFormat) {
        do {
            exportURL = try BookExporter.export(book: local.book, chapters: library.downloadedContent(bookID: local.id), format: format)
            showingShare = true
        } catch { self.error = error.localizedDescription }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
