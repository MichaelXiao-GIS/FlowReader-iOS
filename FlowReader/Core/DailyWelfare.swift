import Foundation
import CoreFoundation

enum DailyWelfareState: Equatable, Sendable {
    case notAccepted, inProgress, claimable, claimed, unknown
}

struct DailyWelfareTask: Identifiable, Equatable, Sendable {
    var id: Int { taskID }
    let taskID: Int
    let recordID: Int?
    let name: String
    let description: String
    let rewardText: String?
    let statusText: String?
    let kind: String
    let taskType: Int?
    let requiredCount: Int?
    let completedCount: Int?
    let state: DailyWelfareState

    var isSignIn: Bool { kind == "signIn" || taskType == 26 || name == "每日签到" }
    var canAccept: Bool { !isSignIn && state == .notAccepted }
    var canClaimReward: Bool { !isSignIn && state == .claimable }
}

struct DailyWelfareSnapshot: Sendable {
    let tasks: [DailyWelfareTask]
    let generation: UUID
}

enum DailyWelfareAction: Equatable, Sendable {
    case acceptTask, claimReward
}

struct DailyWelfareReceipt: Equatable, Sendable {
    let taskID: Int
    let action: DailyWelfareAction
    /// Receipt time on this device; it is not a server task timestamp.
    let confirmedAt: Date
}

extension SFAPI {
    /// Reads the App account's task list. No task is accepted during refresh.
    func dailyWelfareTasks(expectedGeneration: UUID? = nil) async throws -> DailyWelfareSnapshot {
        let generation = sessionGeneration()
        if let expectedGeneration, generation != expectedGeneration { throw CancellationError() }
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        // /user/tasks may return an anonymous catalogue even when the cookie is expired.
        // Verify the App identity before treating those rows as this account's task state.
        _ = try await accountServiceProfile()
        guard sessionGeneration() == generation else { throw CancellationError() }
        var tasks: [DailyWelfareTask] = []
        var known: [Int: DailyWelfareTask] = [:]
        for page in 0..<100 {
            try Task.checkCancellation()
            guard sessionGeneration() == generation else { throw CancellationError() }
            var request = try appRequest(path: "/user/tasks",
                                         query: DailyWelfareProtocol.listQuery(page: page, deviceToken: installationIdentifier()),
                                         body: nil, includeSession: true, method: "GET")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
            let rows = try DailyWelfareProtocol.tasks(from: Self.parseAppResponse(data, response: response))
            let previousCount = tasks.count
            for task in rows {
                if let previous = known[task.id] {
                    // Conflicting rows or a server that ignores pagination must not enable an action.
                    guard previous == task else { throw SFAPIError.invalidResponse }
                } else {
                    known[task.id] = task
                    tasks.append(task)
                }
            }
            if rows.count < DailyWelfareProtocol.pageSize {
                return DailyWelfareSnapshot(tasks: tasks, generation: generation)
            }
            guard tasks.count > previousCount else { throw SFAPIError.invalidResponse }
        }
        throw SFAPIError.invalidResponse
    }

    /// Explicit user action. The preflight is refreshed; the POST is never retried automatically.
    func acceptDailyWelfareTask(taskID: Int, expectedGeneration: UUID) async throws -> DailyWelfareReceipt {
        try await mutateDailyWelfare(taskID: taskID, action: .acceptTask, generation: expectedGeneration)
    }

    /// Claims only a server-completed task. This does not complete reading, sharing, or purchases.
    func claimDailyWelfareReward(taskID: Int, expectedGeneration: UUID) async throws -> DailyWelfareReceipt {
        try await mutateDailyWelfare(taskID: taskID, action: .claimReward, generation: expectedGeneration)
    }

    private func mutateDailyWelfare(taskID: Int, action: DailyWelfareAction, generation: UUID) async throws -> DailyWelfareReceipt {
        guard taskID > 0 else { throw SFAPIError.invalidIdentifier }
        guard sessionGeneration() == generation else { throw CancellationError() }
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        let key = DailyWelfareMutationGate.Key(generation: generation, taskID: taskID)
        guard await DailyWelfareMutationGate.shared.begin(key) else {
            throw SFAPIError.server("这项任务正在处理中，请稍候。")
        }
        do {
            let latest = try await dailyWelfareTasks(expectedGeneration: generation)
            let plan = try DailyWelfareProtocol.mutation(taskID: taskID, action: action, snapshot: latest, expectedGeneration: generation)
            guard sessionGeneration() == generation else { throw CancellationError() }
            let request = try appRequest(path: plan.path, query: [:], body: [:], includeSession: true, method: plan.method)
            let (data, response) = try await send(request, acceptServerErrors: true, expectedGeneration: generation)
            try DailyWelfareProtocol.requireAcknowledgment(data, response: response, action: action)
            try Task.checkCancellation()
            guard sessionGeneration() == generation else { throw CancellationError() }
            let receipt = DailyWelfareReceipt(taskID: taskID, action: action, confirmedAt: Date())
            await DailyWelfareMutationGate.shared.end(key)
            guard sessionGeneration() == generation else { throw CancellationError() }
            return receipt
        } catch {
            await DailyWelfareMutationGate.shared.end(key)
            throw error
        }
    }
}

