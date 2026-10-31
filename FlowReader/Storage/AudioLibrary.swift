import Foundation
import Observation

struct SavedAudio: Identifiable, Codable, Hashable {
    var id: String { "\(track.albumID)-\(track.id)" }
    var book: Book
    var track: AudioTrack
    var fileName: String
}

@MainActor @Observable
final class AudioLibrary {
    static let shared = AudioLibrary()
    private(set) var entries: [SavedAudio] = []
    private(set) var downloadingID: String?
    var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlowAudio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let index = folder.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                entries = try JSONDecoder().decode([SavedAudio].self, from: Data(contentsOf: index))
            }
        } catch { errorMessage = "有声书库无法读取：\(error.localizedDescription)" }
    }

    func localURL(track: AudioTrack) -> URL? {
        guard let saved = entries.first(where: { $0.track.id == track.id && $0.track.albumID == track.albumID }) else { return nil }
        let url = folder.appendingPathComponent(saved.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(book: Book, track: AudioTrack) {
        guard downloadingID == nil, localURL(track: track) == nil else { return }
        downloadingID = "\(track.albumID)-\(track.id)"
        task = Task { [self] in
            defer { downloadingID = nil; task = nil }
            do {
                let request = try await SFAPI.shared.audioRequest(track: track)
                let (temporary, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                let mime = response.mimeType?.lowercased() ?? ""
                guard mime.hasPrefix("audio/") || mime == "application/octet-stream" else { throw SFAPIError.server("返回的文件不是可播放音频。") }
                let suffix = mime == "audio/mp4" || mime == "audio/x-m4a" ? "m4a" : "mp3"
                let fileName = "\(track.albumID)-\(track.id).\(suffix)"
                let destination = folder.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                entries.removeAll { $0.track.id == track.id && $0.track.albumID == track.albumID }
                entries.append(SavedAudio(book: book, track: track, fileName: fileName))
                try persist()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }

    func cancelDownload() { task?.cancel() }

    func remove(_ entry: SavedAudio) {
        do {
            let url = folder.appendingPathComponent(entry.fileName)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            entries.removeAll { $0.id == entry.id }
            try persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func export(_ entry: SavedAudio) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlowExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(entry.fileName)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: folder.appendingPathComponent(entry.fileName), to: destination)
        return destination
    }

    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
