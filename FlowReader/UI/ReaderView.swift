import SwiftUI
import UIKit

struct ReaderView: View {
    let book: Book
    let chapters: [Chapter]
    @Environment(LibraryStore.self) private var library
    @Environment(CloudLibraryStore.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Chapter
    @State private var content: ChapterContent?
    @State private var loading = false
    @State private var loadRevision = 0
    @State private var syncRetryTask: Task<Void, Never>?
    @State private var error: String?
    @State private var showContents = false
    @State private var showSettings = false
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
    private var paragraphs: [String] { content?.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? [] }

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
        .onDisappear { syncRetryTask?.cancel(); saveProgress() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveProgress() } }
        .onChange(of: readingPosition) { _, _ in if turnMode == "curl" { saveProgress() } }
        .onChange(of: turnMode) { _, mode in
            if mode == "scroll" { visibleParagraph = readingPosition.paragraph }
        }
    }

    private var readingPage: some View {
        ZStack {
            background.ignoresSafeArea()
            if loading {
                ProgressView("正在打开章节…")
            } else if let error {
                ContentUnavailableView {
                    Label("暂时无法打开", systemImage: "book.closed")
                } description: { Text(error) } actions: {
                    Button("重试") { loadRevision += 1 }.buttonStyle(.borderedProminent)
                    if chapterIsRemote {
                        Link("在官方页面查看", destination: selected.officialURL).buttonStyle(.glass)
                    }
                }
            } else if content != nil {
                if turnMode == "curl" { pagedContent }
                else { scrollingContent }
            }
            if showChrome || loading || error != nil { readerChrome.transition(.opacity) }
        }
        .foregroundStyle(foreground)
        .accessibilityAction(named: showChrome ? "隐藏阅读工具" : "显示阅读工具", toggleChrome)
        .accessibilityAction(.escape) { dismiss() }
    }

    private var scrollingContent: some View {
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
            .frame(maxWidth: 680)
            .padding(.horizontal, sizeClass == .regular ? 36 : 26)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 48)
        }
        .id(selected.id)
        .accessibilityIdentifier("reader-content")
        .scrollIndicators(.hidden)
        .scrollPosition(id: $visibleParagraph, anchor: .top)
        .onChange(of: visibleParagraph) { _, value in
            guard turnMode == "scroll", let value else { return }
            if value != readingPosition.paragraph {
                readingPosition = ReaderTextPosition(paragraph: value, utf16Offset: 0)
            }
            saveProgress()
        }
        .onTapGesture(perform: toggleChrome)
    }

    private var pagedContent: some View {
        GeometryReader { safeGeometry in
            pagedViewport(safeArea: safeGeometry.safeAreaInsets)
                .ignoresSafeArea()
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

    private var readerChrome: some View {
        VStack {
            HStack(alignment: .top, spacing: 12) {
                Button { saveProgress(); dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel("关闭阅读").accessibilityIdentifier("reader-close")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button { showContents = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                        .accessibilityLabel("章节目录").accessibilityIdentifier("reader-contents")
                    Button { showSettings = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                        .accessibilityLabel("阅读设置").accessibilityIdentifier("reader-settings")
                    moreMenu.frame(width: 44, height: 44)
                }.buttonStyle(.plain).padding(4).glassEffect(.regular, in: .capsule)
            }
            Spacer()
            HStack(spacing: 20) {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(chapterIndex == 0).accessibilityLabel("上一章")
                VStack(spacing: 3) {
                    Text(selected.title).font(.caption.weight(.medium)).lineLimit(1)
                    Text("第 \(chapterIndex + 1) 章 · 共 \(chapters.count) 章").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(maxWidth: 320)
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(chapterIndex + 1 >= chapters.count).accessibilityLabel("下一章")
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule).frame(maxWidth: 460)
        }
        .tint(FlowTheme.accent)
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 12)
    }

    private var moreMenu: some View {
        Menu {
            if cloudProgressFailed { Label("云端暂未同步，本机位置已保存", systemImage: "exclamationmark.icloud") }
            Button {
                if audio.isSpeech && audio.title == selected.title { audio.toggle() } else { speakCurrent() }
            } label: { Label(audio.isPlaying && audio.isSpeech ? "暂停朗读" : "朗读本章", systemImage: "speaker.wave.2") }
            Button { library.download(book: book, chapters: [selected]) } label: { Label("下载本章", systemImage: "arrow.down.circle") }
            if audio.isSpeech { Button("停止朗读", systemImage: "stop.circle") { audio.stop() } }
            Button("隐藏阅读工具", systemImage: "eye.slash", action: toggleChrome)
        } label: { Image(systemName: cloudProgressFailed ? "exclamationmark.icloud" : "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel(cloudProgressFailed ? "云端进度未同步，更多阅读选项" : "更多阅读选项")
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
        loading = true; error = nil; content = nil; pagination = nil
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
            loading = false
            let restoredParagraph = openAtEnd ? max(0, paragraphs.count - 1) : (saved?.chapterID == target.id ? (saved?.paragraph ?? 0) : 0)
            let offset = openAtEnd ? ((paragraphs.last ?? "") as NSString).length : (saved?.chapterID == target.id ? saved?.paragraphUTF16Offset ?? 0 : 0)
            let validParagraph = min(max(0, restoredParagraph), max(0, paragraphs.count - 1))
            let validOffset = min(max(0, offset), paragraphs.indices.contains(validParagraph) ? (paragraphs[validParagraph] as NSString).length : 0)
            readingPosition = ReaderTextPosition(paragraph: validParagraph, utf16Offset: validOffset)
            openAtEnd = false
            visibleParagraph = validParagraph > 0 ? validParagraph : nil
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
    private func select(_ chapter: Chapter) {
        openAtEnd = false
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
