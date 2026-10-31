import SwiftUI

struct BookDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CloudLibraryStore.self) private var cloud
    @Environment(ReadingSession.self) private var readingSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State var book: Book
    @State private var chapters: [Chapter] = []
    @State private var tracks: [AudioTrack] = []
    @State private var loading = true
    @State private var audioLoading = false
    @State private var error: String?
    @State private var audioError: String?
    @State private var showDownload = false
    @State private var contentKind = 0
    @State private var expandedSummary = false
    @State private var loadRequest = UUID()
    @State private var purchaseRequest = UUID()
    @State private var purchaseTask: Task<Void, Never>?
    @State private var purchaseLoading = false
    @State private var purchaseError: String?
    @State private var purchaseNeedsLogin = false
    @State private var showPurchaseLogin = false
    @State private var orderingChapter: Chapter?
    @State private var purchasedReadingChapter: Chapter?

    private var isSaved: Bool { library.books.contains { $0.id == book.id } }
    private var readingChapter: Chapter? {
        if let progress = library.localBook(id: book.id)?.progress,
           let chapter = chapters.first(where: { $0.id == progress.chapterID }) { return chapter }
        return chapters.first
    }
    private var volumes: [String] { chapters.reduce(into: [String]()) { if !$0.contains($1.volumeTitle) { $0.append($1.volumeTitle) } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                bookHeader
                if !book.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(book.summary)
                            .font(.subheadline).foregroundStyle(.secondary).lineSpacing(6)
                            .lineLimit(expandedSummary ? nil : 5)
                        Button(expandedSummary ? "收起简介" : "展开简介") { expandedSummary.toggle() }
                            .font(.caption)
                    }
                }
                cloudReadingPosition
                actions
                Divider()
                HStack {
                    Text("作品目录").font(.title3.weight(.semibold))
                    Spacer()
                    Picker("内容类型", selection: $contentKind) {
                        Text("文字").tag(0)
                        Text("有声").tag(1)
                    }.pickerStyle(.segmented).frame(maxWidth: 160)
                }
                if contentKind == 0 {
                    if chapters.contains(where: \.isVIP) { purchaseStatus }
                    textCatalog
                } else { audioCatalog }
            }
            .padding(horizontalSizeClass == .regular ? 36 : 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(FlowTheme.paper)
        .navigationTitle("作品")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.save(book: book, chapters: chapters)
                } label: {
                    Label(isSaved ? "已在书库" : "加入书库", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                }
                .accessibilityIdentifier("save-book")
            }
        }
        .sheet(isPresented: $showDownload) {
            ChapterDownloadSheet(book: book, chapters: chapters)
        }
        .sheet(isPresented: $showPurchaseLogin, onDismiss: { Task { await cloud.checkSessionGeneration(); startPurchaseRefresh() } }) { AccountServiceLoginView() }
        .sheet(item: $orderingChapter, onDismiss: {
            guard let chapter = purchasedReadingChapter else { return }
            purchasedReadingChapter = nil
            startPurchaseRefresh()
            readingSession.open(ReadingRoute(book: book, chapters: chapters, initialChapter: chapter))
        }) { chapter in
            ChapterPurchaseSheet(book: book, chapter: chapter) { purchasedReadingChapter = $0 }
        }
        .task(id: cloud.sessionGeneration) { await loadBook() }
        .task(id: cloud.sessionGeneration) { if book.id > 0 { await cloud.loadHistoryIfNeeded() } }
        .onChange(of: contentKind) { _, kind in
            if kind == 1 && tracks.isEmpty { Task { await loadAudio() } }
        }
    }

    private var bookHeader: some View {
        HStack(alignment: .top, spacing: 24) {
            BookCover(book: book, width: horizontalSizeClass == .regular ? 140 : 108, height: horizontalSizeClass == .regular ? 196 : 153)
            VStack(alignment: .leading, spacing: 12) {
                Text(book.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(book.isFinished ? "已完结" : "连载中")
                    if let category = book.category { Text(category) }
                }.font(.caption).foregroundStyle(FlowTheme.accent)
                if let words = book.wordCount, words > 0 {
                    Text(words >= 10_000 ? "\(words / 10_000) 万字" : "\(words) 字")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let first = readingChapter {
                Button { openChapter(first) } label: {
                    Label(library.localBook(id: book.id)?.progress == nil ? "开始阅读" : "继续阅读", systemImage: "book.pages")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("start-reading")
            }
            Button { showDownload = true } label: {
                Label("下载", systemImage: "arrow.down")
                    .padding(.vertical, 5)
            }
            .buttonStyle(.glass)
            .disabled(chapters.isEmpty)
            .accessibilityIdentifier("download-chapters")
        }
    }

    @ViewBuilder private var cloudReadingPosition: some View {
        if let progress = cloud.readingProgress(bookID: book.id),
           library.localBook(id: book.id)?.progress?.chapterID != progress.chapterID,
           let chapter = chapters.first(where: { $0.id == progress.chapterID && $0.bookID == book.id }) {
            Button { readingSession.open(ReadingRoute(book: book, chapters: chapters, initialChapter: chapter)) } label: {
                HStack(spacing: 16) {
                    Image(systemName: "icloud").font(.title2).foregroundStyle(FlowTheme.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("从云端继续").font(.headline).foregroundStyle(.primary)
                        Text(chapter.title).font(.subheadline).foregroundStyle(.secondary)
                        if let date = progress.updatedAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }.padding(18).background(FlowTheme.card, in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain).accessibilityIdentifier("book-cloud-continue")
        } else if book.id > 0 && cloud.historyLoading {
            ProgressView("正在读取云端阅读位置").font(.subheadline)
        } else if book.id > 0, let message = cloud.historyError {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("重试云端阅读位置") { Task { await cloud.refreshHistory() } }.font(.subheadline)
            }
        }
    }

    @ViewBuilder private var purchaseStatus: some View {
        if purchaseLoading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在确认购买状态").font(.caption).foregroundStyle(.secondary) }
        } else if let purchaseError {
            HStack(alignment: .top, spacing: 14) {
                Text(purchaseError).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if purchaseNeedsLogin {
                    Button("连接") { showPurchaseLogin = true }.font(.caption)
                } else {
                    Button("重试") { startPurchaseRefresh() }.font(.caption)
                }
            }
            .accessibilityIdentifier("chapter-purchase-status")
        }
    }

    @ViewBuilder private var textCatalog: some View {
        if loading {
            ProgressView("正在加载目录").frame(maxWidth: .infinity).padding(36)
        } else if let error {
            FlowErrorView(message: error) { Task { await loadBook() } }
        } else if chapters.isEmpty {
            ContentUnavailableView("暂无文字章节", systemImage: "text.book.closed")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(volumes, id: \.self) { volume in
                    Text(volume.isEmpty ? "正文" : volume)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FlowTheme.accent)
                        .padding(.top, 18).padding(.bottom, 10)
                    ForEach(chapters.filter { $0.volumeTitle == volume }) { chapter in
                        Button { openChapter(chapter) } label: {
                            HStack(spacing: 12) {
                                Text(chapter.title).font(.subheadline).foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                ChapterPurchaseBadge(chapter: chapter)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 15)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("book-chapter-\(chapter.id)")
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private func openChapter(_ chapter: Chapter) {
        let state = cloud.purchaseState(for: chapter)
        if ChapterCommerceClient.usesUITestFixture && chapter.id == chapters.first?.id {
            orderingChapter = chapter
        } else if library.cachedContent(chapter: chapter) != nil {
            // A valid local download remains readable even if today's remote quote is positive.
            readingSession.open(ReadingRoute(book: book, chapters: chapters, initialChapter: chapter))
        } else if state == .notPurchased || state == .requiresPurchase {
            orderingChapter = chapter
        } else {
            readingSession.open(ReadingRoute(book: book, chapters: chapters, initialChapter: chapter))
        }
    }

    @ViewBuilder private var audioCatalog: some View {
        if audioLoading {
            ProgressView("正在加载有声目录").frame(maxWidth: .infinity).padding(36)
        } else if let audioError {
            FlowErrorView(message: audioError) { Task { await loadAudio() } }
        } else if tracks.isEmpty {
            ContentUnavailableView("暂无有声章节", systemImage: "headphones")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    NavigationLink {
                        AudioPlayerView(book: book, tracks: tracks, initialIndex: index)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "play.circle").font(.title3).foregroundStyle(FlowTheme.accent)
                            Text(track.title).font(.subheadline).foregroundStyle(.primary)
                            Spacer()
                            if track.isVIP { Text("VIP").font(.caption2.weight(.medium)).foregroundStyle(.secondary).accessibilityLabel("付费音轨") }
                        }.padding(.vertical, 15)
                    }.buttonStyle(.plain)
                    Divider().opacity(0.5)
                }
            }
        }
    }

    @MainActor private func loadBook() async {
        let request = UUID()
        loadRequest = request
        purchaseTask?.cancel()
        purchaseRequest = UUID()
        purchaseLoading = false
        purchaseError = nil
        if book.id < 0, let local = library.localBook(id: book.id) {
            chapters = local.chapters
            loading = false
            return
        }
        loading = true
        error = nil
        if let local = library.localBook(id: book.id) { chapters = local.chapters }
        do {
            async let detail = SFAPI.shared.detail(bookID: book.id)
            async let catalog = SFAPI.shared.chapters(bookID: book.id)
            let (updated, result) = try await (detail, catalog)
            guard loadRequest == request, !Task.isCancelled else { return }
            book = updated
            chapters = result
        } catch {
            guard loadRequest == request, !Task.isCancelled else { return }
            self.error = chapters.isEmpty ? error.localizedDescription : nil
        }
        loading = false
        startPurchaseRefresh()
    }

    @MainActor private func startPurchaseRefresh() {
        purchaseTask?.cancel()
        let request = UUID()
        purchaseRequest = request
        let catalogRequest = loadRequest
        guard book.id > 0, chapters.contains(where: \.isVIP) else { return }
        purchaseTask = Task { await loadPurchaseStates(request: request, catalogRequest: catalogRequest) }
    }

    @MainActor private func loadPurchaseStates(request: UUID, catalogRequest: UUID) async {
        purchaseLoading = true
        purchaseError = nil
        purchaseNeedsLogin = false
        defer { if purchaseRequest == request { purchaseLoading = false } }
        guard await SFAPI.shared.hasAppSession() else {
            guard purchaseRequest == request, !Task.isCancelled else { return }
            purchaseError = "连接同一账号的账号服务后，可确认购买状态。"
            purchaseNeedsLogin = true
            return
        }
        do {
            let snapshot = try await SFAPI.shared.chapterPurchaseStates(bookID: book.id)
            let currentGeneration = await SFAPI.shared.sessionGeneration()
            guard purchaseRequest == request, loadRequest == catalogRequest, !Task.isCancelled,
                  snapshot.generation == currentGeneration else { return }
            cloud.applyPurchaseSnapshot(snapshot, bookID: book.id)
            chapters = chapters.map { chapter in
                var updated = chapter
                updated.confirmedPurchaseState = snapshot.states[chapter.id] ?? .unknown
                updated.purchaseSessionGeneration = snapshot.generation
                return updated
            }
        } catch {
            guard purchaseRequest == request, loadRequest == catalogRequest, !Task.isCancelled,
                  !AccountShelfState.isCancellation(error) else { return }
            purchaseError = error.localizedDescription
            switch error {
            case SFAPIError.loginRequired, SFAPIError.authenticationRequired: purchaseNeedsLogin = true
            default: break
            }
        }
    }

    @MainActor private func loadAudio() async {
        if book.id < 0 { tracks = []; return }
        audioLoading = true
        audioError = nil
        do { tracks = try await SFAPI.shared.audioTracks(bookID: book.id) }
        catch { audioError = error.localizedDescription }
        audioLoading = false
    }
}

private struct ChapterDownloadSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapters: [Chapter]
    @State private var selection: Set<Int> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(selection.count == chapters.count ? "取消全选" : "全选") {
                        selection = selection.count == chapters.count ? [] : Set(chapters.map(\.id))
                    }
                    .accessibilityIdentifier("download-select-all")
                } footer: {
                    Text("仅保存当前账号有权阅读的章节。")
                }
                ForEach(chapters) { chapter in
                    Button {
                        if selection.contains(chapter.id) { selection.remove(chapter.id) }
                        else { selection.insert(chapter.id) }
                    } label: {
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selection.contains(chapter.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(chapter.id) ? FlowTheme.accent : Color.secondary)
                        }
                    }
                    .accessibilityAddTraits(selection.contains(chapter.id) ? .isSelected : [])
                }
            }
            .navigationTitle("选择章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("download-selection-cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载 \(selection.count)") {
                        library.download(book: book, chapters: chapters.filter { selection.contains($0.id) })
                        dismiss()
                    }.disabled(selection.isEmpty).accessibilityIdentifier("download-selection-confirm")
                }
            }
        }
        .tint(FlowTheme.accent)
    }
}
