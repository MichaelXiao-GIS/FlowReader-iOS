import SwiftUI
import UIKit

struct ReaderView: View {
    let book: Book
    let chapters: [Chapter]
    @Environment(LibraryStore.self) private var library
    @Environment(CloudLibraryStore.self) private var cloud
    @Environment(ReadingSession.self) private var readingSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Chapter
    @State private var content: ChapterContent?
    @State private var paragraphs: [String] = []
    @State private var loading = false
    @State private var loadRevision = 0
    @State private var syncRetryTask: Task<Void, Never>?
    @State private var error: String?
    @State private var showContents = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var bookmarks = ReaderBookmarkStore.shared
    @State private var bookmarkError: String?
    @State private var subscriptionRequired = false
    @State private var orderingChapter: Chapter?
    @State private var reloadAfterPurchase = false
    @State private var requestedPosition: ReaderTextPosition?
    @State private var scrollJumpRevision = 0
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var showChrome = false
    @State private var readingPosition = ReaderTextPosition(paragraph: 0, utf16Offset: 0)
    @State private var pagination: ReaderPagination?
    @State private var paginationLayout: ReaderLayoutKey?
    @State private var openAtEnd = false
    @State private var visibleParagraph: Int?
    @State private var shouldContinueSpeaking = false
    @State private var progressGeneration: UUID?
    @State private var cloudProgressMessage: String?
    @State private var cloudProgressFailed = false
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0
    @AppStorage("reader.fontSize") private var fontSize = 21.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 10.0
    @AppStorage("reader.theme") private var theme = "paper"
    @AppStorage("reader.serif") private var serif = true
    @AppStorage("reader.turnMode") private var turnMode = "scroll"
    @AppStorage("reader.landscapeSpread") private var landscapeSpread = true
    private var audio: AudioController { .shared }

    init(book: Book, chapters: [Chapter], initialChapter: Chapter) {
        self.book = book
        self.chapters = chapters
        _selected = State(initialValue: initialChapter)
    }
    init(book: Book, chapter: Chapter, catalog: [Chapter]) {
        self.init(book: book, chapters: catalog, initialChapter: chapter)
    }

    private var background: Color {
        switch theme {
        case "night": Color.black
        case "white": colorScheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color.white
        default: colorScheme == .dark ? Color(red: 0.12, green: 0.11, blue: 0.10) : Color(red: 0.97, green: 0.95, blue: 0.90)
        }
    }
    private var foreground: Color { theme == "night" || colorScheme == .dark ? Color(white: 0.88) : Color(red: 0.18, green: 0.16, blue: 0.13) }
    private var bodyFont: Font {
        let size = fontSize * textScale
        guard serif else { return .system(size: size) }
        let font = ["SongtiSC-Regular", "STSongti-SC-Regular", "STSong"].lazy.compactMap { UIFont(name: $0, size: size) }.first
        return font.map { .custom($0.fontName, size: size) } ?? .system(size: size, design: .serif)
    }
    private var chapterIsRemote: Bool { selected.id > 0 && book.id > 0 }
    private var chapterIndex: Int { chapters.firstIndex(where: { $0.id == selected.id }) ?? 0 }

