import SwiftUI

@main
struct FlowReaderApp: App {
    @State private var library: LibraryStore
    private let preferences: UserDefaults

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        if testing {
            let name = "FlowReader.UITests.Preferences"
            preferences = UserDefaults(suiteName: name)!
            preferences.removePersistentDomain(forName: name)
        } else { preferences = .standard }
        let directory = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("FlowUITests-\(UUID().uuidString)") : nil
        _library = State(initialValue: LibraryStore(directory: directory))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .defaultAppStorage(preferences)
                .environment(library)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--uitesting") {
                        library.seedDemoIfNeeded()
                    }
                }
        }
    }
}
