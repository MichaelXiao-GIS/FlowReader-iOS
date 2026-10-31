import SwiftUI

struct ReaderView: View {
    let book: Book
    let chapters: [Chapter]
    @Environment(LibraryStore.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Chapter
    @State private var content: ChapterContent?
    @State private var loading = false
    @State private var error: String?
    @State private var showContents = false
    @State private var showSettings = false
    @State private var showChrome = true
    @State private var visibleParagraph: Int?
    @State private var shouldContinueSpeaking = false
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0
    @AppStorage("reader.fontSize") private var fontSize = 21.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 10.0
    @AppStorage("reader.theme") private var theme = "paper"
    @AppStorage("reader.serif") private var serif = true
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
        case "night": Color(red: 0.09, green: 0.10, blue: 0.11)
        case "white": colorScheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color.white
        default: colorScheme == .dark ? Color(red: 0.12, green: 0.11, blue: 0.10) : Color(red: 0.97, green: 0.95, blue: 0.90)
        }
    }
    private var foreground: Color { theme == "night" || colorScheme == .dark ? Color(white: 0.88) : Color(red: 0.18, green: 0.16, blue: 0.13) }
    private var chapterIndex: Int { chapters.firstIndex(where: { $0.id == selected.id }) ?? 0 }
    private var paragraphs: [String] { content?.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? [] }

    var body: some View {
        readingPage
        .background(background)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(showChrome ? .visible : .hidden, for: .navigationBar)
        .task(id: selected.id) { await load() }
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
        .onDisappear { saveProgress() }
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
                    Button("重试") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            } else if content != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(book.title).font(.subheadline).foregroundStyle(foreground.opacity(0.55))
                            Text(selected.title).font(.system(.largeTitle, design: .serif, weight: .semibold)).foregroundStyle(foreground).accessibilityIdentifier("reader-chapter-title")
                            Rectangle().fill(foreground.opacity(0.12)).frame(width: 48, height: 1).padding(.top, 8)
                        }.padding(.top, 30).padding(.bottom, 14)
                        LazyVStack(alignment: .leading, spacing: lineSpacing + 6) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                                Text("　　" + paragraph)
                                    .font(.system(size: fontSize * textScale, weight: .regular, design: serif ? .serif : .default))
                                    .lineSpacing(lineSpacing)
                                    .foregroundStyle(foreground)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("reader-paragraph-\(index)")
                                    .id(index)
                            }
                        }.scrollTargetLayout()
                        VStack(spacing: 16) {
                            Image(systemName: "leaf").font(.title3).foregroundStyle(foreground.opacity(0.35))
                            if chapterIndex + 1 < chapters.count {
                                Button { move(1) } label: { Label("下一章", systemImage: "arrow.right") }
                                    .buttonStyle(.glass)
                            } else { Text("已读至最后一章").font(.footnote).foregroundStyle(foreground.opacity(0.5)) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 38)
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, sizeClass == .regular ? 36 : 26)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                }
                .id(selected.id)
                .accessibilityIdentifier("reader-content")
                .scrollPosition(id: $visibleParagraph, anchor: .top)
                .onChange(of: visibleParagraph) { _, _ in saveProgress() }
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showChrome.toggle() }
                }
                .accessibilityAction(named: showChrome ? "隐藏阅读工具" : "显示阅读工具") { showChrome.toggle() }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showContents.toggle() } label: { Image(systemName: "list.bullet") }.accessibilityLabel("章节目录").accessibilityIdentifier("reader-contents")
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }.accessibilityLabel("阅读设置").accessibilityIdentifier("reader-settings")
                Menu {
                    Button {
                        if audio.isSpeech && audio.title == selected.title { audio.toggle() } else { speakCurrent() }
                    } label: { Label(audio.isPlaying && audio.isSpeech ? "暂停朗读" : "朗读本章", systemImage: "speaker.wave.2") }
                    Button { library.download(book: book, chapters: [selected]) } label: { Label("下载本章", systemImage: "arrow.down.circle") }
                    if audio.isSpeech { Button("停止朗读", systemImage: "stop.circle") { audio.stop() } }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多阅读选项")
            }
            if showChrome {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(chapterIndex == 0).accessibilityLabel("上一章")
                    Spacer()
                    Text("\(chapterIndex + 1) / \(chapters.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityLabel("第 \(chapterIndex + 1) 章，共 \(chapters.count) 章")
                    Spacer()
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(chapterIndex + 1 >= chapters.count).accessibilityLabel("下一章")
                }
            }
        }
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
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                                } else if chapter.isVIP { Image(systemName: "lock").foregroundStyle(.secondary).font(.caption) }
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
            }
            .navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false }.accessibilityIdentifier("reader-settings-done") } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    @MainActor private func load() async {
        loading = true; error = nil; content = nil
        let target = selected
        let saved = library.localBook(id: book.id)?.progress
        do {
            let loaded = try await library.content(chapter: target)
            try Task.checkCancellation()
            guard selected.id == target.id else { return }
            content = loaded
            loading = false
            let restoredParagraph = saved?.chapterID == target.id ? (saved?.paragraph ?? 0) : 0
            visibleParagraph = restoredParagraph > 0 ? restoredParagraph : nil
            library.recordProgress(book: book, chapters: chapters, chapterID: target.id, paragraph: visibleParagraph ?? 0)
            if shouldContinueSpeaking { shouldContinueSpeaking = false; speakCurrent() }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; loading = false; shouldContinueSpeaking = false }
    }
    private func select(_ chapter: Chapter) {
        saveProgress()
        if audio.isSpeech { audio.stop() }
        shouldContinueSpeaking = false
        selected = chapter
        visibleParagraph = nil
        showChrome = true
    }
    private func move(_ delta: Int) {
        let next = chapterIndex + delta
        guard chapters.indices.contains(next) else { return }
        select(chapters[next])
    }
    private func saveProgress() {
        guard content?.chapter.id == selected.id else { return }
        library.recordProgress(book: book, chapters: chapters, chapterID: selected.id, paragraph: visibleParagraph ?? 0)
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
