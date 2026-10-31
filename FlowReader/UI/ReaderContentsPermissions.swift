import Foundation
import Observation

/// A restored reader can open its directory without ever visiting the book-detail screen.
/// Keep that directory's account permissions current without changing its navigation or progress.
@MainActor @Observable
final class ReaderContentsPermissions {
    struct Client {
        var generation: @MainActor () async -> UUID
        var hasAppSession: @MainActor () async -> Bool
        var fetch: @MainActor (Int, Bool, @escaping @Sendable (ChapterPurchaseSnapshot) async -> Void) async throws -> ChapterPurchaseSnapshot

        static let live = Client(
            generation: { await SFAPI.shared.sessionGeneration() },
            hasAppSession: { await SFAPI.shared.hasAppSession() },
            fetch: { bookID, forceRefresh, progress in
                try await SFAPI.shared.chapterPurchaseStates(bookID: bookID, forceRefresh: forceRefresh, onCurrentPermissions: progress)
            }
        )
    }

    private(set) var loading = false
    private(set) var notice: String?
    @ObservationIgnored private let client: Client
    @ObservationIgnored private var requestID = UUID()

    init(client: Client = .live) { self.client = client }

    static func remoteBookID(chapters: [Chapter]) -> Int? {
        guard let bookID = chapters.first?.bookID, bookID > 0,
              chapters.allSatisfy({ $0.bookID == bookID && $0.id > 0 }),
              chapters.contains(where: \.isVIP) else { return nil }
        return bookID
    }

    func load(chapters: [Chapter], cloud: CloudLibraryStore, forceRefresh: Bool = false) async {
        let request = UUID()
        requestID = request
        notice = nil
        guard let bookID = Self.remoteBookID(chapters: chapters) else {
            loading = false
            return
        }
        loading = true
        defer { if requestID == request { loading = false } }
        await cloud.checkSessionGeneration()
        let generation = await client.generation()
        guard requestID == request, !Task.isCancelled, cloud.sessionGeneration == generation else { return }
        guard await client.hasAppSession() else {
            guard await isCurrent(request, generation: generation, cloud: cloud) else { return }
            notice = "连接账号服务后，可确认章节购买状态。"
            return
        }
        do {
            guard await isCurrent(request, generation: generation, cloud: cloud) else { return }
            let final = try await client.fetch(bookID, forceRefresh) { [weak self, weak cloud] snapshot in
                guard let self, let cloud else { return }
                await self.accept(snapshot, chapters: chapters, bookID: bookID, request: request, generation: generation, cloud: cloud)
            }
            await accept(final, chapters: chapters, bookID: bookID, request: request, generation: generation, cloud: cloud)
        } catch {
            guard !AccountShelfState.isCancellation(error),
                  await isCurrent(request, generation: generation, cloud: cloud) else { return }
            // The shared permission store remains intact on a transient refresh failure.
            notice = error.localizedDescription
        }
    }

    private func accept(_ snapshot: ChapterPurchaseSnapshot, chapters: [Chapter], bookID: Int, request: UUID,
                        generation: UUID, cloud: CloudLibraryStore) async {
        guard snapshot.generation == generation,
              await isCurrent(request, generation: generation, cloud: cloud) else { return }
        var states = snapshot.states
        for chapter in chapters {
            let existing = cloud.purchaseState(for: chapter)
            let incoming = states[chapter.id]
            if existing == .purchased && incoming == .available {
                // A preliminary zero-price quote does not erase a proven purchase.
                // Explicit current denials still take precedence if rights have changed.
                states[chapter.id] = .purchased
            } else if (incoming == nil || incoming == .unknown) && existing != .unknown {
                states[chapter.id] = existing
            }
        }
        let retained = ChapterPurchaseSnapshot(states: states, generation: snapshot.generation,
                                               ownershipRecordsComplete: snapshot.ownershipRecordsComplete, notice: snapshot.notice)
        cloud.applyPurchaseSnapshot(retained, bookID: bookID)
        notice = snapshot.notice
    }

    private func isCurrent(_ request: UUID, generation: UUID, cloud: CloudLibraryStore) async -> Bool {
        let actual = await client.generation()
        return !Task.isCancelled && requestID == request && actual == generation && cloud.sessionGeneration == generation
    }
}
