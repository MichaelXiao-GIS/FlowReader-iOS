import SwiftUI

/// Floating controls never participate in the text column's layout.
struct ReaderChrome<More: View>: View {
    let layout: ReaderViewportLayout
    let paper: Color
    let bookmarked: Bool
    let contentAvailable: Bool
    let speaking: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let progressDescription: String
    let progressAccessibilityLabel: String
    let canSeek: Bool
    @Binding var progress: Double
    let onScrubbing: (Bool) -> Void
    let onBookmark: () -> Void
    let onBookmarks: () -> Void
    let onClose: () -> Void
    let onContents: () -> Void
    let onSettings: () -> Void
    let onSpeak: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    @ViewBuilder let more: () -> More

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            ZStack(alignment: .topLeading) {
                Button(action: onBookmark) {
                    Image(systemName: bookmarked ? "bookmark.fill" : "bookmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                .tint(bookmarked ? FlowTheme.accent : .primary)
                .disabled(!contentAvailable)
                .accessibilityLabel(bookmarked ? "移除此处书签" : "添加此处书签")
                .accessibilityIdentifier("reader-bookmark")
                .contextMenu { Button("查看本书书签", systemImage: "bookmark") { onBookmarks() } }
                .position(layout.bookmarkFrame.center)

                Button(action: onClose) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("关闭阅读").accessibilityIdentifier("reader-close")
                    .position(layout.closeFrame.center)

                VStack(spacing: 0) {
                    tool("章节目录", symbol: "list.bullet", id: "reader-contents", action: onContents)
                    tool(speaking ? "暂停朗读" : "朗读本章", symbol: speaking ? "pause.fill" : "speaker.wave.2",
                         id: "reader-read-aloud", action: onSpeak).disabled(!contentAvailable)
                    tool("阅读设置", symbol: "textformat.size", id: "reader-settings", action: onSettings)
                    more().frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).padding(4)
                .glassEffect(.regular.interactive(), in: .capsule)
                .position(layout.toolsFrame.center)

                if contentAvailable {
                    HStack(spacing: 10) {
                        Button(action: onPrevious) {
                            Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                            .disabled(!canGoBack).accessibilityLabel("上一章").accessibilityIdentifier("reader-previous-chapter")
                        VStack(spacing: 3) {
                            Text(progressDescription).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .accessibilityIdentifier("reader-progress-label")
                            Slider(value: $progress, in: 0...1, onEditingChanged: onScrubbing)
                                .disabled(!canSeek)
                                .accessibilityLabel(progressAccessibilityLabel)
                                .accessibilityValue(progressDescription)
                                .accessibilityIdentifier("reader-progress")
                        }
                        Button(action: onNext) {
                            Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                            .disabled(!canGoForward).accessibilityLabel("下一章").accessibilityIdentifier("reader-next-chapter")
                    }
                    .buttonStyle(.plain).padding(.horizontal, 12)
                    .frame(width: layout.progressFrame.width, height: layout.progressFrame.height)
                    .background {
                        LinearGradient(stops: [.init(color: paper.opacity(0), location: 0),
                                               .init(color: paper, location: 0.24),
                                               .init(color: paper, location: 1)], startPoint: .top, endPoint: .bottom)
                            .padding(.horizontal, -12).padding(.top, -20).padding(.bottom, -12)
                            .allowsHitTesting(false)
                    }
                    .position(layout.progressFrame.center)
                }
            }
        }
        .tint(FlowTheme.accent)
    }

    private func tool(_ label: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .accessibilityLabel(label).accessibilityIdentifier(id)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
