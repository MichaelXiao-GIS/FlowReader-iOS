import SwiftUI

@main
struct FlowReaderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: LibraryStore
    @State private var readingSession: ReadingSession
    @State private var lifecycle: AppLifecycleDiagnostics
    @State private var readingTime: ReadingTimeReporter
    private let preferences: UserDefaults

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let preserveTestState = ProcessInfo.processInfo.arguments.contains("--uitesting-preserve-state")
        if testing {
            let name = "FlowReader.UITests.Preferences"
            preferences = UserDefaults(suiteName: name)!
            if !preserveTestState { preferences.removePersistentDomain(forName: name) }
        } else { preferences = .standard }
        let directory = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("FlowUITests-Library", isDirectory: true) : nil
        if let directory, !preserveTestState { try? FileManager.default.removeItem(at: directory) }
        _library = State(initialValue: LibraryStore(directory: directory))
        _readingSession = State(initialValue: ReadingSession(defaults: preferences))
        _lifecycle = State(initialValue: AppLifecycleDiagnostics(defaults: preferences))
        #if DEBUG
        _readingTime = State(initialValue: ReadingTimeFixture.isEnabled ? ReadingTimeFixture.shared.makeReporter() : ReadingTimeReporter())
        #else
        _readingTime = State(initialValue: ReadingTimeReporter())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .defaultAppStorage(preferences)
                .environment(library)
                .environment(readingSession)
                .environment(lifecycle)
                .environment(readingTime)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase != .active { readingTime.setActivity(nil) }
                    switch phase {
                    case .active: lifecycle.recordPhase(.active)
                    case .inactive: lifecycle.recordPhase(.inactive)
                    case .background: lifecycle.recordPhase(.background)
                    @unknown default: break
                    }
                }
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--uitesting") {
                        library.seedDemoIfNeeded()
                    }
                }
        }
    }
}
