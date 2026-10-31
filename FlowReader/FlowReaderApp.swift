import SwiftUI

@main
struct FlowReaderApp: App {
    @State private var library: LibraryStore

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let directory = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("FlowUITests-\(UUID().uuidString)") : nil
        _library = State(initialValue: LibraryStore(directory: directory))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--uitesting") {
                        library.seedDemoIfNeeded()
                    }
                }
        }
    }
}