    var body: some View {
        readingPage
        .background(background)
        .statusBarHidden(true)
        .preferredColorScheme(theme == "night" ? .dark : nil)
        .persistentSystemOverlays(showChrome ? .automatic : .hidden)
        .interactiveDismissDisabled()
        .task(id: "\(selected.id):\(loadRevision)") { await load() }
        .sheet(isPresented: $showContents) {
            NavigationStack {
                contentsList
                    .navigationTitle("目录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showContents = false } } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) { settings }
        .sheet(isPresented: $showBookmarks) { bookmarkList }
        .sheet(item: $orderingChapter, onDismiss: {
            if reloadAfterPurchase { reloadAfterPurchase = false; loadRevision += 1 }
        }) { chapter in
            ChapterPurchaseSheet(book: book, chapter: chapter) { authorized in
                if authorized.id == selected.id { reloadAfterPurchase = true }
            }
        }
        .alert("书签暂未保存", isPresented: Binding(get: { bookmarkError != nil }, set: { if !$0 { bookmarkError = nil } })) {
            Button("好", role: .cancel) { bookmarkError = nil }
        } message: { Text(bookmarkError ?? "") }
        .onDisappear { syncRetryTask?.cancel(); saveProgress() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveProgress() } }
        .onChange(of: readingPosition) { _, _ in if turnMode == "curl" { saveProgress() } }
        .onChange(of: turnMode) { _, mode in
            if mode == "scroll" { visibleParagraph = readingPosition.paragraph }
        }
    }

    private var readingPage: some View {
        GeometryReader { safeGeometry in
            readerViewport(safeArea: safeGeometry.safeAreaInsets)
                .ignoresSafeArea()
        }
        .foregroundStyle(foreground)
        .accessibilityAction(named: showChrome ? "隐藏阅读工具" : "显示阅读工具", toggleChrome)
        .accessibilityAction(.escape) { closeReader() }
    }

    private func readerViewport(safeArea: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let insets = UIEdgeInsets(top: safeArea.top, left: safeArea.leading, bottom: safeArea.bottom, right: safeArea.trailing)
            let layout = ReaderViewportLayout(size: geometry.size, safeAreaInsets: insets, occlusions: readingOcclusions(in: geometry))
            ZStack(alignment: .topLeading) {
                background.ignoresSafeArea()
                Group {
                    if loading {
                        ProgressView("正在打开章节…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error {
                        ContentUnavailableView {
                            Label(subscriptionRequired ? "本章需要订阅" : "暂时无法打开", systemImage: subscriptionRequired ? "lock" : "book.closed")
                        } description: { Text(subscriptionRequired ? "订阅这一章后，即可在这里继续阅读。" : error) } actions: {
                            if subscriptionRequired {
                                Button("购买本章") { orderingChapter = selected }.buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("reader-purchase-chapter")
                            } else {
                                Button("重试") { loadRevision += 1 }.buttonStyle(.borderedProminent)
                            }
                            if chapterIsRemote {
                                Link("在官方页面查看", destination: selected.officialURL).buttonStyle(.glass)
                            }
                        }
                    } else if content != nil {
                        if turnMode == "curl" { pagedViewport(safeArea: safeArea) }
                        else {
                            scrollingContent
                                .frame(width: layout.contentFrame.width, height: layout.contentFrame.height)
                                .position(x: layout.contentFrame.midX, y: layout.contentFrame.midY)
                        }
                    }
                }
                if showChrome || loading || error != nil { readerChrome(layout: layout).transition(.opacity) }
            }
        }
    }

    private var scrollingContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(book.title).font(.subheadline).foregroundStyle(foreground.opacity(0.55))
                    Text(selected.title).font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .accessibilityIdentifier("reader-chapter-title")
                    Rectangle().fill(foreground.opacity(0.12)).frame(width: 48, height: 1).padding(.top, 8)
                }.padding(.top, 38).padding(.bottom, 14)
                LazyVStack(alignment: .leading, spacing: lineSpacing + 6) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text("　　" + paragraph)
                            .font(bodyFont)
                            .lineSpacing(lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("reader-paragraph-\(index)")
                            .id(index)
                    }
                }.scrollTargetLayout()
                VStack(spacing: 16) {
                    Image(systemName: "leaf").font(.title3).foregroundStyle(foreground.opacity(0.35))
                    Text(chapterIndex + 1 < chapters.count ? "本章完" : "已读至最后一章")
                        .font(.footnote).foregroundStyle(foreground.opacity(0.5))
                }.frame(maxWidth: .infinity).padding(.vertical, 38)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        .id(selected.id)
        .accessibilityIdentifier("reader-content")
        .scrollIndicators(.hidden)
        .contentMargins(0, for: .scrollContent)
        .scrollPosition(id: $visibleParagraph, anchor: .top)
        .onChange(of: visibleParagraph) { _, value in
            guard turnMode == "scroll", let value else { return }
            if value != readingPosition.paragraph {
                readingPosition = ReaderTextPosition(paragraph: value, utf16Offset: 0)
            }
            saveProgress()
        }
        .onTapGesture(perform: toggleChrome)
        .onChange(of: scrollJumpRevision) { _, _ in
            proxy.scrollTo(readingPosition.paragraph, anchor: .top)
        }
        }
    }

    private func pagedViewport(safeArea: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let insets = UIEdgeInsets(top: safeArea.top, left: safeArea.leading, bottom: safeArea.bottom, right: safeArea.trailing)
            let occlusions = readingOcclusions(in: geometry)
            let spreadSize = CurlPageReader.textSize(for: geometry.size, doublePage: true, safeAreaInsets: insets, occlusions: occlusions)
            let spread = landscapeSpread && geometry.size.width > geometry.size.height
                && spreadSize.width >= max(240, fontSize * textScale * 8) && spreadSize.height >= 240
            let textSize = CurlPageReader.textSize(for: geometry.size, doublePage: spread, safeAreaInsets: insets, occlusions: occlusions)
            let layout = ReaderLayoutKey(chapterID: selected.id, textSize: textSize, fontSize: fontSize * textScale, lineSpacing: lineSpacing, serif: serif)
            Group {
                if let pagination, paginationLayout == layout {
                    CurlPageReader(pagination: pagination, currentPosition: $readingPosition, doublePage: spread,
                                   background: UIColor(background), foreground: UIColor(foreground),
                                   bookTitle: book.title, chapterTitle: selected.title,
                                   onToggleChrome: toggleChrome, onChapterBoundary: { move($0, fromPageBoundary: true) },
                                   reduceMotion: reduceMotion, safeAreaInsets: insets, occlusions: occlusions)
                } else {
                    ProgressView("正在排版…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle()).onTapGesture(perform: toggleChrome)
                }
            }
            .task(id: layout) {
                let source = paragraphs
                let worker = Task.detached(priority: .userInitiated) {
                    ReaderPagination(paragraphs: source, fontSize: layout.fontSize,
                                     lineSpacing: layout.lineSpacing, serif: layout.serif, textSize: layout.textSize)
                }
                let result = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, selected.id == layout.chapterID else { return }
                pagination = result
                paginationLayout = layout
            }
        }
    }

    private func readingOcclusions(in geometry: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return geometry.reservedRegions(kind: .occlusion).filter(\.isActive).map { region in
                let margins = region.margins
                return CGRect(x: region.frame.minX - margins.leading, y: region.frame.minY - margins.top,
                              width: region.frame.width + margins.leading + margins.trailing,
                              height: region.frame.height + margins.top + margins.bottom)
            }
        }
        return []
    }

    private func readerChrome(layout: ReaderViewportLayout) -> some View {
        ReaderChrome(layout: layout, paper: background,
                     bookmarked: currentBookmark != nil, contentAvailable: content != nil && !loading,
                     speaking: audio.isSpeech && audio.isPlaying && audio.title == selected.title,
                     canGoBack: chapterIndex > 0, canGoForward: chapterIndex + 1 < chapters.count,
                     progressDescription: progressDescription,
                     progressAccessibilityLabel: turnMode == "curl" ? "本章分页进度" : "本章段落进度",
                     canSeek: progressCount > 1, progress: progressBinding, onScrubbing: scrub,
                     onBookmark: toggleBookmark, onBookmarks: { showBookmarks = true },
                     onClose: closeReader, onContents: { showContents = true },
                     onSettings: { showSettings = true }, onSpeak: toggleSpeech,
                     onPrevious: { move(-1) }, onNext: { move(1) }) { moreMenu }
    }

    private var currentBookmark: ReaderBookmark? {
        bookmarks.bookmark(bookID: book.id, chapterID: selected.id, position: readingPosition)
    }

    private var progressCount: Int { turnMode == "curl" ? pagination?.pages.count ?? 0 : paragraphs.count }
    private var progressIndex: Int {
        turnMode == "curl" ? pagination?.pageIndex(for: readingPosition) ?? 0 : readingPosition.paragraph
    }
    private var progressFraction: Double { ReaderProgressNavigation.fraction(index: progressIndex, count: progressCount) }
    private var progressDescription: String {
        let fraction = isScrubbing ? scrubProgress : progressFraction
        let index = isScrubbing ? ReaderProgressNavigation.index(fraction: fraction, count: progressCount) : progressIndex
        let unit = turnMode == "curl" ? "页" : "段"
        guard progressCount > 0 else { return "正在计算本章进度" }
        guard progressCount > 1 else { return "本章 · 1/1 \(unit)" }
        return "本章 \(Int((fraction * 100).rounded()))% · \(min(index + 1, progressCount))/\(progressCount) \(unit)"
    }
    private var progressBinding: Binding<Double> {
        Binding(get: { isScrubbing ? scrubProgress : progressFraction }, set: { value in
            scrubProgress = value
            // Accessibility slider adjustments may not emit an editing transition.
            if !isScrubbing { seek(to: value) }
        })
    }
    private func scrub(_ editing: Bool) {
        if editing { scrubProgress = progressFraction; isScrubbing = true }
        else { isScrubbing = false; seek(to: scrubProgress) }
    }
    private func seek(to fraction: Double) {
        guard content != nil else { return }
        let index = ReaderProgressNavigation.index(fraction: fraction, count: progressCount)
        if turnMode == "curl", let pagination, pagination.pages.indices.contains(index) {
            jump(to: pagination.pages[index].startPosition)
        } else { jump(to: ReaderTextPosition(paragraph: index, utf16Offset: 0)) }
    }
    private func jump(to position: ReaderTextPosition) {
        readingPosition = ReaderProgressNavigation.bounded(position, paragraphs: paragraphs)
        visibleParagraph = readingPosition.paragraph
        scrollJumpRevision += 1
        saveProgress()
    }
    private func toggleBookmark() {
        guard content != nil else { return }
        let excerpt = paragraphs.indices.contains(readingPosition.paragraph) ? paragraphs[readingPosition.paragraph] : ""
        do { try bookmarks.toggle(bookID: book.id, chapter: selected, position: readingPosition, excerpt: excerpt) }
        catch { bookmarkError = error.localizedDescription }
    }
    private func toggleSpeech() {
        if audio.isSpeech && audio.title == selected.title { audio.toggle() } else { speakCurrent() }
    }

    private var bookmarkList: some View {
        NavigationStack {
            Group {
                let saved = bookmarks.bookmarks(bookID: book.id)
                if let error = bookmarks.loadError {
                    ContentUnavailableView("书签暂时无法读取", systemImage: "exclamationmark.book", description: Text(error))
                } else if saved.isEmpty {
                    ContentUnavailableView("还没有书签", systemImage: "bookmark", description: Text("轻点阅读左上角的书签按钮，保存当前章节和段落位置。"))
                } else {
                    List(saved) { bookmark in
                        Button {
                            guard let chapter = chapters.first(where: { $0.id == bookmark.chapterID }) else { return }
                            select(chapter, at: bookmark.position)
                            showBookmarks = false
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(bookmark.chapterTitle).font(.headline).foregroundStyle(.primary)
                                Text(bookmark.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                Text("第 \(bookmark.position.paragraph + 1) 段 · \(bookmark.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.tertiary)
                                if !chapters.contains(where: { $0.id == bookmark.chapterID }) {
                                    Text("当前目录中暂无此章").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5)
                        }
                        .disabled(!chapters.contains(where: { $0.id == bookmark.chapterID }))
                        .accessibilityIdentifier("reader-bookmark-\(bookmark.id.uuidString)")
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                do { try bookmarks.remove(id: bookmark.id) }
                                catch { bookmarkError = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .navigationTitle("本书书签").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showBookmarks = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var moreMenu: some View {
        Menu {
            if cloudProgressFailed { Label("云端暂未同步，本机位置已保存", systemImage: "exclamationmark.icloud") }
            Button("书签", systemImage: "bookmark") { showBookmarks = true }
                .accessibilityIdentifier("reader-bookmarks-menu")
            Button("上一章", systemImage: "chevron.left") { move(-1) }.disabled(chapterIndex == 0)
            Button("下一章", systemImage: "chevron.right") { move(1) }.disabled(chapterIndex + 1 >= chapters.count)
            Button { library.download(book: book, chapters: [selected]) } label: { Label("下载本章", systemImage: "arrow.down.circle") }
            if audio.isSpeech { Button("停止朗读", systemImage: "stop.circle") { audio.stop() } }
            Button("隐藏阅读工具", systemImage: "eye.slash", action: toggleChrome)
        } label: { Image(systemName: cloudProgressFailed ? "exclamationmark.icloud" : "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel(cloudProgressFailed ? "云端进度未同步，更多阅读选项" : "更多阅读选项")
            .accessibilityIdentifier("reader-more")
    }

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showChrome.toggle() }
    }

    private var contentsList: some View {
        List {
            ForEach(Array(Dictionary(grouping: chapters, by: \.volumeTitle).keys).sorted { lhs, rhs in
                (chapters.firstIndex(where: { $0.volumeTitle == lhs }) ?? 0) < (chapters.firstIndex(where: { $0.volumeTitle == rhs }) ?? 0)
            }, id: \.self) { volume in
                Section(volume.isEmpty ? "正文" : volume) {
                    ForEach(chapters.filter { $0.volumeTitle == volume }) { chapter in
                        Button {
                            select(chapter)
                            showContents = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(chapter.title).foregroundStyle(chapter.id == selected.id ? FlowTheme.accent : .primary)
                                Spacer()
                                if library.localBook(id: book.id)?.downloadedIDs.contains(chapter.id) == true {
                                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).font(.caption)
                                        .accessibilityLabel("已下载")
                                }
                                ChapterPurchaseBadge(chapter: chapter)
                                if chapter.id == selected.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(FlowTheme.accent).font(.caption) }
                            }.padding(.vertical, 5)
                        }.accessibilityIdentifier("reader-chapter-\(chapter.id)").listRowBackground(chapter.id == selected.id ? FlowTheme.accent.opacity(0.07) : Color.clear)
                    }
                }
            }
        }.listStyle(.insetGrouped)
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("翻页方式", selection: $turnMode) {
                        Text("上下滚动").tag("scroll")
                        Text("仿真翻页").tag("curl")
                    }.pickerStyle(.segmented).accessibilityIdentifier("reader-turn-mode")
                    if turnMode == "curl" {
                        Toggle("横屏双栏", isOn: $landscapeSpread).accessibilityIdentifier("reader-landscape-spread")
                    }
                } header: { Text("阅读方式") } footer: {
                    Text(turnMode == "curl" ? "左右轻扫或轻点页边翻页，轻点中央显示工具。横屏空间充足时显示双页。" : "上下滑动阅读，轻点正文显示或隐藏工具。")
                }
                Section("文字") {
                    HStack {
                        Text("字号")
                        Slider(value: $fontSize, in: 16...34, step: 1).accessibilityLabel("字号").accessibilityIdentifier("reader-font-size")
                        Text("\(Int(fontSize))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("行距")
                        Slider(value: $lineSpacing, in: 4...20, step: 1).accessibilityLabel("行距")
                    }
                    Toggle("衬线字体", isOn: $serif)
                }
                Section("纸张") {
                    Picker("阅读主题", selection: $theme) {
                        Text("暖纸").tag("paper")
                        Text("素白").tag("white")
                        Text("夜读").tag("night")
                    }.pickerStyle(.segmented)
                }
                Section("朗读") {
                    Button { speakCurrent(); showSettings = false } label: { Label("从本章开始朗读", systemImage: "speaker.wave.2") }
                    Picker("睡眠定时", selection: Binding(get: { audio.sleepMinutes }, set: { audio.sleepMinutes = $0 })) {
                        Text("关闭").tag(0)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                }
                Section("阅读位置") {
                    Text(cloudProgressMessage ?? "段落位置已保存在本机。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if chapterIsRemote {
                        Text("云端同步到章节，段落位置由本机保存。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if cloudProgressFailed {
                        Button("重试同步本章") {
                            guard let generation = progressGeneration else { return }
                            syncRetryTask?.cancel()
                            syncRetryTask = Task { await synchronizeProgress(chapter: selected, generation: generation) }
                        }
                    }
                }
            }
            .navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false }.accessibilityIdentifier("reader-settings-done") } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    @MainActor private func load() async {
        loading = true; error = nil; content = nil; paragraphs = []; pagination = nil
        subscriptionRequired = false
        cloudProgressMessage = nil; cloudProgressFailed = false
        let target = selected
        let generation = await SFAPI.shared.sessionGeneration()
        progressGeneration = generation
        let saved = library.localBook(id: book.id)?.progress
        do {
            let loaded = try await library.content(chapter: target)
            try Task.checkCancellation()
            guard selected.id == target.id else { return }
            await cloud.applyChapterAccess(loaded.chapter)
            try Task.checkCancellation()
            guard selected.id == target.id else { return }
            content = loaded
            // Split a chapter once, not on every scroll/progress or chrome update.
            paragraphs = loaded.text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            loading = false
            let destination = requestedPosition
            let restoredParagraph = destination?.paragraph ?? (openAtEnd ? max(0, paragraphs.count - 1) : (saved?.chapterID == target.id ? (saved?.paragraph ?? 0) : 0))
            let offset = destination?.utf16Offset ?? (openAtEnd ? ((paragraphs.last ?? "") as NSString).length : (saved?.chapterID == target.id ? saved?.paragraphUTF16Offset ?? 0 : 0))
            readingPosition = ReaderProgressNavigation.bounded(ReaderTextPosition(paragraph: restoredParagraph, utf16Offset: offset), paragraphs: paragraphs)
            requestedPosition = nil
            openAtEnd = false
            visibleParagraph = readingPosition.paragraph > 0 || destination != nil ? readingPosition.paragraph : nil
            saveProgress()
            if shouldContinueSpeaking { shouldContinueSpeaking = false; speakCurrent() }
            guard target.id > 0, book.id > 0 else { return }
            // Opening a chapter intentionally starts a new reading position. Restoring a library,
            // downloading content, and scrolling never submit previously saved history.
            try await Task.sleep(for: .seconds(3))
            guard selected.id == target.id, content?.chapter.id == target.id, scenePhase == .active else { return }
            await synchronizeProgress(chapter: target, generation: generation)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, selected.id == target.id else { return }
            if case SFAPIError.subscriptionRequired = error { subscriptionRequired = true }
            self.error = error.localizedDescription; loading = false; shouldContinueSpeaking = false
        }
    }
    @MainActor private func synchronizeProgress(chapter: Chapter, generation: UUID) async {
        guard !Task.isCancelled, selected.id == chapter.id, content?.chapter.id == chapter.id else { return }
        do {
            let recorded = try await cloud.recordOpenedChapter(book: book, chapter: chapter, expectedGeneration: generation)
            guard !Task.isCancelled, selected.id == chapter.id else { return }
            if recorded {
                cloudProgressMessage = "本章已同步到云端。"
                cloudProgressFailed = false
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), selected.id == chapter.id,
                  await SFAPI.shared.sessionGeneration() == generation else { return }
            cloudProgressMessage = "本机位置已保存，云端暂未同步：\(error.localizedDescription)"
            cloudProgressFailed = true
        }
    }
    private func select(_ chapter: Chapter, at position: ReaderTextPosition? = nil) {
        if chapter.id == selected.id, let position, content != nil {
            jump(to: position)
            showChrome = false
            return
        }
        openAtEnd = false
        requestedPosition = position
        isScrubbing = false
        syncRetryTask?.cancel()
        saveProgress()
        if audio.isSpeech { audio.stop() }
        shouldContinueSpeaking = false
        selected = chapter
        visibleParagraph = nil
        showChrome = false
    }
    private func move(_ delta: Int, fromPageBoundary: Bool = false) {
        let next = chapterIndex + delta
        guard chapters.indices.contains(next) else { return }
        select(chapters[next])
        openAtEnd = fromPageBoundary && delta < 0
    }
    private func saveProgress() {
        guard content?.chapter.id == selected.id else { return }
        library.recordProgress(book: book, chapters: chapters, chapterID: selected.id, paragraph: readingPosition.paragraph, paragraphUTF16Offset: readingPosition.utf16Offset)
        readingSession.checkpoint(bookID: book.id, chapterID: selected.id)
    }
    private func closeReader() {
        saveProgress()
        readingSession.close()
        dismiss()
    }
    private func speakCurrent() {
        guard let content else { return }
        audio.speak(text: content.text, title: selected.title, bookTitle: book.title) {
            guard chapterIndex + 1 < chapters.count else { return }
            shouldContinueSpeaking = true
            saveProgress()
            selected = chapters[chapterIndex + 1]
            visibleParagraph = nil
        }
    }
}

private struct ReaderLayoutKey: Hashable {
    let chapterID: Int
    let textSize: CGSize
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let serif: Bool
}
