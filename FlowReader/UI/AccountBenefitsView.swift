import SwiftUI

struct AccountBenefitsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var membership: MembershipInfo?
    @State private var signState = SignInViewState()
    @State private var signConfirmations = SignInConfirmationStore.shared
    @State private var appAccount: AccountProfile?
    @State private var webAccount: AccountProfile?
    @State private var appConnected = false
    @State private var webConnected = false
    @State private var loading = false
    @State private var signing = false
    @State private var needsAppLogin = false
    @State private var needsWebLogin = false
    @State private var membershipError: String?
    @State private var identityError: String?
    @State private var showLogin = false
    @State private var showWebLogin = false
    @State private var requestID = UUID()
    @State private var sessionGeneration: UUID?
    @State private var actionTask: Task<Void, Never>?
    @State private var welfare: WelfareViewState

    init() {
        #if DEBUG
        _welfare = State(initialValue: ReadingTimeFixture.isEnabled ? ReadingTimeFixture.shared.makeWelfareState()
            : MemberGiftsFixture.isEnabled ? MemberGiftsFixture.makeState() : WelfareViewState())
        #else
        _welfare = State(initialValue: WelfareViewState())
        #endif
    }

    private var status: SignInStatus? { signState.status }
    private var receipt: SignInReceipt? { signState.receipt }
    private var hasSigned: Bool { signState.hasSigned }
    private var differentAccounts: Bool {
        guard let appAccount, let webAccount else { return false }
        return !appAccount.matchesAccountIdentity(webAccount)
    }

    var body: some View {
        List {
            Section {
                if webConnected {
                    LabeledContent("网页账号", value: webAccount?.name ?? (loading ? "正在读取" : "身份暂不可读"))
                }
                if appConnected {
                    LabeledContent("账号服务", value: appAccount?.name ?? (loading ? "正在读取" : "身份暂不可读"))
                }
                if let identityError { Text(identityError).font(.subheadline).foregroundStyle(.secondary) }
                Button(needsAppLogin ? "重新连接账号服务" : appConnected ? "更换账号服务连接" : "连接账号服务") { showLogin = true }
                    .disabled(signing)
                    .accessibilityIdentifier("benefits-connect")
                if needsWebLogin || (!webConnected && !appConnected) {
                    Button(needsWebLogin ? "重新连接网页账号" : "官方网页登录") { showWebLogin = true }
                        .disabled(signing)
                }
            } header: { Text("当前账号") }
            footer: {
                Text(differentAccounts ? "网页与账号服务连接了不同账号。会员信息与签到均标明实际使用的账号。" : "网页登录与账号服务分别保存。签到需要连接账号服务。")
            }

            Section {
                if loading && membership == nil { ProgressView("正在读取会员信息") }
                if let membership {
                    if let name = membership.vipName { LabeledContent("VIP 等级", value: name) }
                    else if let level = membership.vipLevel { LabeledContent("VIP 等级", value: "VIP \(level)") }
                    if let name = membership.membershipName { LabeledContent("会员名称", value: name) }
                    if let active = membership.isMember { LabeledContent("会员状态", value: active ? "已开通" : "未开通") }
                    if let date = membership.expiresAt { LabeledContent("到期日期", value: date) }
                    if membership.vipName == nil && membership.vipLevel == nil && membership.isMember == nil && membership.membershipName == nil {
                        Text("会员详情请在菠萝包官方查看").foregroundStyle(.secondary)
                    }
                } else if !loading && membershipError == nil {
                    Text("连接账号后查看会员信息").foregroundStyle(.secondary)
                }
                if let membershipError { errorMessage(membershipError) }
            } header: { Text("会员信息") }
            footer: {
                VStack(alignment: .leading, spacing: 5) {
                    if let membership {
                        Text("来自\(membership.source == .app ? "账号服务" : "网页账号")：\(membership.source == .app ? appAccount?.name ?? "身份暂不可读" : webAccount?.name ?? "身份暂不可读")")
                    }
                    Text("VIP 等级与会员状态不代表已购买某一作品的付费章节。")
                }
            }

            Section("福利") {
                NavigationLink { DailyWelfareView(state: welfare) } label: {
                    Label("日常福利", systemImage: "checklist")
                }.disabled(signing).accessibilityIdentifier("benefits-daily-welfare")
                NavigationLink { MemberGiftsView(state: welfare) } label: {
                    Label("会员礼包", systemImage: "gift")
                }.disabled(signing).accessibilityIdentifier("benefits-member-gifts")
            }

            Section {
                if appConnected {
                    if loading && status == nil && receipt == nil { ProgressView("正在读取签到状态") }
                    else {
                        Label(SignInPresentation.statusText(status: status, receipt: receipt), systemImage: hasSigned ? "checkmark.circle.fill" : "calendar")
                            .foregroundStyle(hasSigned ? FlowTheme.accent : Color.primary)
                            .accessibilityIdentifier("sign-in-status")
                    }
                    if let days = status?.consecutiveDays { LabeledContent("连续签到", value: "\(days) 天") }
                    if let receipt, !receipt.rewards.isEmpty {
                        ForEach(receipt.rewards) { reward in LabeledContent(reward.name, value: "\(reward.quantity)") }
                    }
                    if let message = signState.visibleError { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                    if let notice = signState.detailsNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sign-in-details-unavailable")
                    }
                    Button {
                        actionTask = Task { await signIn() }
                    } label: {
                        HStack {
                            Text(signing ? "正在签到" : hasSigned ? "今日已签到" : signState.actionError == nil ? "签到" : "重试签到")
                            Spacer()
                            if signing { ProgressView() }
                        }
                    }
                    .disabled(signing || loading || hasSigned || appAccount == nil || needsAppLogin)
                    .accessibilityIdentifier("sign-in-submit")
                } else {
                    Text("连接账号服务后，可读取今日状态并签到。").foregroundStyle(.secondary)
                }
            } header: { Text("每日签到") }
            footer: {
                if let appAccount { Text("签到账号：\(appAccount.name)。签到与奖励以菠萝包返回结果为准。") }
                else { Text("确认账号身份后才能签到。") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FlowTheme.paper)
        .navigationTitle("会员与签到")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(loading || signing)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await load() } }) { AccountServiceLoginView() }
        .sheet(isPresented: $showWebLogin, onDismiss: { Task { await load() } }) { WebLoginView() }
        .onDisappear { requestID = UUID(); actionTask?.cancel(); signing = false }
    }

    private func errorMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button("重试读取") { Task { await load() } }.disabled(loading || signing)
        }
    }

    @MainActor private func load() async {
        guard !signing else { return }
        let request = UUID()
        requestID = request
        loading = true
        let generation = await SFAPI.shared.sessionGeneration()
        guard requestID == request else { return }
        sessionGeneration = generation
        signState.prepare(generation: generation, serviceDay: SignInProtocol.serviceDay(at: Date()))
        // Read identities afresh so switching either independent session cannot reuse another account's benefits.
        membership = nil
        appAccount = nil; webAccount = nil
        membershipError = nil; identityError = nil; needsAppLogin = false; needsWebLogin = false
        let appSession = await SFAPI.shared.hasSavedAppLogin()
        let webSession = await SFAPI.shared.hasSavedWebLogin()
        guard requestID == request else { return }
        appConnected = appSession
        webConnected = webSession
        guard appSession || webSession else { loading = false; return }
        async let identities: Void = loadIdentities(request, appSession: appSession, webSession: webSession)
        async let benefits: Void = loadMembership(request)
        async let signStatus: Void = loadSignStatus(request, connected: appSession)
        _ = await (identities, benefits, signStatus)
        if requestID == request { loading = false }
    }

    @MainActor private func loadIdentities(_ request: UUID, appSession: Bool, webSession: Bool) async {
        if webSession {
            do {
                let account = try await SFAPI.shared.webProfile()
                if await isCurrent(request) { webAccount = account }
            } catch {
                if await isCurrent(request), !AccountShelfState.isCancellation(error) {
                    identityError = error.localizedDescription
                    if isLoginError(error) { needsWebLogin = true }
                }
            }
        }
        if appSession {
            do {
                let account = try await SFAPI.shared.accountServiceProfile()
                if await isCurrent(request) {
                    appAccount = account
                    if signConfirmations.isConfirmed(for: account) { signState.restoreConfirmedDay() }
                    if let status { signConfirmations.record(status, for: account) }
                }
            } catch {
                guard await isCurrent(request), !AccountShelfState.isCancellation(error) else { return }
                identityError = error.localizedDescription
                if isLoginError(error) { needsAppLogin = true }
            }
        }
    }

    @MainActor private func loadMembership(_ request: UUID) async {
        do {
            let result = try await SFAPI.shared.membership()
            if await isCurrent(request) { membership = result }
        } catch {
            guard await isCurrent(request), !AccountShelfState.isCancellation(error) else { return }
            membershipError = error.localizedDescription
            if appConnected && isLoginError(error) { needsAppLogin = true }
            if !appConnected && webConnected && isLoginError(error) { needsWebLogin = true }
        }
    }

    @MainActor private func loadSignStatus(_ request: UUID, connected: Bool) async {
        guard connected else { return }
        do {
            let result = try await SFAPI.shared.signInStatus()
            if await isCurrent(request) {
                signState.loaded(result)
                if let appAccount { signConfirmations.record(result, for: appAccount) }
            }
        } catch {
            guard await isCurrent(request), !AccountShelfState.isCancellation(error) else { return }
            signState.failedStatus(error)
            if isLoginError(error) { needsAppLogin = true }
        }
    }

    @MainActor private func signIn() async {
        guard !signing, !loading, appConnected, appAccount != nil, !needsAppLogin, !hasSigned else { return }
        signing = true
        signState.beginAction()
        let request = requestID
        let submittedAt = Date()
        defer { if requestID == request { signing = false } }
        do {
            guard await isCurrent(request), let generation = sessionGeneration else { return }
            let result = try await SFAPI.shared.signInToday(expectedGeneration: generation)
            guard await isCurrent(request) else { return }
            signState.confirmed(result)
            if let appAccount { signConfirmations.record(result, for: appAccount, at: submittedAt) }
            // The receipt confirms this action; refresh optional status fields without inventing a streak.
            await loadSignStatus(request, connected: true)
        } catch {
            guard await isCurrent(request), !AccountShelfState.isCancellation(error) else { return }
            signState.failedAction(error)
            if isLoginError(error) { needsAppLogin = true }
        }
    }

    @MainActor private func isCurrent(_ request: UUID) async -> Bool {
        guard requestID == request, !Task.isCancelled, let expected = sessionGeneration else { return false }
        let current = await SFAPI.shared.sessionGeneration()
        return requestID == request && !Task.isCancelled && sessionGeneration == expected && current == expected
    }

    private func isLoginError(_ error: Error) -> Bool {
        switch error {
        case SFAPIError.loginRequired, SFAPIError.authenticationRequired: return true
        default: return false
        }
    }
}

enum SignInPresentation {
    static func statusText(status: SignInStatus?, receipt: SignInReceipt?) -> String {
        if let receipt { return receipt.alreadySigned ? "今日已签到" : "签到完成" }
        switch status?.signedToday {
        case true: return "今日已签到"
        case false: return "今日尚未签到"
        case nil: return "今日签到状态暂未提供"
        }
    }
}
