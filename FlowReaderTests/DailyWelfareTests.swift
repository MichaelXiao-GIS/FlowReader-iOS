import XCTest
@testable import FlowReader

final class DailyWelfareTests: XCTestCase {
    private func row(status: Any = 0, completed: Any = 0, required: Any = 3600, recordID: Any = 0) -> [String: Any] {
        ["taskId": 5, "recordId": recordID, "name": "每日阅读60分钟", "desc": "轻小说／漫画／对话",
         "tips1": "服务器提供的奖励说明", "tips2": "任务状态", "type": "novelHome", "taskType": 4,
         "category": 1, "requireNum": required, "completeNum": completed, "status": status]
    }

    private func task(_ row: [String: Any]) throws -> DailyWelfareTask {
        try XCTUnwrap(DailyWelfareProtocol.tasks(from: [row]).first)
    }

    func testIncompleteReadingNeverEnablesRewardAndCountsStayInServerUnits() throws {
        let pending = try task(row(status: 0))
        XCTAssertEqual(pending.state, .notAccepted)
        XCTAssertTrue(pending.canAccept)
        XCTAssertFalse(pending.canClaimReward)
        let incomplete = try task(row(status: 1, completed: 3599))
        XCTAssertEqual(incomplete.completedCount, 3599)
        XCTAssertEqual(incomplete.requiredCount, 3600)
        XCTAssertEqual(incomplete.state, .inProgress)
        XCTAssertFalse(incomplete.canAccept)
        XCTAssertFalse(incomplete.canClaimReward)
        XCTAssertTrue(try task(row(status: 1, completed: 3600)).canClaimReward)
        XCTAssertTrue(try task(row(status: 1, completed: 7200)).canClaimReward)
        let claimed = try task(row(status: 2, completed: 3600))
        XCTAssertEqual(claimed.state, .claimed)
        XCTAssertFalse(claimed.canClaimReward)
        let accepted = try task(row(status: 0, recordID: 9001))
        XCTAssertEqual(accepted.state, .inProgress)
        XCTAssertFalse(accepted.canAccept, "Accepted tasks may retain status 0 with a positive recordId")
        XCTAssertFalse(accepted.canClaimReward)
    }

    func testUnknownOrMalformedTaskStateCannotAuthorizeAnAction() throws {
        var malformedRows = [row(status: 3), row(status: true), row(completed: false),
                             row(required: -1), row(completed: 1.5)]
        for key in ["status", "recordId", "category", "type", "taskType", "requireNum", "completeNum"] {
            var value = row()
            value.removeValue(forKey: key)
            malformedRows.append(value)
        }
        var unknownType = row()
        unknownType["taskType"] = 999
        malformedRows.append(unknownType)
        for value in malformedRows {
            let value = try task(value)
            XCTAssertEqual(value.state, .unknown)
            XCTAssertFalse(value.canAccept)
            XCTAssertFalse(value.canClaimReward)
        }
        XCTAssertFalse(try task(row(status: 1, completed: 0, required: 0)).canClaimReward)
        XCTAssertThrowsError(try DailyWelfareProtocol.tasks(from: ["unexpected": []]))
        XCTAssertThrowsError(try DailyWelfareProtocol.tasks(from: [row(), row()]))
        var invalidIdentity = row()
        invalidIdentity["taskId"] = true
        XCTAssertThrowsError(try DailyWelfareProtocol.tasks(from: [invalidIdentity]))
    }

    func testSignInAlwaysUsesTheExistingSignInFlow() throws {
        var signIn = row(status: 0, required: 0)
        signIn["type"] = "signIn"
        signIn["taskType"] = 26
        signIn["name"] = "每日签到"
        let value = try task(signIn)
        XCTAssertTrue(value.isSignIn)
        XCTAssertFalse(value.canAccept)
        XCTAssertFalse(value.canClaimReward)
        let generation = UUID()
        let snapshot = DailyWelfareSnapshot(tasks: [value], generation: generation)
        XCTAssertThrowsError(try DailyWelfareProtocol.mutation(taskID: value.id, action: .acceptTask,
                                                              snapshot: snapshot, expectedGeneration: generation))
    }

