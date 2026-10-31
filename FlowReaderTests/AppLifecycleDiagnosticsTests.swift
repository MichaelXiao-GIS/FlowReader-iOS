import XCTest
@testable import FlowReader

@MainActor
final class AppLifecycleDiagnosticsTests: XCTestCase {
    func testHomeReturnKeepsLaunchIdentityAndCountsOnlyBackgroundReturns() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let diagnostics = AppLifecycleDiagnostics(defaults: defaults, launchID: id, startedAt: Date(timeIntervalSince1970: 100), exitsOnSuspend: false)
        diagnostics.recordRootMount()
        diagnostics.recordPhase(.active, at: Date(timeIntervalSince1970: 101))
        diagnostics.recordPhase(.inactive, at: Date(timeIntervalSince1970: 102))
        diagnostics.recordPhase(.active, at: Date(timeIntervalSince1970: 103))
        XCTAssertEqual(diagnostics.snapshot.sameProcessReturnCount, 0, "An alert or interruption is not a trip to the background")
        diagnostics.recordPhase(.inactive, at: Date(timeIntervalSince1970: 104))
        diagnostics.recordPhase(.background, at: Date(timeIntervalSince1970: 105))
        diagnostics.recordPhase(.inactive, at: Date(timeIntervalSince1970: 106))
        diagnostics.recordPhase(.active, at: Date(timeIntervalSince1970: 107))
        diagnostics.recordPhase(.active, at: Date(timeIntervalSince1970: 108))
        diagnostics.recordRootMount()
        XCTAssertEqual(diagnostics.snapshot.launchID, id)
        XCTAssertEqual(diagnostics.snapshot.launchCount, 1)
        XCTAssertEqual(diagnostics.snapshot.sameProcessReturnCount, 1)
        XCTAssertEqual(diagnostics.snapshot.rootMountCount, 2)
        XCTAssertEqual(diagnostics.snapshot.lastForegroundAt, Date(timeIntervalSince1970: 107))
        XCTAssertEqual(diagnostics.snapshot.lastBackgroundAt, Date(timeIntervalSince1970: 105))
    }

    func testProcessRestartIncrementsLaunchCountWithoutClaimingWarmReturn() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let oldID = UUID()
        let original = AppLifecycleDiagnostics(defaults: defaults, launchID: oldID, startedAt: Date(timeIntervalSince1970: 100), exitsOnSuspend: false)
        original.recordPhase(.background, at: Date(timeIntervalSince1970: 105))
        original.recordRootMount()
        let newID = UUID()
        let restarted = AppLifecycleDiagnostics(defaults: defaults, launchID: newID, startedAt: Date(timeIntervalSince1970: 200), exitsOnSuspend: false)
        restarted.recordPhase(.active, at: Date(timeIntervalSince1970: 201))
        XCTAssertNotEqual(restarted.snapshot.launchID, oldID)
        XCTAssertEqual(restarted.snapshot.launchID, newID)
        XCTAssertEqual(restarted.snapshot.launchCount, 2)
        XCTAssertEqual(restarted.snapshot.sameProcessReturnCount, 0)
        XCTAssertEqual(restarted.snapshot.rootMountCount, 0)
        XCTAssertEqual(restarted.snapshot.startedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(restarted.snapshot.lastBackgroundAt, Date(timeIntervalSince1970: 105))
    }

    func testRecreatingStateInSameProcessDoesNotIncrementLaunchCounter() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let first = AppLifecycleDiagnostics(defaults: defaults, launchID: id, startedAt: Date(timeIntervalSince1970: 100), exitsOnSuspend: false)
        first.recordRootMount()
        let recreated = AppLifecycleDiagnostics(defaults: defaults, launchID: id, startedAt: Date(timeIntervalSince1970: 200), exitsOnSuspend: false)
        XCTAssertEqual(recreated.snapshot.launchCount, 1)
        XCTAssertEqual(recreated.snapshot.rootMountCount, 1)
        XCTAssertEqual(recreated.snapshot.startedAt, Date(timeIntervalSince1970: 100))
    }

    func testInstalledExitSettingIsReportedWithoutReadingUnrelatedUserData() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unrelated-private-test-value", forKey: "unrelated.account")
        let diagnostics = AppLifecycleDiagnostics(defaults: defaults, launchID: UUID(), startedAt: Date(timeIntervalSince1970: 100), exitsOnSuspend: true)
        XCTAssertTrue(diagnostics.snapshot.exitsOnSuspend)
        XCTAssertTrue(diagnostics.report.contains("ExitsOnSuspend：true"))
        XCTAssertFalse(diagnostics.report.contains("unrelated-private-test-value"))
        let data = try XCTUnwrap(defaults.data(forKey: "diagnostics.appLifecycle"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected: Set<String> = ["launchID", "startedAt", "launchCount", "rootMountCount", "sameProcessReturnCount", "awaitingBackgroundReturn", "exitsOnSuspend"]
        XCTAssertEqual(Set(object.keys), expected, "Only lifecycle facts belong in the persisted record")
    }

    func testMalformedDiagnosticRecordStartsFresh() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: "diagnostics.appLifecycle")
        let diagnostics = AppLifecycleDiagnostics(defaults: defaults, launchID: UUID(), startedAt: Date(), exitsOnSuspend: false)
        XCTAssertEqual(diagnostics.snapshot.launchCount, 1)
        XCTAssertEqual(diagnostics.snapshot.rootMountCount, 0)
    }

    private func isolatedDefaults() throws -> (String, UserDefaults) {
        let name = "FlowReader.LifecycleTests.\(UUID().uuidString)"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }
}
