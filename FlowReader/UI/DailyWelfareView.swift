import SwiftUI

struct DailyWelfareView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var state: WelfareViewState
    @State private var showLogin = false

    var body: some View {
        List {
            Section {
                if let account = state.account {
                    LabeledContent("当前账号", value: account.name)
                } else {
                    Text(state.loading ? "正在确认账号身份…" : "请连接账号服务后查看福利任务。")
                        .foregroundStyle(.secondary)
                }
                if state.needsLogin {
                    Button("登录菠萝包") { showLogin = true }
                        .accessibilityIdentifier("welfare-connect")
                }
            }
            if let message = state.errorMessage {
                Section {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    Button("刷新状态") { Task { await state.refresh(.daily) } }.disabled(state.busy)
                }
            }
            Section {
                if state.loading && !state.hasLoadedDaily { ProgressView("正在读取福利任务") }
                if state.hasLoadedDaily && state.tasks.isEmpty {
                    Text("当前没有可展示的日常任务。").foregroundStyle(.secondary)
                }
                ForEach(state.tasks) { task in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(task.name).font(.headline)
                        if !task.description.isEmpty { Text(task.description).font(.subheadline).foregroundStyle(.secondary) }
                        if let reward = task.rewardText { Label(reward, systemImage: "gift").font(.subheadline).foregroundStyle(FlowTheme.accent) }
                        if let completed = task.completedCount, let required = task.requiredCount, required > 0 {
                            HStack {
                                Text(task.taskType == 4 ? "阅读进度" : "已完成").foregroundStyle(.secondary)
                                Spacer()
                                Text(task.taskType == 4 ? "\(completed / 60) / \(max(1, required / 60 + (required % 60 == 0 ? 0 : 1))) 分钟" : "\(completed) / \(required)").monospacedDigit()
                            }.font(.caption)
                            ProgressView(value: Double(min(completed, required)), total: Double(required))
                                .accessibilityLabel(task.taskType == 4 ? "阅读进度，\(completed / 60) 分钟，共 \(max(1, required / 60 + (required % 60 == 0 ? 0 : 1))) 分钟" : "已完成 \(completed)，共 \(required)")
                        }
                        Button {
                            Task { await state.perform(task) }
                        } label: {
                            HStack {
                                Text(state.taskButtonTitle(task))
                                Spacer()
                                if state.actionKey == "task-\(task.id)" { ProgressView() }
                            }
                        }
                        .disabled(!state.canAct(on: task))
                        .accessibilityIdentifier("welfare-task-\(task.id)")
                    }.padding(.vertical, 8)
                }
            } header: { Text("日常任务") }
            footer: {
                Text("当前本应用的阅读时长暂不计入福利任务，进度以服务器返回为准。分享等条件请在菠萝包官方完成后返回刷新。每日签到请使用上一级的签到入口。")
            }
        }
        .scrollContentBackground(.hidden).background(FlowTheme.paper)
        .navigationTitle("日常福利").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await state.refresh(.daily) } }.disabled(state.busy)
            }
        }
        .task { await state.refresh(.daily) }
        .refreshable { await state.refresh(.daily) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await state.refresh(.daily) } } }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await state.refresh(.daily) } }) { AccountServiceLoginView() }
        .onDisappear { state.invalidateRead() }
    }
}

/// Shared by the two destinations so an acknowledged action survives navigating back.
@MainActor @Observable
final class WelfareViewState {
    enum SectionKind { case daily, gifts }
    struct Client {
        var generation: @MainActor () async -> UUID
        var profile: @MainActor () async throws -> AccountProfile
        var daily: @MainActor (UUID) async throws -> DailyWelfareSnapshot
        var gifts: @MainActor (UUID) async throws -> MemberGiftsSnapshot
        var acceptTask: @MainActor (Int, UUID) async throws -> DailyWelfareReceipt
        var claimReward: @MainActor (Int, UUID) async throws -> DailyWelfareReceipt
        var claimGift: @MainActor (MemberGift, UUID) async throws -> MemberGiftReceipt