    func testMutationUsesTaskIdentifierAndRejectsChangedStateOrAccount() async throws {
        let generation = UUID()
        let value = try task(row())
        let fresh = DailyWelfareSnapshot(tasks: [value], generation: generation)
        let plan = try DailyWelfareProtocol.mutation(taskID: value.taskID, action: .acceptTask,
                                                     snapshot: fresh, expectedGeneration: generation)
        XCTAssertEqual(plan.path, "/user/tasks/5")
        XCTAssertEqual(plan.method, "POST")
        XCTAssertNotEqual(plan.path, "/user/tasks/9001")
        let api = SFAPI(loadPersistedSessions: false)
        let request = try await api.appRequest(path: plan.path, query: [:], body: [:], includeSession: true, method: plan.method)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], [:])
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertThrowsError(try DailyWelfareProtocol.mutation(taskID: value.id, action: .claimReward,
                                                              snapshot: fresh, expectedGeneration: generation))
        XCTAssertThrowsError(try DailyWelfareProtocol.mutation(taskID: value.id, action: .acceptTask,
                                                              snapshot: fresh, expectedGeneration: UUID())) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let completed = DailyWelfareSnapshot(tasks: [try task(row(status: 1, completed: 3600, recordID: 9001))], generation: generation)
        XCTAssertThrowsError(try DailyWelfareProtocol.mutation(taskID: value.id, action: .acceptTask,
                                                              snapshot: completed, expectedGeneration: generation))
        let reward = try DailyWelfareProtocol.mutation(taskID: value.id, action: .claimReward,
                                                      snapshot: completed, expectedGeneration: generation)
        XCTAssertEqual(reward.path, "/user/tasks/5")
        XCTAssertEqual(reward.method, "PUT")
        XCTAssertNotEqual(reward.path, "/user/tasks/9001")
    }

    func testOnlyAnExplicitSuccessfulEnvelopeConfirmsAMutation() throws {
        let url = try XCTUnwrap(URL(string: "https://api.sfacg.com/user/tasks/5"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        for code in [200, 201] {
            let envelope = try data(["status": ["httpCode": code, "errorCode": 200], "data": NSNull()])
            XCTAssertNoThrow(try DailyWelfareProtocol.requireAcknowledgment(envelope, response: response,
                                                                           action: code == 201 ? .acceptTask : .claimReward))
            XCTAssertThrowsError(try DailyWelfareProtocol.requireAcknowledgment(envelope, response: response,
                                                                               action: code == 201 ? .claimReward : .acceptTask))
        }
        let bad: [[String: Any]] = [[:], ["success": true], ["status": [:]],
                                    ["status": ["httpCode": true]],
                                    ["status": ["httpCode": 200, "errorCode": 500]],
                                    ["status": ["httpCode": 401, "errorCode": 507]]]
        for envelope in bad {
            XCTAssertThrowsError(try DailyWelfareProtocol.requireAcknowledgment(data(envelope), response: response, action: .claimReward))
        }
        let failedTransport = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try DailyWelfareProtocol.requireAcknowledgment(data(["status": ["httpCode": 200]]),
                                                                           response: failedTransport, action: .claimReward))
    }

    func testMissingSessionStopsReadsAndWritesBeforeNetwork() async {
        let api = SFAPI(loadPersistedSessions: false)
        let generation = await api.sessionGeneration()
        do {
            _ = try await api.dailyWelfareTasks(expectedGeneration: generation)
            XCTFail("An App identity is required")
        } catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected error: \(error)") } }
        do {
            _ = try await api.acceptDailyWelfareTask(taskID: 5, expectedGeneration: generation)
            XCTFail("Cannot accept a task without an App identity")
        } catch { guard case SFAPIError.loginRequired = error else { return XCTFail("Unexpected error: \(error)") } }
        do {
            _ = try await api.claimDailyWelfareReward(taskID: 5, expectedGeneration: UUID())
            XCTFail("A changed identity must cancel the action")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testConcurrentTaskMutationIsRejectedAndGateReleases() async {
        let gate = DailyWelfareMutationGate()
        let key = DailyWelfareMutationGate.Key(generation: UUID(), taskID: 5)
        let first = await gate.begin(key)
        let second = await gate.begin(key)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let otherAccount = await gate.begin(.init(generation: UUID(), taskID: 5))
        XCTAssertTrue(otherAccount)
        await gate.end(key)
        let later = await gate.begin(key)
        XCTAssertTrue(later)
    }

    func testTaskPaginationPreservesTheRequiredServiceParameters() {
        let query = DailyWelfareProtocol.listQuery(page: 2, deviceToken: "installation-placeholder")
        XCTAssertEqual(query["page"], "2")
        XCTAssertEqual(query["size"], "20")
        XCTAssertEqual(query["taskCategory"], "1")
        XCTAssertEqual(query["package"], "com.sfacg")
        XCTAssertEqual(query["deviceToken"], "installation-placeholder")
        XCTAssertNil(query["userId"])
    }
}
