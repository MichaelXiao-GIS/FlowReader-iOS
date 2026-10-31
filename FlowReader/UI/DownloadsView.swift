import SwiftUI

struct DownloadsView: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        NavigationStack {
            Group {
                if library.jobs.isEmpty {
                    ContentUnavailableView("把故事带在身边", systemImage: "arrow.down.circle", description: Text("在作品目录中下载章节，离线时也能继续阅读。"))
                } else {
                    List {
                        ForEach(library.jobs) { job in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top, spacing: 16) {
                                    BookCover(book: job.book, width: 52, height: 74)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(job.book.title).font(.headline).lineLimit(2)
                                        Text(status(job)).font(.subheadline).foregroundStyle(.secondary)
                                        Text("\(job.completedIDs.count) / \(job.chapters.count) 章").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if job.status == .downloading || job.status == .queued {
                                        Button { library.pause(jobID: job.id) } label: { Image(systemName: "pause.fill") }.buttonStyle(.glass).accessibilityLabel("暂停下载")
                                    } else if job.status != .complete {
                                        Button { library.resume(jobID: job.id) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass).accessibilityLabel("继续下载")
                                    } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(FlowTheme.accent).accessibilityLabel("下载完成") }
                                }
                                ProgressView(value: job.fraction).tint(FlowTheme.accent)
                                if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }.padding(.vertical, 12).listRowBackground(FlowTheme.card)
                                .swipeActions { Button("移除任务", role: .destructive) { library.cancel(jobID: job.id) } }
                        }
                    }.scrollContentBackground(.hidden)
                }
            }.background(FlowTheme.paper).accessibilityIdentifier("downloads-content").navigationTitle("下载")
        }
    }
    private func status(_ job: DownloadJob) -> String {
        switch job.status {
        case .queued: "等待下载"
        case .downloading: "正在下载"
        case .paused: "已暂停"
        case .failed: "下载已停止"
        case .complete: "已保存到书库"
        }
    }
}
