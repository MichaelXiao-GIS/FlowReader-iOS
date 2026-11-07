import SwiftUI

struct AccountWalletSection: View {
    @Environment(CloudLibraryStore.self) private var cloud
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = AccountWalletState.shared

    var body: some View {
        Section {
            if let wallet = state.wallet {
                WalletBalanceRows(wallet: wallet)
            } else if state.loading {
                ProgressView("正在读取余额")
            } else if state.needsLogin {
                Text("登录后查看火券、代券和金币。").foregroundStyle(.secondary)
            } else {
                Text("余额暂未读取").foregroundStyle(.secondary)
            }
            if let error = state.error, !state.needsLogin { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !state.needsLogin {
                Button("刷新余额") { Task { await state.load() } }.disabled(state.loading)
                    .accessibilityIdentifier("wallet-refresh")
            }
        } header: { Text("账户余额") }
        footer: {
            if let account = state.wallet?.account {
                Text("当前账号：\(account.name)。火券与代券用于章节订阅，金币用于福利兑换。")
            }
        }
        .task(id: cloud.sessionGeneration) { await state.load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await state.load() } } }
    }
}

struct WalletBalanceRows: View {
    let wallet: AccountWallet
    var includesGold = true
    var body: some View {
        balance("火券", amount: wallet.fireMoney, id: "wallet-fire-money")
        balance("代券", amount: wallet.coupons, id: "wallet-coupons")
        if includesGold { balance("金币", amount: wallet.goldCoins, id: "wallet-gold-coins") }
    }
    private func balance(_ title: String, amount: Int?, id: String) -> some View {
        LabeledContent(title) {
            Text(amount.map { $0.formatted() } ?? "暂未提供").monospacedDigit()
                .foregroundStyle(amount == nil ? .secondary : .primary)
        }.accessibilityIdentifier(id)
    }
}
