import Foundation
import AVFoundation
import MediaPlayer
import Observation

@MainActor @Observable
final class AudioController: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = AudioController()
    private(set) var title = ""
    private(set) var subtitle = ""
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var isSpeech = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var hasPlayable: Bool { player != nil || speaker.isPaused || speaker.isSpeaking }
    private(set) var activeIndex = 0
    private(set) var tracks: [AudioTrack] = []
    var errorMessage: String?
    var rate: Float = 1 {
        didSet { if !isSpeech, isPlaying { player?.rate = rate }; updateNowPlaying() }
    }
    var sleepMinutes = 0 {
        didSet { configureSleep() }
    }
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var activeBook: Book?
    @ObservationIgnored private var speechCompletion: (() -> Void)?
    @ObservationIgnored private var generation = UUID()

    override private init() {
        super.init()
        speaker.delegate = self
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(seconds: 15) }; return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(seconds: -15) }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }

    func play(book: Book, tracks: [AudioTrack], index: Int) {
        guard tracks.indices.contains(index) else { return }
        stop()
        activeBook = book
        self.tracks = tracks
        activeIndex = index
        title = tracks[index].title
        subtitle = book.title
        isLoading = true
        let token = generation
        loadTask = Task { [self] in
            do {
                try activateAudio()
                let asset: AVURLAsset
                if let local = AudioLibrary.shared.localURL(track: tracks[index]) {
                    asset = AVURLAsset(url: local)
                } else {
                    let request = try await SFAPI.shared.audioRequest(track: tracks[index])
                    guard let url = request.url else { throw URLError(.badURL) }
                    asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]])
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = newPlayer
                timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor in
                        guard let self else { return }
                        self.currentTime = time.seconds.isFinite ? time.seconds : 0
                        let total = self.player?.currentItem?.duration.seconds ?? 0
                        self.duration = total.isFinite ? total : 0
                        self.updateNowPlaying()
                    }
                }
                itemObservation = newPlayer.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if item.status == .failed {
                            self.errorMessage = item.error?.localizedDescription ?? "音频暂时无法播放。"
                            self.isPlaying = false
                            self.isLoading = false
                        } else if item.status == .readyToPlay { self.isLoading = false }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: newPlayer.currentItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.next() }
                }
                newPlayer.playImmediately(atRate: rate)
                isPlaying = true
                updateNowPlaying()
            } catch is CancellationError { }
            catch { guard generation == token else { return }; errorMessage = error.localizedDescription; isLoading = false; isPlaying = false }
        }
    }

    func speak(text: String, title: String, bookTitle: String, completion: (() -> Void)? = nil) {
        stop()
        self.title = title
        subtitle = bookTitle
        isSpeech = true
        speechCompletion = completion
        do {
            try activateAudio()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * min(max(rate, 0.7), 1.5)
            speaker.speak(utterance)
            isPlaying = true
            updateNowPlaying()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggle() { isPlaying ? pause() : resume() }
    func pause() {
        if isSpeech { speaker.pauseSpeaking(at: .immediate) } else { player?.pause() }
        isPlaying = false
        updateNowPlaying()
    }
    func resume() {
        do { try activateAudio() } catch { errorMessage = error.localizedDescription; return }
        if isSpeech {
            guard speaker.isPaused else { return }
            speaker.continueSpeaking()
        } else {
            guard player != nil else { return }
            player?.playImmediately(atRate: rate)
        }
        isPlaying = true
        updateNowPlaying()
    }
    func stop() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        speechCompletion = nil
        speaker.stopSpeaking(at: .immediate)
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        itemObservation?.invalidate()
        itemObservation = nil
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        isLoading = false
        isSpeech = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func next() {
        guard let book = activeBook, tracks.indices.contains(activeIndex + 1), !isSpeech else { pause(); return }
        play(book: book, tracks: tracks, index: activeIndex + 1)
    }
    func previous() {
        guard let book = activeBook, tracks.indices.contains(activeIndex - 1), !isSpeech else { return }
        play(book: book, tracks: tracks, index: activeIndex - 1)
    }
    func skip(seconds: Double) { seek(to: currentTime + seconds) }
    func seek(to seconds: Double) {
        guard !isSpeech else { return }
        player?.seek(to: CMTime(seconds: min(max(seconds, 0), max(duration, 0)), preferredTimescale: 600))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isSpeech else { return }
            self.isPlaying = false
            self.updateNowPlaying()
            let completion = self.speechCompletion
            self.speechCompletion = nil
            completion?()
        }
    }
    private func activateAudio() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try AVAudioSession.sharedInstance().setActive(true)
    }
    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: subtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0
        ]
    }
    private func configureSleep() {
        sleepTask?.cancel()
        guard sleepMinutes > 0 else { return }
        sleepTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(sleepMinutes * 60)); pause(); sleepMinutes = 0 }
            catch { }
        }
    }
}
