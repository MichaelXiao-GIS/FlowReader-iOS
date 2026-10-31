import XCTest
@testable import FlowReader

@MainActor
final class ReaderContentsPermissionTests: XCTestCase {
    private var chapters: [Chapter] {
        [Chapter(id: 10, bookID: 42, volumeID: 1, volumeTitle: "测试卷", title: "原创测试章", order: 0, isVIP: true),
         Chapter(id: 11, bookID: 42, volumeID: 1, volumeTitle: "测试卷", title: "原创测试章二", order: 1, isVIP: true)]
    }

    func testRestoredReaderLoadsPaidBadgesWithoutBookDetailAndAcceptsIncrementalSnapshots() async {
        let fixture = ContentsPermissionFixture()
        let cloud = CloudLibraryStore(client: fixture.cloudClient)
        let values = chapters
        fixture.fetch = { _, _, progress in
            await progress(ChapterPurchaseSnapshot(states: [10: .purchased, 11: .available], generation: fixture.generation))
            XCTAssertEqual(cloud.purchaseState(for: values[0]), .purchased)
            XCTAssertEqual(cloud.purchaseState(for: values[1]), .available)
            return ChapterPurchaseSnapshot(states: [10: .purchased, 11: .purchased], generation: fixture.generation,
                                           ownershipRecordsComplete: true)
        }
        let loader = ReaderContentsPermissions(client: fixture.client)
        XCTAssertNil(cloud.sessionGeneration)
        await loader.load(chapters: values, cloud: cloud)
        XCTAssertEqual(fixture.fetchCount, 1)
        XCTAssertEqual(cloud.purchaseState(for: values[1]), .purchased)
        XCTAssertNil(loader.notice)
        XCTAssertFalse(loader.loading)
    }

    func testOfflineFreeAndMixedBookCatalogsNeverCallAnyClient() async {
        let fixture = ContentsPermissionFixture(), cloud = CloudLibraryStore(client: fixture.cloudClient)
        let loader = ReaderContentsPermissions(client: fixture.client)
        var local = chapters; local[0].bookID = -42; local[1].bookID = -42
        var free = chapters; free[0].isVIP = false; free[1].isVIP = false
        var mixed = chapters; mixed[1].bookID = 43
        for value in [[], local, free, mixed] { await loader.load(chapters: value, cloud: cloud) }
        XCTAssertEqual(fixture.generationCount, 0)
        XCTAssertEqual(fixture.hasSessionCount, 0)
        XCTAssertEqual(fixture.fetchCount, 0)
        XCTAssertNil(loader.notice)
    }

    func testMissingAppSessionDoesNotFetchAndKeepsExistingBadges() async {
        let fixture = ContentsPermissionFixture(), cloud = CloudLibraryStore(client: fixture.cloudClient)
        await cloud.checkSessionGeneration()
        cloud.applyPurchaseSnapshot(ChapterPurchaseSnapshot(states: [10: .purchased], generation: fixture.generation), bookID: 42)
        fixture.hasSession = false
        let loader = ReaderContentsPermissions(client: fixture.client)
        await loader.load(chapters: chapters, cloud: cloud)
        XCTAssertEqual(fixture.fetchCount, 0)
        XCTAssertEqual(cloud.purchaseState(for: chapters[0]), .purchased)
        XCTAssertNotNil(loader.notice)
    }

    func testFailureAfterPreliminaryQuotePreservesPaidEvidenceAndShowsNonblockingNotice() async {
        let fixture = ContentsPermissionFixture(), cloud = CloudLibraryStore(client: fixture.cloudClient)
        await cloud.checkSessionGeneration()
        cloud.applyPurchaseSnapshot(ChapterPurchaseSnapshot(states: [10: .purchased, 11: .available], generation: fixture.generation), bookID: 42)
        fixture.fetch = { _, _, progress in
            await progress(ChapterPurchaseSnapshot(states: [10: .available, 11: .unknown], generation: fixture.generation))
            throw URLError(.networkConnectionLost)
        }
        let loader = ReaderContentsPermissions(client: fixture.client)
        await loader.load(chapters: chapters, cloud: cloud)
        XCTAssertEqual(cloud.purchaseState(for: chapters[0]), .purchased)
        XCTAssertEqual(cloud.purchaseState(for: chapters[1]), .available)
        XCTAssertNotNil(loader.notice)
        XCTAssertFalse(loader.loading)
    }

