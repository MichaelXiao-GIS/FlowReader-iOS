import SwiftUI

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ReadingSession.self) private var readingSession
    @Environment(AppLifecycleDiagnostics.self) private var lifecycle
    enum Destination: String, Hashable { case discover, library, downloads, account }
    @AppStorage("navigation.selectedTab") private var selectedTab = Destination.discover.rawValue
    @State private var discoverPath = NavigationPath()
    @State private var accountPath = NavigationPath()
    @State private var cloudLibrary = CloudLibraryStore()
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        @Bindable var readingSession = readingSession
        Group {
            if #available(iOS 27.1, *) {
                tabs.defaultTabBarPlacement(.sidebar)
            } else {
                tabs
            }
        }
        .tint(FlowTheme.accent)
        .fullScreenCover(item: $readingSession.route) { route in
            ReaderView(book: route.book, chapters: route.chapters, initialChapter: route.initialChapter)
        }
        .environment(readingSession)
        .environment(cloudLibrary)
        .task {
            lifecycle.recordRootMount()
            readingSession.restoreIfNeeded(from: library)
            await cloudLibrary.checkSessionGeneration()
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .alert("无法完成操作", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { Destination(rawValue: selectedTab) ?? .discover }, set: { selectedTab = $0.rawValue })) {
            Tab("发现", systemImage: "sparkles", value: .discover) {
                NavigationStack(path: $discoverPath) { DiscoverView() }
            }
            Tab("书库", systemImage: "books.vertical", value: .library) {
                LocalLibraryView()
            }
            Tab("下载", systemImage: "arrow.down.circle", value: .downloads) {
                DownloadsView()
            }
            Tab("我的", systemImage: "person.crop.circle", value: .account) {
                NavigationStack(path: $accountPath) { AccountView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
