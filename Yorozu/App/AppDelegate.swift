import AppKit
import KeyboardShortcuts
import os

@MainActor
struct AppEnvironment {
    let storeOpenResult: LauncherStoreOpenResult
    let defaults: UserDefaults
    let discoverer: any ApplicationDiscovering
    let launcher: any ApplicationLaunching
    let startsClipboardMonitor: Bool
    let temporaryDirectory: URL?
    let usesLivePasteIntegration: Bool
    let allowsURLPreviewNetwork: Bool
    let registersGlobalShortcuts: Bool
    let isolatesShortcutSettings: Bool

    static func production() -> AppEnvironment {
        let result: LauncherStoreOpenResult
        do {
            result = LauncherStore.openRecovering(
                databaseURL: try LauncherStore.defaultDatabaseURL()
            )
        } catch {
            result = LauncherStoreOpenResult(store: nil, recoveryNotice: nil)
        }
        return AppEnvironment(
            storeOpenResult: result,
            defaults: .standard,
            discoverer: FileSystemApplicationDiscoverer(),
            launcher: WorkspaceApplicationLauncher(),
            startsClipboardMonitor: true,
            temporaryDirectory: nil,
            usesLivePasteIntegration: true,
            allowsURLPreviewNetwork: true,
            registersGlobalShortcuts: true,
            isolatesShortcutSettings: false
        )
    }

    static func uiTesting(runID: String) throws -> AppEnvironment {
        let safeRunID = runID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "com.yorozu.app-ui-tests-\(safeRunID)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let suiteName = "com.yorozu.app.ui-tests.\(safeRunID)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defaults.removePersistentDomain(forName: suiteName)

        return AppEnvironment(
            storeOpenResult: LauncherStore.openRecovering(
                databaseURL: directory.appendingPathComponent("Yorozu.sqlite")
            ),
            defaults: defaults,
            discoverer: UITestApplicationDiscoverer(),
            launcher: UITestApplicationLauncher(),
            startsClipboardMonitor: false,
            temporaryDirectory: directory,
            usesLivePasteIntegration: false,
            allowsURLPreviewNetwork: false,
            registersGlobalShortcuts: false,
            isolatesShortcutSettings: true
        )
    }
}

private actor UITestApplicationDiscoverer: ApplicationDiscovering {
    func discoverApplications() async throws -> [DiscoveredApplication] {
        [
            DiscoveredApplication(
                id: ApplicationIdentity(rawValue: "bundle:com.microsoft.vscode"),
                bundleIdentifier: "com.microsoft.vscode",
                canonicalURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                displayName: "Visual Studio Code",
                localizedName: nil,
                version: "1.0",
                normalizedSearchText: "visual studio code com.microsoft.vscode",
                rootPriority: 0
            ),
            DiscoveredApplication(
                id: ApplicationIdentity(rawValue: "bundle:com.apple.Safari"),
                bundleIdentifier: "com.apple.Safari",
                canonicalURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                displayName: "Safari",
                localizedName: nil,
                version: "1.0",
                normalizedSearchText: "safari com.apple.safari",
                rootPriority: 0
            ),
        ]
    }
}

@MainActor
private final class UITestApplicationLauncher: ApplicationLaunching {
    func launch(_ application: LaunchableApplication) async throws {}
    func revealInFinder(_ application: LaunchableApplication) {}
}

@MainActor
private final class UITestPasteboard: PasteboardAccessing {
    private var storedSnapshot = PasteboardSnapshot(items: [])
    private(set) var changeCount = 0

    func snapshot() -> PasteboardSnapshotResult {
        .captured(storedSnapshot)
    }

    func replace(
        with content: PasteboardContent,
        preserving snapshot: PasteboardSnapshot
    ) -> PasteboardReplacementResult {
        changeCount += 1
        return .written(changeCount: changeCount)
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        storedSnapshot = snapshot
        changeCount += 1
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.yorozu.app", category: "lifecycle")

    private lazy var environment: AppEnvironment = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing")
            || arguments.contains("--ui-testing-settings") {
            let runID = value(after: "--ui-testing-run-id", in: arguments)
                ?? UUID().uuidString
            do {
                return try AppEnvironment.uiTesting(runID: runID)
            } catch {
                logger.error("UI test environment initialization failed")
                preconditionFailure(
                    "Yorozu will not fall back to production dependencies during UI tests"
                )
            }
        }
        return AppEnvironment.production()
    }()
    private lazy var storeOpenResult = environment.storeOpenResult
    private lazy var store: LauncherStore? = storeOpenResult.store

