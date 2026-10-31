import SwiftUI

struct AudioPlayerView: View {
    let book: Book
    let tracks: [AudioTrack]
    var initialIndex = 0
    @State private var audio = AudioController.shared
    @State private var savedAudio = AudioLibrary.shared
    @State private var showTracks = false
    @State private var seeking = false
    @State private var seekTime = 0.0

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                BookCover(book: book, width: 200, height: 282).padding(.top, 28)
                VStack(spacing: 8) {
                    Text(audio.subtitle == book.title ? audio.title : (tracks.first?.title ?? book.title))
                        .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    Text(book.title).font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { seeking ? seekTime : min(audio.currentTime, max(audio.duration, 1)) }, set: { seekTime = $0 }), in: 0...max(audio.duration, 1)) { editing in
                        seeking = editing
                        if !editing { audio.seek(to: seekTime) }
                    }.disabled(audio.duration <= 0).accessibilityLabel("播放进度")
                    HStack {
                        Text(clock(audio.currentTime))
                        Spacer()
                        Text(clock(audio.duration))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 32) {
                    Button { audio.previous() } label: { Image(systemName: "backward.end.fill") }.disabled(audio.activeIndex == 0).accessibilityLabel("上一集")
                    Button { audio.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("后退15秒")
                    Button {
                        if audio.subtitle != book.title || !audio.hasPlayable { audio.play(book: book, tracks: tracks, index: initialIndex) }
                        else { audio.toggle() }
                    } label: {
                        Group {
                            if audio.isLoading { ProgressView() }
                            else { Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title) }
                        }.frame(width: 64, height: 64)
                    }.buttonStyle(.glassProminent).accessibilityLabel(audio.isPlaying ? "暂停" : "播放")
                    Button { audio.skip(seconds: 15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("快进15秒")
                    Button { audio.next() } label: { Image(systemName: "forward.end.fill") }.disabled(audio.activeIndex + 1 >= tracks.count).accessibilityLabel("下一集")
                }.font(.title3).buttonStyle(.plain)
                HStack {
                    Menu {
                        Picker("播放速度", selection: $audio.rate) {
                            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { value in Text("\(value.formatted())×").tag(value) }
                        }
                    } label: { Text("\(audio.rate.formatted())×").font(.subheadline.monospacedDigit()) }.buttonStyle(.glass)
                    Spacer()
                    Menu {
                        Picker("睡眠定时", selection: $audio.sleepMinutes) {
                            Text("关闭").tag(0)
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("60 分钟").tag(60)
                        }
                    } label: { Label(audio.sleepMinutes == 0 ? "定时" : "\(audio.sleepMinutes) 分钟", systemImage: "moon") }.buttonStyle(.glass)
                    Spacer()
                    Button { showTracks = true } label: { Image(systemName: "list.bullet") }.buttonStyle(.glass).accessibilityLabel("有声目录")
                }
            }.padding(.horizontal, 30).padding(.bottom, 40).frame(maxWidth: 500).frame(maxWidth: .infinity)
        }
        .background(FlowTheme.paper)
        .navigationTitle("正在聆听").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if savedAudio.downloadingID != nil {
                    Button { savedAudio.cancelDownload() } label: { ProgressView() }.accessibilityLabel("取消音频下载")
                } else if tracks.indices.contains(audio.activeIndex) {
                    let track = tracks[audio.activeIndex]
                    Button { savedAudio.download(book: book, track: track) } label: {
                        Image(systemName: savedAudio.localURL(track: track) == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                    }.disabled(savedAudio.localURL(track: track) != nil).accessibilityLabel(savedAudio.localURL(track: track) == nil ? "下载本集" : "本集已下载")
                }
            }
        }
        .onChange(of: savedAudio.errorMessage) { _, message in if let message { audio.errorMessage = message; savedAudio.errorMessage = nil } }
        .task {
            if audio.subtitle != book.title { audio.play(book: book, tracks: tracks, index: initialIndex) }
        }
        .alert("无法播放", isPresented: Binding(get: { audio.errorMessage != nil }, set: { if !$0 { audio.errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(audio.errorMessage ?? "") }
        .sheet(isPresented: $showTracks) {
            NavigationStack {
                List(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button { audio.play(book: book, tracks: tracks, index: index); showTracks = false } label: {
                        HStack {
                            Text(track.title).foregroundStyle(.primary)
                            Spacer()
                            if index == audio.activeIndex { Image(systemName: "waveform").foregroundStyle(FlowTheme.accent) }
                            else if track.isVIP { Image(systemName: "lock").foregroundStyle(.secondary) }
                        }.padding(.vertical, 7)
                    }
                }.navigationTitle("有声目录").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showTracks = false } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
    private func clock(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        return "\(Int(value) / 60):\(String(format: "%02d", Int(value) % 60))"
    }
}
