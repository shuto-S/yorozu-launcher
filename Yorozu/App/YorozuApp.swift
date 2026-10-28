import SwiftUI

@main
struct YorozuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Keep dependency-provided controls in English even when macOS uses another language.
        let arguments = ProcessInfo.processInfo.arguments
        if !AppEnvironment.requiresIsolation(arguments: arguments) {
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
