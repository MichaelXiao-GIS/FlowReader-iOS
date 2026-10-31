import SwiftUI

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    enum Destination: Hashable { case discover, library, downloads, account }
    @State private var selection: Destination = .discover
    @State private var discoverPath = NavigationPath()
    @State private var accountPath = NavigationPath()
    @State private var cloudLibrary = CloudLibraryStore()
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Group {
            if #available(iOS 27.1, *) {
                tabs.defaultTabBarPlacement(.sidebar)
            } else {
                tabs
            }
        }
        .tint(FlowTheme.accent)
        .environment(cloudLibrary)
        .task { await cloudLibrary.checkSessionGeneration() }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .alert("无法完成操作", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("发现", systemImage: "sparkles", value: .discover) {
                NavigationStack(path: $discoverPath) { DiscoverView().readingDestinations() }
            }
            Tab("书库", systemImage: "books.vertical", value: .library) {
                LocalLibraryView()
            }
            Tab("下载", systemImage: "arrow.down.circle", value: .downloads) {
                DownloadsView()
            }
            Tab("我的", systemImage: "person.crop.circle", value: .account) {
                NavigationStack(path: $accountPath) { AccountView().readingDestinations() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
