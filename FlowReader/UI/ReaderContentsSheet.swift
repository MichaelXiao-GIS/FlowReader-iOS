import SwiftUI

struct ReaderContentsSection: Identifiable, Equatable {
    struct ID: Hashable {
        let volumeID: Int
        let sequence: Int
    }

    let id: ID
    let volumeID: Int
    let title: String
    var chapters: [Chapter]
}

enum ReaderContentsOrdering {
    /// Keep the catalog's own sequence. Neither chapter IDs nor repeated volume titles imply order.
    static func sections(chapters: [Chapter], descending: Bool) -> [ReaderContentsSection] {
        var result: [ReaderContentsSection] = []
        for chapter in chapters {
            if result.last?.volumeID == chapter.volumeID {
                result[result.count - 1].chapters.append(chapter)
            } else {
                result.append(ReaderContentsSection(
                    id: .init(volumeID: chapter.volumeID, sequence: result.count),
                    volumeID: chapter.volumeID,
                    title: chapter.volumeTitle,
                    chapters: [chapter]
                ))
            }
        }
        guard descending else { return result }
        return result.reversed().map { section in
            var reversed = section
            reversed.chapters.reverse()
            return reversed
        }
    }

    static func initialTarget(chapters: [Chapter], currentChapterID: Int) -> Int? {
        chapters.contains(where: { $0.id == currentChapterID }) ? currentChapterID : chapters.first?.id
    }

    static func boundaryTarget(chapters: [Chapter], descending: Bool) -> Int? {
        descending ? chapters.last?.id : chapters.first?.id
    }
}

struct ReaderContentsSheet: View {
    let chapters: [Chapter]
    let currentChapterID: Int
    let downloadedIDs: Set<Int>
    let onSelect: (Chapter) -> Void

    @Environment(CloudLibraryStore.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reader.contentsDescending") private var descending = false
    @State private var permissions = ReaderContentsPermissions()
    @State private var permissionRefresh = 0
    @State private var positionedInitially = false
    @State private var scrollRequest: ScrollRequest?

    private struct PermissionTaskID: Hashable {
        let bookID: Int?
        let generation: UUID?
        let refresh: Int
    }

    private struct ScrollRequest {
        let id = UUID()
        let chapterID: Int
        let anchor: UnitPoint
        let animated: Bool
    }

    private var sections: [ReaderContentsSection] {
        ReaderContentsOrdering.sections(chapters: chapters, descending: descending)
    }

    private var hasCurrentChapter: Bool { chapters.contains(where: { $0.id == currentChapterID }) }

    private var orderSelection: Binding<Bool> {
        Binding(get: { descending }, set: { value in
            guard value != descending else { return }
            descending = value
            if let target = ReaderContentsOrdering.boundaryTarget(chapters: chapters, descending: value) {
                scrollRequest = ScrollRequest(chapterID: target, anchor: .top, animated: false)
            }
        })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("目录排序", selection: orderSelection) {
                    Text("正序").tag(false)
                    Text("倒序").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityIdentifier("reader-contents-order")

                if let notice = permissions.notice {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("重试") { permissionRefresh += 1 }
                            .font(.footnote)
                            .disabled(permissions.loading)
                            .accessibilityIdentifier("reader-contents-permission-retry")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("reader-contents-permission-notice")
                }

                ScrollViewReader { proxy in
                    List {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.chapters) { chapter in
                                    chapterRow(chapter)
                                        .id(chapter.id)
                                }
                            } header: {
                                Text(section.title.isEmpty ? "正文" : section.title)
                                    .accessibilityIdentifier("reader-volume-\(section.id.volumeID)-\(section.id.sequence)")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .accessibilityIdentifier("reader-contents-list")
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        guard !positionedInitially, size.width > 0, size.height > 0 else { return }
                        positionedInitially = true
                        if let target = ReaderContentsOrdering.initialTarget(chapters: chapters, currentChapterID: currentChapterID) {
                            scrollRequest = ScrollRequest(chapterID: target, anchor: .center, animated: false)
                        }
                    }
                    .task(id: scrollRequest?.id) {
                        guard let request = scrollRequest else { return }
                        // Apply after the List has laid out, including a newly reversed section order.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(request.animated && !reduceMotion ? .easeInOut(duration: 0.25) : nil) {
                            proxy.scrollTo(request.chapterID, anchor: request.anchor)
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("当前章节", systemImage: "scope") {
                        scrollRequest = ScrollRequest(chapterID: currentChapterID, anchor: .center, animated: true)
                    }
                    .disabled(!hasCurrentChapter)
                    .accessibilityLabel("定位当前章节")
                    .accessibilityIdentifier("reader-contents-locate")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("reader-contents-done")
                }
            }
        }
        .task(id: PermissionTaskID(bookID: ReaderContentsPermissions.remoteBookID(chapters: chapters),
                                   generation: cloud.sessionGeneration, refresh: permissionRefresh)) {
            await permissions.load(chapters: chapters, cloud: cloud, forceRefresh: permissionRefresh > 0)
        }
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let isCurrent = chapter.id == currentChapterID
        return Button { onSelect(chapter) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title)
                        .foregroundStyle(isCurrent ? FlowTheme.accent : .primary)
                    if isCurrent {
                        Text("正在阅读")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FlowTheme.accent)
                            .accessibilityIdentifier("reader-current-chapter")
                    }
                }
                Spacer(minLength: 4)
                if downloadedIDs.contains(chapter.id) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .accessibilityLabel("已下载")
                }
                ChapterPurchaseBadge(chapter: chapter)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("reader-chapter-\(chapter.id)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .listRowBackground(isCurrent ? FlowTheme.accent.opacity(0.07) : Color.clear)
    }
}
