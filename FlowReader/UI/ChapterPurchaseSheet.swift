import SwiftUI

struct ChapterPurchaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CloudLibraryStore.self) private var cloud
    let book: Book
    let chapter: Chapter
    let onRead: (Chapter) -> Void
    @State private var state: ChapterPurchaseViewState
    @State private var confirmation: ChapterOrderQuote?
    @State private var showConfirmation = false
    @State private var showLogin = false

    init(book: Book, chapter: Chapter, onRead: @escaping (Chapter) -> Void) {
        self.book = book; self.chapter = chapter; self.onRead = onRead
        _state = State(initialValue: ChapterPurchaseViewState(chapter: chapter))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(chapter.title).font(.headline)
                    Text(book.title).font(.subheadline).foregroundStyle(.secondary)
                }
                if state.loading && state.quote == nil { Section { ProgressView("正在读取价格与余额") } }
                if let quote = state.quote {
                    Section("当前账号") { Text(quote.account.name).accessibilityIdentifier("purchase-account") }
                    Section {
                        LabeledContent("本章价格", value: quote.price == 0 ? "已可阅读" : "\(quote.price) 火券 / 代券")
                            .accessibilityIdentifier("purchase-price")
                        WalletBalanceRows(wallet: quote.wallet, includesGold: false)
                    } footer: {
                        Text("由菠萝包按可用代券与火券结算，金币不用于本章订阅。")
                    }
                }
                Section {
                    if let chapter = state.readableChapter {
                        Label(state.receipt?.isReadabilityConfirmed == true ? state.receipt!.message : "本章已可阅读，无需再次购买。", systemImage: "checkmark.circle")
                            .foregroundStyle(FlowTheme.accent).accessibilityIdentifier("purchase-readable")
                        Button("开始阅读") {
                            Task {
                                await cloud.applyChapterAccess(chapter)
                                onRead(chapter)
                                dismiss()
                            }
                        }.accessibilityIdentifier("purchase-read")
                    } else if let message = state.pendingMessage {
                        Text(message).foregroundStyle(.secondary).accessibilityIdentifier("purchase-pending")
                    } else if let quote = state.quote, !state.needsLogin {
                        if quote.wallet.subscriptionBalance == nil {
                            Text("完整余额暂未确认，请刷新后查看。").foregroundStyle(.secondary)
                        } else if !quote.canPurchase {
                            Text("火券与代券余额不足，请在菠萝包官方充值后刷新。").foregroundStyle(.secondary)
                        }
                        Button {
                            Task {
                                confirmation = await state.confirmation()
                                showConfirmation = confirmation != nil
                            }
                        } label: {
                            HStack { Text(state.submitting ? "正在提交订阅" : "购买本章"); Spacer(); if state.submitting { ProgressView() } }
                        }
                        .disabled(!state.canRequestConfirmation)
                        .accessibilityIdentifier("purchase-review")
                    }
                    if let error = state.error { Text(error).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("purchase-error") }
                    if state.needsLogin {
                        Button("登录菠萝包") { showLogin = true }.accessibilityIdentifier("purchase-login")
                    }
                    if state.readableChapter == nil {
                        Button(state.resultPending || state.quote?.isPending == true ? "刷新章节状态" : "刷新价格与余额") {
                            confirmation = nil; showConfirmation = false
                            Task { await state.load() }
                        }.disabled(state.loading || state.submitting).accessibilityIdentifier("purchase-refresh")
                    }
                } footer: {
                    Text("本次仅订阅这一章，不会开启自动订阅。")
                    if ChapterCommerceClient.usesUITestFixture { Text("离线购买测试，不会提交真实订单。") }
                }
            }
            .scrollContentBackground(.hidden).background(FlowTheme.paper)
            .navigationTitle("购买本章").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(state.submitting).accessibilityIdentifier("purchase-close")
                }
            }
        }
        .interactiveDismissDisabled(state.submitting)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: cloud.sessionGeneration) { confirmation = nil; showConfirmation = false; await state.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !state.submitting { confirmation = nil; showConfirmation = false; Task { await state.load() } }
        }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await cloud.checkSessionGeneration(); await state.load() } }) { AccountServiceLoginView() }
        .confirmationDialog("确认购买这一章？", isPresented: $showConfirmation, titleVisibility: .visible, presenting: confirmation) { quote in
            Button("确认购买 · \(quote.price) 火券 / 代券") {
                Task {
                    await state.confirm(quote)
                    await AccountWalletState.shared.load()
                }
            }.accessibilityIdentifier("purchase-confirm")
            Button("取消", role: .cancel) { confirmation = nil }.accessibilityIdentifier("purchase-cancel")
        } message: { quote in
            Text("\(quote.chapter.title)\n当前账号：\(quote.account.name)\n本章合计 \(quote.price) 火券 / 代券，由菠萝包按可用余额结算。")
        }
        .onDisappear { state.cancelReads() }
    }
}
