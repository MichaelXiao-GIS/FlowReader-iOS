import SwiftUI

struct MemberGiftsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var state: WelfareViewState
    @State private var showLogin = false

    var body: some View {
        List {
            Section {
                if let account = state.account {
                    LabeledContent("当前账号", value: account.name)
                    if let active = state.membershipActive {
                        LabeledContent("菠萝包会员", value: active ? "已开通" : "未开通")
                    }
                } else {
                    Text(state.loading ? "正在确认账号与会员资格…" : "请连接账号服务后查看会员礼包。")
                        .foregroundStyle(.secondary)
                }
                if state.needsLogin {
                    Button("登录菠萝包") { showLogin = true }.accessibilityIdentifier("member-gifts-connect")
                }
                if let notice = state.memberNotice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
            }
            if let message = state.errorMessage {
                Section {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    Button("刷新状态") { Task { await state.refresh(.gifts) } }.disabled(state.busy)
                }
            }
            Section {
                if state.loading && !state.hasLoadedGifts { ProgressView("正在读取会员礼包") }
                if state.hasLoadedGifts && state.gifts.isEmpty {
                    Text("当前没有可展示的会员礼包。").foregroundStyle(.secondary)
                }
                ForEach(state.gifts) { gift in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(gift.title).font(.headline)
                        if !gift.detail.isEmpty { Text(gift.detail).font(.subheadline).foregroundStyle(.secondary) }
                        if let amount = gift.quantity {
                            Label("奖励数量：\(amount)", systemImage: "gift").font(.subheadline).foregroundStyle(FlowTheme.accent)
                        }
                        if let days = gift.intervalDays, !gift.detail.contains("每\(days)天"), !gift.detail.contains("每 \(days) 天") {
                            Text("每 \(days) 天可领取一次").font(.caption).foregroundStyle(.secondary)
                        }
                        if let receipt = state.confirmedGifts[gift.id], gift.availability == .available || gift.availability == .unknown {
                            Label(receipt, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(FlowTheme.accent)
                        }
                        Button { Task { await state.claim(gift) } } label: {
                            HStack {
                                Text(buttonTitle(gift))
                                Spacer()
                                if state.actionKey == "gift-\(gift.id)" { ProgressView() }
                            }
                        }
                        .disabled(!state.canClaim(gift))
                        .accessibilityIdentifier("member-gift-\(gift.id)")
                    }.padding(.vertical, 8)
                }
            } header: { Text("会员礼包") }
            footer: {
                Text("会员资格和领取时间以菠萝包账号状态为准。")
            }
        }
        .scrollContentBackground(.hidden).background(FlowTheme.paper)
        .navigationTitle("会员礼包").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await state.refresh(.gifts) } }.disabled(state.busy)
            }
        }
        .task { await state.refresh(.gifts) }
        .refreshable { await state.refresh(.gifts) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await state.refresh(.gifts) } } }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await state.refresh(.gifts) } }) { AccountServiceLoginView() }
        .onDisappear { state.invalidateRead() }
    }

    private func buttonTitle(_ gift: MemberGift) -> String {
        if state.actionKey == "gift-\(gift.id)" { return "正在领取…" }
        if state.confirmedGifts[gift.id] != nil, gift.availability == .available || gift.availability == .unknown { return "已领取，等待状态更新" }
        switch gift.availability {
        case .available: return "领取礼包"
        case .cooldown:
            if gift.remainingDays == 1 { return "明日再来" }
            if let days = gift.remainingDays { return "\(days) 天后可领取" }
            return "尚在领取间隔内"
        case .membershipRequired: return "需要菠萝包会员"
        case .unknown: return "资格待确认"
        }
    }
}