        static let live = Client(
            generation: { await SFAPI.shared.sessionGeneration() },
            profile: { try await SFAPI.shared.accountServiceProfile() },
            daily: { try await SFAPI.shared.dailyWelfareTasks(expectedGeneration: $0) },
            gifts: { try await SFAPI.shared.memberGifts(expectedGeneration: $0) },
            acceptTask: { try await SFAPI.shared.acceptDailyWelfareTask(taskID: $0, expectedGeneration: $1) },
            claimReward: { try await SFAPI.shared.claimDailyWelfareReward(taskID: $0, expectedGeneration: $1) },
            claimGift: { try await SFAPI.shared.claimMemberGift($0, expectedGeneration: $1) }
        )
    }
    private enum Confirmation { case daily(DailyWelfareReceipt), gift(MemberGift, MemberGiftReceipt) }
    private(set) var account: AccountProfile?
    private(set) var tasks: [DailyWelfareTask] = []
    private(set) var gifts: [MemberGift] = []
    private(set) var membershipActive: Bool?
    private(set) var memberNotice: String?
    private(set) var hasLoadedDaily = false
    private(set) var hasLoadedGifts = false
    private(set) var loading = false
    private(set) var actionKey: String?
    private(set) var needsLogin = false
    private(set) var errorMessage: String?
    private var confirmations = WelfareConfirmationPolicy()
    var confirmedTasks: [Int: DailyWelfareAction] { confirmations.taskActions }
    var confirmedGifts: [String: String] { confirmations.giftMessages }
    private var generation: UUID?
    private var requestID = UUID()
    private var verified = false
    @ObservationIgnored private let client: Client
    var busy: Bool { loading || actionKey != nil }

    init(client: Client = .live) { self.client = client }

    func invalidateRead() {
        // A submitted action must retain its receipt even after the user navigates back.
        if actionKey == nil { requestID = UUID(); loading = false; verified = false }
    }

    func refresh(_ section: SectionKind) async {
        guard actionKey == nil else { return }
        let request = UUID()
        requestID = request
        loading = true; verified = false; errorMessage = nil
        defer { if requestID == request { loading = false } }
        let current = await client.generation()
        guard requestID == request, !Task.isCancelled else { return }
        if generation != current { clearAccountData(); generation = current }
        confirmations.prepare(generation: current, serviceDay: SignInProtocol.serviceDay(at: Date()))
        do {
            try await read(section, request: request, generation: current)
        } catch {
            guard await isCurrent(request, current), !AccountShelfState.isCancellation(error) else { return }
            handle(error)
        }
    }

    func canAct(on task: DailyWelfareTask) -> Bool {
        verified && !busy && !needsLogin && confirmations.canSubmit(task)
    }

    func taskButtonTitle(_ task: DailyWelfareTask) -> String {
        if actionKey == "task-\(task.id)" { return "正在处理…" }
        if let action = confirmedTasks[task.id] {
            if action == .claimReward, task.state == .claimed { return "已领取" }
            return action == .acceptTask ? "任务已领取，等待状态更新" : "奖励已领取，等待状态更新"
        }
        switch task.state {
        case .notAccepted: return "领取任务"
        case .inProgress: return "进行中"
        case .claimable: return "领取奖励"
        case .claimed: return "已领取"
        case .unknown: return "状态待确认"
        }
    }

    func canClaim(_ gift: MemberGift) -> Bool {
        verified && !busy && !needsLogin && membershipActive == true && confirmations.canSubmit(gift)
    }

    func perform(_ task: DailyWelfareTask) async {
        guard canAct(on: task), let generation else { return }
        let accept = task.canAccept
        await mutate(.daily, key: "task-\(task.id)", generation: generation) {
            let receipt = accept
                ? try await client.acceptTask(task.id, generation)
                : try await client.claimReward(task.id, generation)
            return .daily(receipt)
        }
    }

    func claim(_ gift: MemberGift) async {
        guard canClaim(gift), let generation else { return }
        await mutate(.gifts, key: "gift-\(gift.id)", generation: generation) {
            .gift(gift, try await client.claimGift(gift, generation))
        }
    }

    private func mutate(_ section: SectionKind, key: String, generation: UUID,
                        operation: () async throws -> Confirmation) async {
        let request = UUID()
        requestID = request; actionKey = key; errorMessage = nil
        defer { if requestID == request { actionKey = nil } }
        do {
            guard await isCurrent(request, generation) else { return }
            let confirmation = try await operation()
            guard await isCurrent(request, generation) else { return }
            switch confirmation {
            case .daily(let receipt): confirmations.record(receipt)
            case .gift(let gift, let receipt): confirmations.record(receipt, gift: gift)
            }
            do { try await read(section, request: request, generation: generation) }
            catch {
                guard await isCurrent(request, generation) else { return }
                verified = false
                errorMessage = "操作已成功，最新状态暂未更新。请刷新查看，无需重复领取。"
                needsLogin = Self.isLoginError(error)
            }
        } catch {
            guard await isCurrent(request, generation), !AccountShelfState.isCancellation(error) else { return }
            handle(error)
        }
    }

