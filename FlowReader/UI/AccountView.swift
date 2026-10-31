import SwiftUI
import WebKit

struct AccountView: View {
    private enum Destination: Hashable { case benefits }
    @Environment(CloudLibraryStore.self) private var cloud
    @AppStorage("appearance") private var appearance = "system"
    @State private var showLogin = false
    @State private var showLogout = false
    @State private var showAbout = false
    @State private var showAppLogin = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: cloud.account == nil ? "person.crop.circle" : "person.crop.circle.fill")
                        .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(FlowTheme.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cloud.account?.name ?? "你的阅读空间").font(.title3.weight(.semibold))
                        Text(cloud.account != nil ? "你的云端阅读账号" : "登录菠萝包，连接云端书架")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10)
                if cloud.appConnected {
                    Label("账号已连接", systemImage: "checkmark.circle").foregroundStyle(FlowTheme.accent)
                    Button("切换账号") { showAppLogin = true }
                } else {
                    Button(cloud.appNeedsLogin ? "重新登录菠萝包" : "登录菠萝包") { showAppLogin = true }
                        .accessibilityIdentifier("account-login")
                }
            } footer: {
                Text("登录后同步书架、云端续读、会员福利与有声。收藏与阅读进度位于“书库”。")
            }
            if let error = cloud.accountError {
                Section("账号信息") {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("重试读取账号") { Task { await cloud.refreshAccount() } }
                        .disabled(cloud.accountLoading)
                }
            }
            AccountWalletSection { showAppLogin = true }
            Section("会员与签到") {
                NavigationLink(value: Destination.benefits) {
                    Label("会员信息与每日签到", systemImage: "checkmark.seal")
                }
                .accessibilityIdentifier("account-benefits")
            }
            Section {
                if cloud.webConnected {
                    Label(cloud.webAccount.map { "已授权 · \($0.name)" } ?? "网页阅读已授权", systemImage: "checkmark.circle")
                        .foregroundStyle(FlowTheme.accent)
                    Button("更换网页授权") { showLogin = true }
                } else {
                    Button(cloud.webNeedsLogin ? "重新授权网页阅读" : "授权网页阅读") { showLogin = true }
                        .accessibilityIdentifier("official-login")
                }
                if let message = cloud.webConnectionError {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let primary = cloud.account, let web = cloud.webAccount,
                   cloud.usesAppAccount, !primary.matchesAccountIdentity(web) {
                    Text("网页授权与当前账号不同，请更换为同一账号后读取已购章节。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("网页阅读授权 · 可选") }
            footer: {
                Text("账号登录已支持授权正文；网页授权仅供旧版阅读方式兼容使用，失效不会阻止书架与福利同步。")
            }
            Section("偏好设置") {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Button("关于菠萝阅") { showAbout = true }.foregroundStyle(.primary)
            }
            if cloud.hasSavedConnection {
                Section {
                    Button("退出登录", role: .destructive) { showLogout = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FlowTheme.paper)
        .navigationTitle("我的")
        .navigationDestination(for: Destination.self) { _ in AccountBenefitsView() }
        .accessibilityIdentifier("account-content")
        .refreshable { await cloud.refreshAccount(); await AccountWalletState.shared.load() }
        .task { await cloud.refreshAccount() }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await cloud.refreshAccount() } }) { WebLoginView() }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showAppLogin, onDismiss: { Task { await cloud.refreshAccount() } }) { AccountServiceLoginView() }
        .confirmationDialog("退出后将清除本机登录信息，下载的作品会保留。", isPresented: $showLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task {
                    cloud.reset()
                    await SFAPI.shared.logout()
                    await cloud.refreshAccount()
                }
            }
        }
    }
}

