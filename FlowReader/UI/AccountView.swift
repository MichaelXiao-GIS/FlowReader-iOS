import SwiftUI
import WebKit

struct AccountView: View {
    @AppStorage("appearance") private var appearance = "system"
    @State private var profile: AccountProfile?
    @State private var shelf: [Book] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showLogin = false
    @State private var showLogout = false
    @State private var showAbout = false
    @State private var showAppLogin = false
    @State private var appConnected = false
    @State private var webConnected = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: profile == nil ? "person.crop.circle" : "person.crop.circle.fill")
                        .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(FlowTheme.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile?.name ?? "你的阅读空间").font(.title3.weight(.semibold))
                        Text(profile == nil ? "登录菠萝包，连接账号书架" : "已连接菠萝包账号")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10)
                if !webConnected {
                    Button(profile == nil ? "登录菠萝包" : "连接官方网页账号") { showLogin = true }
                        .accessibilityIdentifier("official-login")
                } else {
                    Label("网页账号已连接", systemImage: "checkmark.circle").foregroundStyle(FlowTheme.accent)
                }
            }
            if let error {
                Section { Text(error).font(.subheadline).foregroundStyle(.secondary) }
            }
            if profile != nil {
                Section {
                    if loading { ProgressView("正在同步书架") }
                    else if shelf.isEmpty {
                        Text("书架还没有作品").foregroundStyle(.secondary)
                    }
                    ForEach(shelf) { book in
                        NavigationLink(value: book) { BookRow(book: book) }
                    }
                } header: {
                    HStack { Text("账号书架"); Spacer(); Text("\(shelf.count)") }
                }
            }
            Section("有声服务") {
                if appConnected {
                    Label("已连接", systemImage: "checkmark.circle").foregroundStyle(FlowTheme.accent)
                } else {
                    Button("连接有声服务") { showAppLogin = true }
                }
            }
            Section("偏好设置") {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Button("关于菠萝阅") { showAbout = true }.foregroundStyle(.primary)
            }
            if profile != nil {
                Section {
                    Button("退出登录", role: .destructive) { showLogout = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FlowTheme.paper)
        .navigationTitle("我的")
        .navigationDestination(for: Book.self) { book in BookDetailView(book: book) }
        .accessibilityIdentifier("account-content")
        .refreshable { await refresh() }
        .task { await refresh() }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await refresh() } }) { WebLoginView() }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showAppLogin, onDismiss: { Task { await refresh() } }) { AppLoginView() }
        .confirmationDialog("退出后将清除本机登录信息，下载的作品会保留。", isPresented: $showLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task {
                    await SFAPI.shared.logout()
                    profile = nil
                    shelf = []
                    error = nil
                    appConnected = false
                    webConnected = false
                }
            }
        }
    }

    @MainActor private func refresh() async {
        appConnected = await SFAPI.shared.hasAppSession()
        webConnected = await SFAPI.shared.hasWebSession()
        guard await SFAPI.shared.hasSession() else { profile = nil; shelf = []; return }
        loading = true
        error = nil
        do {
            profile = try await SFAPI.shared.profile()
            shelf = try await SFAPI.shared.bookshelf()
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct AppLoginView: View {
    @Environment(\.dismiss) private var dismiss
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
                    Text("有声播放需要 App 会话。登录可能需要在官方客户端完成验证。密码不会保存。")
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
            .navigationTitle("连接有声服务")
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
            dismiss()
        } catch { self.error = error.localizedDescription }
        connecting = false
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
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
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(FlowTheme.accent)
    }
}

struct WebLoginView: View {
    @Environment(\.dismiss) private var dismiss
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
