import SwiftUI
import UniformTypeIdentifiers

struct LocalLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importing = false
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var showingShare = false
    @State private var deleting: LocalBook?
    @State private var filter = ""
    @State private var path = NavigationPath()
    @Namespace private var covers
    @State private var savedAudio = AudioLibrary.shared
    private var filtered: [LocalBook] {
        library.books.filter { filter.isEmpty || $0.book.title.localizedCaseInsensitiveContains(filter) || $0.book.author.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.books.isEmpty && savedAudio.entries.isEmpty {
                    ContentUnavailableView {
                        Label("为故事留一个位置", systemImage: "books.vertical")
                    } description: { Text("下载喜欢的章节，或导入自己的文本，随时离线阅读。") } actions: {
                        Button("导入文本", systemImage: "plus") { importing = true }.buttonStyle(.glassProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            if let recent = library.books.filter({ $0.progress != nil }).max(by: { ($0.progress?.updatedAt ?? .distantPast) < ($1.progress?.updatedAt ?? .distantPast) }), filter.isEmpty {
                                continueReading(recent)
                            }
                            HStack {
                                Text("我的藏书").font(.title2.bold())
                                Spacer()
                                Text("\(filtered.count) 本").font(.subheadline).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 24)], alignment: .leading, spacing: 30) {
                                ForEach(filtered) { local in
                                    NavigationLink(value: local.book) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            BookCover(book: local.book, width: 140, height: 200)
                                                .matchedTransitionSource(id: local.id, in: covers)
                                            Text(local.book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                            Text(local.downloadedIDs.isEmpty ? "最近阅读" : "已下载 \(local.downloadedIDs.count) 章")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        ForEach(ExportFormat.allCases) { format in
                                            Button("导出 \(format.rawValue)", systemImage: "square.and.arrow.up") { export(local, as: format) }.disabled(local.downloadedIDs.isEmpty)
                                        }
                                        Button("移除藏书", systemImage: "trash", role: .destructive) { deleting = local }
                                    }
                                }
                            }
                            if filtered.isEmpty && !filter.isEmpty { ContentUnavailableView.search(text: filter) }
                            if !savedAudio.entries.isEmpty {
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
                        }.padding(24).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
            }
            .background(FlowTheme.paper)
            .accessibilityIdentifier("library-content")
            .navigationTitle("书库")
            .navigationDestination(for: Book.self) { book in
                if reduceMotion { BookDetailView(book: book) }
                else { BookDetailView(book: book).navigationTransition(.zoom(sourceID: book.id, in: covers)) }
            }
            .readingDestinations()
            .searchable(text: $filter, prompt: "搜索书库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入文本", systemImage: "doc.badge.plus") { importing = true }
                        Button("阅读原创示例", systemImage: "book") { library.seedDemoIfNeeded() }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("添加书籍")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .utf8PlainText, .text]) { result in
                do { _ = try library.importText(url: result.get()) } catch { self.error = error.localizedDescription }
            }
            .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
            .confirmationDialog("移除《\(deleting?.book.title ?? "")》及其下载的章节？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("移除藏书", role: .destructive) { if let deleting { library.remove(bookID: deleting.id) }; deleting = nil }
            }
            .sheet(isPresented: $showingShare) { if let exportURL { ActivitySheet(items: [exportURL]) } }
            .onChange(of: savedAudio.errorMessage) { _, message in if let message { error = message; savedAudio.errorMessage = nil } }
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
                            Label("继续阅读", systemImage: "book.pages").font(.subheadline.weight(.medium)).foregroundStyle(FlowTheme.accent).padding(.top, 7)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(20).background(FlowTheme.card, in: .rect(cornerRadius: 22))
                }.buttonStyle(.plain)
            }
        }
    }

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