/// Protocol backed by the reference client's getTasks/claimTask/taskBonus and a live GET task list.
/// No reading-time or share-completion submission is part of this protocol.
enum DailyWelfareProtocol {
    static let pageSize = 20

    struct MutationRequest: Equatable, Sendable {
        let path: String
        let method: String
    }

    static func listQuery(page: Int, deviceToken: String) -> [String: String] {
        ["taskCategory": "1", "package": "com.sfacg", "deviceToken": deviceToken,
         "page": String(max(0, page)), "size": String(pageSize)]
    }

    static func tasks(from payload: Any) throws -> [DailyWelfareTask] {
        guard let rows = payload as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var seen = Set<Int>()
        return try rows.map { row in
            guard let id = nonnegativeInteger(row["taskId"]), id > 0, seen.insert(id).inserted,
                  let name = nonemptyString(row["name"]) else { throw SFAPIError.invalidResponse }
            let recordID = nonnegativeInteger(row["recordId"])
            let required = nonnegativeInteger(row["requireNum"])
            let completed = nonnegativeInteger(row["completeNum"])
            let taskType = nonnegativeInteger(row["taskType"])
            let kind = nonemptyString(row["type"]) ?? ""
            let rawStatus = nonnegativeInteger(row["status"])
            let state: DailyWelfareState
            // An incomplete or changed schema is displayable, but cannot authorize a mutation.
            if recordID != nil, let required, let completed, taskType != nil,
               isKnownKind(kind, taskType: taskType), nonnegativeInteger(row["category"]) == 1 {
                switch rawStatus {
                // A live accepted subscription task keeps status 0 while recordId is positive.
                case 0: state = recordID == 0 ? .notAccepted : .inProgress
                case 1: state = required > 0 && completed >= required ? .claimable : .inProgress
                case 2: state = .claimed
                default: state = .unknown
                }
            } else {
                state = .unknown
            }
            return DailyWelfareTask(taskID: id, recordID: recordID, name: name,
                                    description: nonemptyString(row["desc"]) ?? "",
                                    rewardText: nonemptyString(row["tips1"]), statusText: nonemptyString(row["tips2"]),
                                    kind: kind, taskType: taskType, requiredCount: required, completedCount: completed,
                                    state: state)
        }
    }

    static func mutation(taskID: Int, action: DailyWelfareAction, snapshot: DailyWelfareSnapshot,
                         expectedGeneration: UUID) throws -> MutationRequest {
        guard snapshot.generation == expectedGeneration else { throw CancellationError() }
        guard taskID > 0 else { throw SFAPIError.invalidIdentifier }
        guard let task = snapshot.tasks.first(where: { $0.taskID == taskID }) else {
            throw SFAPIError.server("任务列表已更新，请刷新后再试。")
        }
        guard !task.isSignIn else { throw SFAPIError.server("请使用每日签到入口完成签到。") }
        switch action {
        case .acceptTask:
            guard task.canAccept else { throw SFAPIError.server("这项任务的状态已变化，请刷新后查看。") }
            return MutationRequest(path: "/user/tasks/\(task.taskID)", method: "POST")
        case .claimReward:
            guard task.canClaimReward else { throw SFAPIError.server("服务器尚未确认任务已完成，请刷新任务进度后再领取。") }
            return MutationRequest(path: "/user/tasks/\(task.taskID)", method: "PUT")
        }
    }

    static func requireAcknowledgment(_ data: Data, response: HTTPURLResponse, action: DailyWelfareAction) throws {
        _ = try SFAPI.parseAppResponse(data, response: response)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = root["status"] as? [String: Any],
              nonnegativeInteger(status["httpCode"]) == (action == .acceptTask ? 201 : 200) else {
            throw SFAPIError.invalidResponse
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func isKnownKind(_ kind: String, taskType: Int?) -> Bool {
        switch (kind, taskType) {
        case ("share", 5), ("novelHome", 4), ("novelHome", 11), ("novelHome", 12),
             ("pay", 10), ("comicHome", 23), ("signIn", 26): return true
        default: return false
        }
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let integer = Int(exactly: number.doubleValue), integer >= 0 { return integer }
        if let text = value as? String, let integer = Int(text), integer >= 0 { return integer }
        return nil
    }
}

/// Guards a task across actor reentrancy while its fresh preflight request is in flight.
actor DailyWelfareMutationGate {
    struct Key: Hashable, Sendable {
        let generation: UUID
        let taskID: Int
    }
    static let shared = DailyWelfareMutationGate()
    private var pending = Set<Key>()
    func begin(_ key: Key) -> Bool { pending.insert(key).inserted }
    func end(_ key: Key) { pending.remove(key) }
}