struct AccountServiceLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudLibraryStore.self) private var cloud
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("菠萝包账号", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                } footer: {
                    Text("登录后同步书架、云端续读、会员福利与有声作品。密码只用于本次登录，不会保存；如需额外验证，请在官方客户端完成。")
                }
                if let error {
                    Section { Text(error).font(.subheadline).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack { Text("连接"); Spacer(); if connecting { ProgressView() } }
                    }
                    .disabled(connecting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("连接账号服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(connecting) } }
        }
        .tint(FlowTheme.accent)
        .interactiveDismissDisabled(connecting)
        .onDisappear { password = "" }
    }

    @MainActor private func connect() async {
        connecting = true
        error = nil
        let submittedPassword = password
        password = ""
        do {
            _ = try await SFAPI.shared.loginApp(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: submittedPassword)
            await cloud.checkSessionGeneration()
            dismiss()
        } catch { self.error = error.localizedDescription }
        connecting = false
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppLifecycleDiagnostics.self) private var lifecycle
    @State private var copiedDiagnostics = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("菠萝阅").font(.largeTitle.weight(.semibold))
                        Text("FLOW READER").font(.caption.weight(.medium)).tracking(3).foregroundStyle(FlowTheme.accent)
                        Text("一个安静、独立的轻小说阅读空间。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 20)
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
                Section("来源与许可") {
                    Link("SF Novel Flow 参考项目", destination: URL(string: "https://github.com/Mios-dream/SFNovel-ReaderProject")!)
                    Text("本应用基于参考项目的接口行为，以 SwiftUI 原生实现，采用 GPLv3 许可。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("你的数据") {
                    Text("账号会话保存在系统钥匙串中。书库、阅读进度和下载保存在本机。本应用不收集分析数据，不展示广告。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("独立第三方客户端，与菠萝包及 SFACG 无隶属关系。作品版权归各自权利人所有。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("运行诊断") {
                        Text(lifecycle.explanation).font(.subheadline)
                        LabeledContent("启动标识", value: String(lifecycle.snapshot.launchID.uuidString.prefix(8)))
                        LabeledContent("当前启动", value: lifecycle.snapshot.startedAt.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("累计启动", value: String(lifecycle.snapshot.launchCount))
                        LabeledContent("同进程返回", value: String(lifecycle.snapshot.sameProcessReturnCount))
                        if let date = lifecycle.snapshot.lastForegroundAt {
                            LabeledContent("最近前台", value: date.formatted(date: .abbreviated, time: .standard))
                        }
                        if let date = lifecycle.snapshot.lastBackgroundAt {
                            LabeledContent("最近后台", value: date.formatted(date: .abbreviated, time: .standard))
                        }
                        LabeledContent("Root 挂载次数", value: String(lifecycle.snapshot.rootMountCount))
                        LabeledContent("安装包退后台即退出", value: lifecycle.snapshot.exitsOnSuspend ? "已设置" : "未设置")
                        Text("仅保存在本机，不含账号、阅读内容或登录凭据。页面挂载次数不等于进程重启次数。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(copiedDiagnostics ? "已复制诊断" : "复制诊断") {
                            UIPasteboard.general.string = lifecycle.report
                            copiedDiagnostics = true
                        }
                    }
                }
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(FlowTheme.accent)
    }
}

struct WebLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudLibraryStore.self) private var cloud
    @State private var controller = LoginWebController()
    @State private var finishing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .padding(12).frame(maxWidth: .infinity).background(FlowTheme.card)
                }
                if let pageError = controller.error {
                    FlowErrorView(message: pageError) { controller.load() }
                } else {
                    LoginWebContent(controller: controller)
                        .overlay {
                            if finishing { ProgressView("正在连接账号").padding(24).glassEffect(in: .rect(cornerRadius: 20)) }
                        }
                }
            }
            .navigationTitle("菠萝包官网登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成登录") { Task { await finish() } }.disabled(finishing)
                }
            }
        }
        .tint(FlowTheme.accent)
        .interactiveDismissDisabled(finishing)
    }

    @MainActor private func finish() async {
        finishing = true
        error = nil
        let cookies = await controller.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        do {
            _ = try await SFAPI.shared.importWebCookies(cookies)
            await cloud.checkSessionGeneration()
            dismiss()
        } catch { self.error = error.localizedDescription }
        finishing = false
    }
}

@MainActor @Observable private final class LoginWebController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var error: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        load()
    }

    func load() {
        error = nil
        webView.load(URLRequest(url: URL(string: "https://passport.sfacg.com/Login.aspx")!))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        guard let url = navigationAction.request.url, let host = url.host,
              url.scheme == "https", host == "sfacg.com" || host.hasSuffix(".sfacg.com") else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

private struct LoginWebContent: UIViewRepresentable {
    let controller: LoginWebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