    private func read(_ section: SectionKind, request: UUID, generation: UUID) async throws {
        // Never interpret an anonymously readable catalogue as this account's task state.
        let identity = try await client.profile()
        guard await isCurrent(request, generation) else { throw CancellationError() }
        if let account, !account.matchesAccountIdentity(identity) {
            clearAccountData()
            confirmations.prepare(generation: generation, serviceDay: SignInProtocol.serviceDay(at: Date()))
        }
        account = identity
        switch section {
        case .daily:
            let snapshot = try await client.daily(generation)
            guard await isCurrent(request, generation), snapshot.generation == generation else { throw CancellationError() }
            tasks = snapshot.tasks.filter { !$0.isSignIn }
            hasLoadedDaily = true
            confirmations.reconcile(tasks: tasks)
        case .gifts:
            let snapshot = try await client.gifts(generation)
            guard await isCurrent(request, generation), snapshot.generation == generation,
                  snapshot.account.matchesAccountIdentity(identity) else { throw CancellationError() }
            account = snapshot.account; gifts = snapshot.gifts
            membershipActive = snapshot.isActiveMember; memberNotice = snapshot.notice
            hasLoadedGifts = true
            confirmations.reconcile(gifts: gifts)
        }
        verified = true; needsLogin = false; errorMessage = nil
    }

    private func isCurrent(_ request: UUID, _ expected: UUID) async -> Bool {
        guard requestID == request, generation == expected, !Task.isCancelled else { return false }
        let current = await client.generation()
        guard requestID == request, !Task.isCancelled else { return false }
        if current != expected { clearAccountData(); generation = current; return false }
        return generation == expected
    }

    private func handle(_ error: Error) {
        verified = false; errorMessage = error.localizedDescription
        needsLogin = Self.isLoginError(error)
        if needsLogin { account = nil; tasks = []; gifts = []; hasLoadedDaily = false; hasLoadedGifts = false }
    }

    private func clearAccountData() {
        account = nil; tasks = []; gifts = []; membershipActive = nil; memberNotice = nil
        confirmations = WelfareConfirmationPolicy(); hasLoadedDaily = false; hasLoadedGifts = false
        verified = false; needsLogin = false
    }

    private static func isLoginError(_ error: Error) -> Bool {
        switch error {
        case SFAPIError.loginRequired, SFAPIError.authenticationRequired: true
        default: false
        }
    }
}

/// A stale catalogue cannot reopen a confirmed action. Daily rewards remain confirmed for
/// the service day; gifts need both an elapsed interval and a freshly available server row.
struct WelfareConfirmationPolicy {
    private(set) var taskActions: [Int: DailyWelfareAction] = [:]
    private struct GiftConfirmation {
        let message: String
        let serviceDay: String
        let intervalDays: Int?
    }
    private var gifts: [String: GiftConfirmation] = [:]
    var giftMessages: [String: String] { gifts.mapValues(\.message) }
    private var generation: UUID?
    private var serviceDay: String?

    mutating func prepare(generation: UUID, serviceDay: String) {
        if self.generation != generation { taskActions = [:]; gifts = [:] }
        else if self.serviceDay != serviceDay { taskActions = [:] }
        self.generation = generation; self.serviceDay = serviceDay
    }

    mutating func record(_ receipt: DailyWelfareReceipt) { taskActions[receipt.taskID] = receipt.action }
    mutating func record(_ receipt: MemberGiftReceipt, gift: MemberGift) {
        guard let serviceDay else { return }
        gifts[gift.id] = GiftConfirmation(message: receipt.message, serviceDay: serviceDay, intervalDays: gift.intervalDays)
    }

    func canSubmit(_ task: DailyWelfareTask) -> Bool {
        taskActions[task.id] == nil && (task.canAccept || task.canClaimReward)
    }

    func canSubmit(_ gift: MemberGift) -> Bool {
        gifts[gift.id] == nil && gift.availability == .available
    }

    mutating func reconcile(tasks: [DailyWelfareTask]) {
        for task in tasks {
            if taskActions[task.id] == .acceptTask, task.state == .inProgress || task.state == .claimable || task.state == .claimed { taskActions[task.id] = nil }
        }
    }

    mutating func reconcile(gifts: [MemberGift]) {
        guard let serviceDay else { return }
        for gift in gifts where gift.availability == .available {
            guard let confirmed = self.gifts[gift.id], let interval = confirmed.intervalDays, interval > 0,
                  let elapsed = Self.days(from: confirmed.serviceDay, to: serviceDay), elapsed >= interval else { continue }
            self.gifts[gift.id] = nil
        }
    }

    private static func days(from first: String, to last: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: first), let end = formatter.date(from: last) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }
}
