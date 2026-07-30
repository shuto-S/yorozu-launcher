import AppKit
import KeyboardShortcuts
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.yorozu.app", category: "lifecycle")

    private lazy var store: LauncherStore? = {
        do {
            return try LauncherStore(databaseURL: LauncherStore.defaultDatabaseURL())
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    private lazy var catalog = ApplicationCatalog(
        store: store,
        discoverer: FileSystemApplicationDiscoverer()
    )
    private lazy var featureCatalog = FeatureCommandCatalog(store: store)
    private lazy var clipboardCatalog = ClipboardCatalog(store: store)
    private lazy var snippetCatalog = SnippetCatalog(store: store)
    private let clipboardPreferences = ClipboardPreferences()
    private lazy var urlPreviewService = URLPreviewService(store: store)

    lazy var viewModel = LauncherViewModel(
        catalog: catalog,
        featureCatalog: featureCatalog,
        clipboardCatalog: clipboardCatalog,
        snippetCatalog: snippetCatalog,
        clipboardPreferences: clipboardPreferences,
        urlPreviewService: urlPreviewService,
        launcher: WorkspaceApplicationLauncher()
    )

    private lazy var clipboardMonitor = ClipboardMonitor(
        reader: SystemPasteboardReader(),
        preferences: clipboardPreferences,
        catalog: clipboardCatalog,
        onSnapshot: { [weak self] snapshot in
            self?.viewModel.handleClipboardSnapshot(snapshot)
        }
    )
    private lazy var pasteCoordinator = PasteCoordinator(monitor: clipboardMonitor)
    private lazy var paletteController = PaletteWindowController(
        viewModel: viewModel,
        pasteCoordinator: pasteCoordinator
    )
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let isSettingsUITesting = arguments.contains("--ui-testing-settings")
        #if DEBUG
        configureDebugAppearance(arguments: arguments)
        #endif
        NSApp.setActivationPolicy(isUITesting || isSettingsUITesting ? .regular : .accessory)

        _ = paletteController
        menuBarController = MenuBarController(
            viewModel: viewModel,
            openPalette: { [weak self] in
                self?.paletteController.toggle(route: .root)
            },
            openSettings: { [weak self] in
                self?.showSettings()
            }
        )

        KeyboardShortcuts.onKeyUp(for: .toggleLauncher) { [weak self] in
            self?.paletteController.toggle(route: .root)
        }
        KeyboardShortcuts.onKeyUp(for: .openClipboardHistory) { [weak self] in
            self?.paletteController.toggle(route: .clipboard)
        }
        KeyboardShortcuts.onKeyUp(for: .openSnippets) { [weak self] in
            self?.paletteController.toggle(route: .snippets)
        }
        KeyboardShortcuts.onKeyUp(for: .openAliases) { [weak self] in
            self?.paletteController.toggle(route: .aliases)
        }

        viewModel.start()
        Task {
            await clipboardMonitor.start()
        }

        #if DEBUG
        let performanceRoute: (route: PaletteRoute, fileName: String)? = {
            if arguments.contains("--performance-testing-clipboard") {
                return (.clipboard, "yorozu-palette-performance-clipboard.json")
            }
            if arguments.contains("--performance-testing-snippets") {
                return (.snippets, "yorozu-palette-performance-snippets.json")
            }
            if arguments.contains("--performance-testing") {
                return (.root, "yorozu-palette-performance.json")
            }
            return nil
        }()
        if let performanceRoute {
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                let report = await paletteController.runPresentationStressTest(
                    iterations: 100,
                    route: performanceRoute.route
                )
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(report)
                    try data.write(
                        to: URL(
                            fileURLWithPath:
                                "/private/tmp/\(performanceRoute.fileName)"
                        ),
                        options: .atomic
                    )
                    logger.notice(
                        "Palette stress test completed: p95 \(report.p95Milliseconds, privacy: .public) ms"
                    )
                } catch {
                    logger.error(
                        "Palette stress report failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                NSApp.terminate(nil)
            }
            return
        }
        #endif

        if isUITesting {
            paletteController.show(route: .root)
        } else if isSettingsUITesting {
            showSettings()
        }
    }

    func showSettings() {
        paletteController.show(route: .settings, origin: .direct)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyboardShortcuts.disable(
            .toggleLauncher,
            .openClipboardHistory,
            .openSnippets,
            .openAliases
        )
        Task {
            await clipboardMonitor.stop()
        }
        paletteController.invalidate()
    }

    #if DEBUG
    private func configureDebugAppearance(arguments: [String]) {
        let usesHighContrast = arguments.contains("--ui-testing-high-contrast")
        if arguments.contains("--ui-testing-light") {
            NSApp.appearance = NSAppearance(
                named: usesHighContrast ? .accessibilityHighContrastAqua : .aqua
            )
        } else if arguments.contains("--ui-testing-dark") {
            NSApp.appearance = NSAppearance(
                named: usesHighContrast
                    ? .accessibilityHighContrastDarkAqua
                    : .darkAqua
            )
        }
    }
    #endif
}