    private lazy var catalog = ApplicationCatalog(
        store: store,
        discoverer: environment.discoverer
    )
    private lazy var featureCatalog = FeatureCommandCatalog(store: store)
    private lazy var clipboardCatalog = ClipboardCatalog(store: store)
    private lazy var snippetCatalog = SnippetCatalog(store: store)
    private lazy var clipboardPreferences = ClipboardPreferences(
        defaults: environment.defaults
    )
    private lazy var urlPreviewService = URLPreviewService(
        store: store,
        networkEnabled: environment.allowsURLPreviewNetwork
    )

    lazy var viewModel = LauncherViewModel(
        catalog: catalog,
        featureCatalog: featureCatalog,
        clipboardCatalog: clipboardCatalog,
        snippetCatalog: snippetCatalog,
        clipboardPreferences: clipboardPreferences,
        urlPreviewService: urlPreviewService,
        shortcutSettings: AppShortcutSettings(
            usesIsolatedStorage: environment.isolatesShortcutSettings
        ),
        launcher: environment.launcher,
        storageRecoveryNotice: storeOpenResult.recoveryNotice
    )

    private lazy var clipboardMonitor = ClipboardMonitor(
        reader: SystemPasteboardReader(),
        settings: clipboardPreferences.recordingSettings,
        catalog: clipboardCatalog,
        onSnapshot: { [weak self] snapshot in
            self?.viewModel.handleClipboardSnapshot(snapshot)
        }
    )
    private lazy var pasteCoordinator: PasteCoordinator = {
        guard !environment.usesLivePasteIntegration else {
            return PasteCoordinator(monitor: clipboardMonitor)
        }
        return PasteCoordinator(
            pasteboard: UITestPasteboard(),
            suppressClipboardMonitor: { _ in },
            dependencies: PasteCoordinatorDependencies(
                isAccessibilityTrusted: { false },
                postPasteShortcut: { false },
                sleep: { _ in },
                activationPollInterval: .zero,
                activationPollAttempts: 0,
                activationGracePeriod: .zero,
                restorationDelay: .zero
            )
        )
    }()
    private lazy var paletteController = PaletteWindowController(
        viewModel: viewModel,
        pasteCoordinator: pasteCoordinator
    )
    private var menuBarController: MenuBarController?
    private var terminationCleanupStarted = false
    private var terminationCleanupCompleted = false

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

        if environment.registersGlobalShortcuts {
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
        }

        viewModel.start()
        clipboardPreferences.recordingSettingsDidChange = { [weak self] settings in
            guard let self else { return }
            Task {
                await self.clipboardMonitor.update(settings: settings)
            }
        }
        if environment.startsClipboardMonitor {
            Task {
                await clipboardMonitor.start()
            }
        }

        #if DEBUG
        if arguments.contains("--performance-testing-clipboard-interaction") {
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                let report = await paletteController.runClipboardInteractionStressTest()
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(report)
                    try data.write(
                        to: URL(
                            fileURLWithPath:
                                "/private/tmp/yorozu-clipboard-interaction-performance.json"
                        ),
                        options: .atomic
                    )
                    logger.notice(
                        "Clipboard interaction stress test completed: route p95 \(report.rootToClipboard.p95Milliseconds, privacy: .public) ms, selection p95 \(report.selectionMovement.p95Milliseconds, privacy: .public) ms, settled detail p95 \(report.settledDetailPresentation.p95Milliseconds, privacy: .public) ms"
                    )
                } catch {
                    logger.error(
                        "Clipboard interaction stress report failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                NSApp.terminate(nil)
            }
            return
        }

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationCleanupCompleted {
            return .terminateNow
        }
        guard !terminationCleanupStarted else {
            return .terminateCancel
        }
        terminationCleanupStarted = true
        viewModel.shutdown()
        let clipboardMonitor = self.clipboardMonitor
        let store = store
        let temporaryDirectory = environment.temporaryDirectory
        Task.detached(priority: .utility) {
            await clipboardMonitor.stop()
            try? await store?.close()
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.terminationCleanupCompleted = true
                NSApplication.shared.terminate(nil)
            }
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if environment.registersGlobalShortcuts {
            KeyboardShortcuts.disable(
                .toggleLauncher,
                .openClipboardHistory,
                .openSnippets,
                .openAliases
            )
        }
        paletteController.invalidate()
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
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
