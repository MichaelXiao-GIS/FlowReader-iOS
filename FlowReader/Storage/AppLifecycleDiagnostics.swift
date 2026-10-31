import Foundation
import Observation

private enum LifecycleProcess {
    static let id = UUID()
    static let startedAt = Date()
}

enum AppLifecyclePhase: String, Codable { case active, inactive, background }

/// A small local record for troubleshooting suspension. Contains no reading or account data.
@MainActor @Observable
final class AppLifecycleDiagnostics {
    struct Snapshot: Codable, Equatable {
        var launchID: UUID
        var startedAt: Date
        var launchCount: Int
        var rootMountCount: Int
        var sameProcessReturnCount: Int
        var lastForegroundAt: Date?
        var lastBackgroundAt: Date?
        var phase: AppLifecyclePhase?
        var awaitingBackgroundReturn: Bool
        var exitsOnSuspend: Bool
    }

    private(set) var snapshot: Snapshot
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "diagnostics.appLifecycle"

    init(defaults: UserDefaults = .standard, launchID: UUID = LifecycleProcess.id,
         startedAt: Date = LifecycleProcess.startedAt,
         exitsOnSuspend: Bool = Bundle.main.object(forInfoDictionaryKey: "UIApplicationExitsOnSuspend") as? Bool ?? false) {
        self.defaults = defaults
        let previous = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        if var previous, previous.launchID == launchID {
            previous.exitsOnSuspend = exitsOnSuspend
            snapshot = previous
        } else {
            snapshot = Snapshot(launchID: launchID, startedAt: startedAt,
                                launchCount: min(previous?.launchCount ?? 0, 1_000_000) + 1,
                                rootMountCount: 0, sameProcessReturnCount: 0,
                                lastForegroundAt: previous?.lastForegroundAt,
                                lastBackgroundAt: previous?.lastBackgroundAt,
                                phase: nil, awaitingBackgroundReturn: false, exitsOnSuspend: exitsOnSuspend)
        }
        persist()
    }

    func recordRootMount() {
        snapshot.rootMountCount += 1
        persist()
    }

    func recordPhase(_ phase: AppLifecyclePhase, at date: Date = Date()) {
        guard snapshot.phase != phase else { return }
        snapshot.phase = phase
        if phase == .background {
            snapshot.lastBackgroundAt = date
            snapshot.awaitingBackgroundReturn = true
        } else if phase == .active {
            snapshot.lastForegroundAt = date
            if snapshot.awaitingBackgroundReturn {
                snapshot.sameProcessReturnCount += 1
                snapshot.awaitingBackgroundReturn = false
            }
        }
        persist()
    }

    var explanation: String {
        if snapshot.sameProcessReturnCount > 0 {
            return "本次进程已从后台正常返回 \(snapshot.sameProcessReturnCount) 次。"
        }
        return "若切回后启动标识改变，说明应用进程重新启动；标识不变则是同一进程返回。"
    }

    var report: String {
        let formatter = ISO8601DateFormatter()
        func date(_ value: Date?) -> String { value.map { formatter.string(from: $0) } ?? "暂无记录" }
        return """
        菠萝阅运行诊断（仅本机）
        启动标识：\(snapshot.launchID.uuidString)
        当前启动：\(date(snapshot.startedAt))
        累计启动次数：\(snapshot.launchCount)
        同进程后台返回次数：\(snapshot.sameProcessReturnCount)
        最近前台：\(date(snapshot.lastForegroundAt))
        最近后台：\(date(snapshot.lastBackgroundAt))
        Root 挂载次数：\(snapshot.rootMountCount)
        安装包 ExitsOnSuspend：\(snapshot.exitsOnSuspend ? "true" : "false")
        \(explanation)
        不包含账号、书籍、正文、设备标识或登录凭据；不会自动上传。
        """
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.storageKey) }
    }
}