    func testExplicitCurrentDenialStillOverridesHistoricalPurchasedBadge() async {
        let fixture = ContentsPermissionFixture(), cloud = CloudLibraryStore(client: fixture.cloudClient)
        await cloud.checkSessionGeneration()
        cloud.applyPurchaseSnapshot(ChapterPurchaseSnapshot(states: [10: .purchased], generation: fixture.generation), bookID: 42)
        fixture.fetch = { _, _, _ in ChapterPurchaseSnapshot(states: [10: .requiresPurchase], generation: fixture.generation) }
        await ReaderContentsPermissions(client: fixture.client).load(chapters: chapters, cloud: cloud)
        XCTAssertEqual(cloud.purchaseState(for: chapters[0]), .requiresPurchase)
    }

    func testCancellationIsSilentAndManualRetryAloneForcesCacheRefresh() async {
        let fixture = ContentsPermissionFixture(), cloud = CloudLibraryStore(client: fixture.cloudClient)
        fixture.fetch = { _, _, _ in throw URLError(.cancelled) }
        let loader = ReaderContentsPermissions(client: fixture.client)
        await loader.load(chapters: chapters, cloud: cloud)
        XCTAssertNil(loader.notice)
        XCTAssertEqual(fixture.forced, [false])
        fixture.fetch = { _, _, _ in ChapterPurchaseSnapshot(states: [10: .purchased], generation: fixture.generation) }
        await loader.load(chapters: chapters, cloud: cloud, forceRefresh: true)
        XCTAssertEqual(fixture.forced, [false, true])
        XCTAssertEqual(cloud.purchaseState(for: chapters[0]), .purchased)
    }

    func testAccountChangeRejectsBothLateProgressAndFinalResponse() async {
        let fixture = ContentsPermissionFixture(), cloud = CloudLibraryStore(client: fixture.cloudClient)
        let original = fixture.generation
        fixture.fetch = { _, _, progress in
            fixture.generation = UUID()
            await cloud.checkSessionGeneration()
            let stale = ChapterPurchaseSnapshot(states: [10: .purchased], generation: original)
            await progress(stale)
            return stale
        }
        let loader = ReaderContentsPermissions(client: fixture.client)
        await loader.load(chapters: chapters, cloud: cloud)
        XCTAssertEqual(cloud.purchaseState(for: chapters[0]), .unknown)
        XCTAssertNil(loader.notice)
    }

    func testOlderRequestCannotOverwriteACompletedNewRefresh() async {
        let fixture = ContentsPermissionFixture(), cloud = CloudLibraryStore(client: fixture.cloudClient)
        let latch = ContentsPermissionLatch()
        fixture.fetch = { _, force, progress in
            if !force {
                await latch.wait()
                let stale = ChapterPurchaseSnapshot(states: [10: .requiresPurchase], generation: fixture.generation)
                await progress(stale)
                return stale
            }
            return ChapterPurchaseSnapshot(states: [10: .purchased], generation: fixture.generation)
        }
        let loader = ReaderContentsPermissions(client: fixture.client), values = chapters
        let old = Task { await loader.load(chapters: values, cloud: cloud) }
        await latch.waitUntilEntered()
        await loader.load(chapters: values, cloud: cloud, forceRefresh: true)
        await latch.release()
        await old.value
        XCTAssertEqual(cloud.purchaseState(for: chapters[0]), .purchased)
        XCTAssertFalse(loader.loading)
    }
}

@MainActor
private final class ContentsPermissionFixture {
    var generation = UUID()
    var hasSession = true
    var generationCount = 0
    var hasSessionCount = 0
    var fetchCount = 0
    var forced: [Bool] = []
    var fetch: ((Int, Bool, @escaping @Sendable (ChapterPurchaseSnapshot) async -> Void) async throws -> ChapterPurchaseSnapshot)?

    var client: ReaderContentsPermissions.Client {
        .init(generation: { self.generationCount += 1; return self.generation },
              hasAppSession: { self.hasSessionCount += 1; return self.hasSession },
              fetch: { bookID, force, progress in
                  self.fetchCount += 1; self.forced.append(force)
                  if let fetch = self.fetch { return try await fetch(bookID, force, progress) }
                  return ChapterPurchaseSnapshot(states: [:], generation: self.generation)
              })
    }
    var cloudClient: CloudLibraryStore.Client {
        .init(generation: { self.generationCount += 1; return self.generation },
              hasAppSession: { self.hasSession }, hasWebSession: { false },
              profile: { throw SFAPIError.loginRequired },
              bookshelf: { BookshelfSyncResult(books: [], failedSectionCount: 0) })
    }
}

private actor ContentsPermissionLatch {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { waiting?.resume(); waiting = nil }
}
