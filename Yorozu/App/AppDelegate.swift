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
    let usesLiveAIIntegration: Bool
    let aiConversationFixtures: [AIConversationSummary]
    let registersGlobalShortcuts: Bool
    let isolatesShortcutSettings: Bool
    let monitorsApplicationDirectories: Bool
    let startsCommandInputModeSwitching: Bool

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
            usesLiveAIIntegration: true,
            aiConversationFixtures: [],
            registersGlobalShortcuts: true,
            isolatesShortcutSettings: false,
            monitorsApplicationDirectories: true,
            startsCommandInputModeSwitching: true
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
            usesLiveAIIntegration: false,
            aiConversationFixtures: [
                AIConversationSummary(
                    providerID: .codex,
                    providerConversationID: "conversation-ui-test",
                    title: "Welcome to Yorozu AI",
                    model: .terra,
                    isArchived: false,
                    deletionState: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    lastMessageAt: Date(timeIntervalSince1970: 1_700_000_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
            ],
            registersGlobalShortcuts: false,
            isolatesShortcutSettings: true,
            monitorsApplicationDirectories: false,
            startsCommandInputModeSwitching: false
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

private actor UITestOpenAIChatService: OpenAIChatServing {
    func availableModelIDs(apiKey: String) -> Set<String> {
        Set(AIModel.openAIModels.map(\.rawValue))
    }

    func createConversation(
        apiKey: String,
        title: String,
        model: AIModel
    ) -> String {
        "conversation-ui-created"
    }

    func updateConversation(
        apiKey: String,
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) {}

    func loadConversation(
        apiKey: String,
        conversationID: String,
        limit: Int,
        after: String?
    ) -> AIConversationPage {
        AIConversationPage(
            messages: [
                AIChatMessage(
                    id: "message-ui-user-1",
                    role: .user,
                    text: "How can I keep Yorozu fast?",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
                AIChatMessage(
                    id: "message-ui-assistant-1",
                    role: .assistant,
                    text: """
                    Keep the launch path local.
                    Cache searchable snapshots in memory.

                    - Move network work away from selection changes.
                    - Keep database work off the launch path.
                    """,
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
                AIChatMessage(
                    id: "message-ui-user-2",
                    role: .user,
                    text: "What should I measure?",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
                AIChatMessage(
                    id: "message-ui-assistant-2",
                    role: .assistant,
                    text: "Track warm palette presentation, route transitions, keyboard selection latency, idle CPU, and resident memory. Measure multiple independent runs before comparing changes.",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
                AIChatMessage(
                    id: "message-ui-user-3",
                    role: .user,
                    text: "How should the UI behave?",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
                AIChatMessage(
                    id: "message-ui-assistant-3",
                    role: .assistant,
                    text: "Keep keyboard navigation immediate, make every primary action mouse-accessible, and avoid rebuilding the result hierarchy during route changes.",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
                AIChatMessage(
                    id: "message-ui-user-4",
                    role: .user,
                    text: "And for long-running work?",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
                AIChatMessage(
                    id: "message-ui-assistant-4",
                    role: .assistant,
                    text: "Cancel stale searches and previews, coalesce streaming updates, and keep bounded caches so long sessions stay responsive.",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
            ],
            nextCursor: nil,
            hasMore: false
        )
    }

    func uploadAttachment(
        apiKey: String,
        attachment: AIChatAttachment
    ) throws -> AIUploadedAttachment {
        throw AIChatError.invalidAttachment
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.responseCreated("response-ui-test"))
            continuation.yield(.textDelta("Yorozu AI is ready."))
            continuation.yield(.completed)
            continuation.finish()
        }
    }

    func deleteConversationCompletely(
        apiKey: String,
        conversationID: String
    ) {}
}

private actor UITestAIChatProvider: AIChatProvider, OpenAIAPIKeyManaging {
    nonisolated let descriptor: AIProviderDescriptor
    private let service = UITestOpenAIChatService()
    private var apiKey: String? = "ui-test-key"

    init(providerID: AIProviderID) {
        let isCodex = providerID == .codex
        let isClaude = providerID == .claude
        let isOllama = providerID == .ollama
        descriptor = AIProviderDescriptor(
            id: providerID,
            displayName: isCodex
                ? "Codex"
                : (isClaude ? "Claude" : (isOllama ? "Ollama" : "OpenAI API")),
            rootCommandTitle: isCodex
                ? "AI Chat: Codex"
                : (isClaude
                    ? "AI Chat: Claude"
                    : (isOllama ? "AI Chat: Ollama" : "AI Chat: OpenAI")),
            description: isOllama ? "Local UI test provider" : "UI test provider",
            symbolName: isCodex
                ? "terminal"
                : (isClaude
                    ? "bubble.left.and.bubble.right"
                    : (isOllama ? "server.rack" : "sparkles")),
            capabilities: isOllama
                ? [
                    .modelSelection, .streaming, .archive,
                    .deletion, .translation,
                ]
                : (isCodex
                ? [
                    .authentication, .modelSelection, .reasoningEffort,
                    .streaming, .archive, .deletion, .translation,
                ]
                : (isClaude
                    ? [
                        .authentication, .modelSelection, .streaming,
                        .archive, .deletion, .translation,
                    ]
                    : [
                    .authentication, .modelSelection, .streaming,
                    .archive, .deletion, .translation,
                    ]))
        )
    }

    func availability() -> AIProviderAvailability { .available }
    func authenticationState() -> AIAuthenticationState {
        apiKey == nil
            ? .authenticationRequired
            : .authenticated(detail: "Test account")
    }
    func availableModels() -> [AIModel] {
        if descriptor.id == .claude { return AIModel.claudeModels }
        if descriptor.id == .ollama { return AIModel.ollamaModels }
        guard descriptor.id == .codex else { return AIModel.openAIModels }
        let efforts = ["low", "medium", "high"].map {
            AIReasoningEffort(rawValue: $0)
        }
        let lowEffort = AIReasoningEffort(rawValue: "low")
        return [
            AIModel(
                rawValue: "codex-ui-model",
                title: "Codex UI Model",
                detail: "UI test model",
                isDefault: true,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: efforts[1]
            ),
            AIModel(
                rawValue: "codex-ui-fast",
                title: "Codex UI Fast",
                detail: "Fast UI test model",
                isDefault: false,
                supportedReasoningEfforts: [lowEffort],
                defaultReasoningEffort: lowEffort
            ),
        ]
    }
    func createConversation(title: String, model: AIModel) async throws -> String {
        try await service.createConversation(apiKey: "ui-test-key", title: title, model: model)
    }
    func updateConversation(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        try await service.updateConversation(
            apiKey: "ui-test-key",
            conversationID: conversationID,
            title: title,
            model: model,
            isArchived: isArchived
        )
    }
    func loadConversation(
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage {
        try await service.loadConversation(
            apiKey: "ui-test-key",
            conversationID: conversationID,
            limit: limit,
            after: after
        )
    }
    func uploadAttachment(_ attachment: AIChatAttachment) async throws -> AIUploadedAttachment {
        throw AIChatError.invalidAttachment
    }
    nonisolated func streamResponse(
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        UITestOpenAIChatService().streamResponse(apiKey: "ui-test-key", request: request)
    }
    nonisolated func streamTranslation(
        request: AITranslationRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.responseCreated("ui-translation"))
            continuation.yield(.textDelta("UI test translation"))
            continuation.yield(.completed)
            continuation.finish()
        }
    }
    func stopGeneration(conversationID: String) async {}
    func deleteConversationCompletely(conversationID: String) async throws {}
    func shutdown() async {}
    func hasAPIKey() async throws -> Bool { apiKey != nil }
    func saveAPIKey(_ value: String) async throws { apiKey = value }
    func removeAPIKey() async throws { apiKey = nil }
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
    private lazy var commandInputModeController: CommandInputModeController = {
        if environment.startsCommandInputModeSwitching {
            return .live(defaults: environment.defaults)
        }
        return .disabled(defaults: environment.defaults)
    }()
    private lazy var urlPreviewService = URLPreviewService(
        store: store,
        networkEnabled: environment.allowsURLPreviewNetwork
    )
    private lazy var aiProviderPreferences = AIProviderPreferences(defaults: environment.defaults)
    private lazy var codexAIChatPreferences = AIChatPreferences(
        defaults: environment.defaults,
        providerID: .codex
    )
    private lazy var openAIAIChatPreferences = AIChatPreferences(
        defaults: environment.defaults,
        providerID: .openAIAPI
    )
    private lazy var claudeAIChatPreferences = AIChatPreferences(
        defaults: environment.defaults,
        providerID: .claude,
        fallbackModel: AIModel.claudeSonnet
    )
    private lazy var ollamaAIChatPreferences = AIChatPreferences(
        defaults: environment.defaults,
        providerID: .ollama,
        fallbackModel: AIModel.ollamaDefault
    )
    private lazy var translationPreferences = TranslationPreferences(
        defaults: environment.defaults
    )
    private lazy var aiCredentials: any OpenAICredentialStoring = {
        let usesLiveAIIntegration = environment.usesLiveAIIntegration
        return DeferredOpenAICredentialStore {
            if usesLiveAIIntegration {
                return KeychainOpenAICredentialStore()
            }
            return InMemoryOpenAICredentialStore(value: "ui-test-key")
        }
    }()
    private lazy var aiService: any OpenAIChatServing = {
        let usesLiveAIIntegration = environment.usesLiveAIIntegration
        return DeferredOpenAIChatService {
            if usesLiveAIIntegration {
                return OpenAIChatClient()
            }
            return UITestOpenAIChatService()
        }
    }()
    private lazy var openAIProvider: any AIChatProvider = OpenAIAPIProvider(
        service: aiService,
        credentials: aiCredentials
    )
    private lazy var claudeCredentials: any OpenAICredentialStoring = {
        let usesLiveAIIntegration = environment.usesLiveAIIntegration
        return DeferredOpenAICredentialStore {
            if usesLiveAIIntegration {
                return KeychainClaudeCredentialStore()
            }
            return InMemoryOpenAICredentialStore(value: "ui-test-key")
        }
    }()
    private lazy var claudeService: any ClaudeChatServing = {
        let usesLiveAIIntegration = environment.usesLiveAIIntegration
        return DeferredClaudeChatService {
            if usesLiveAIIntegration {
                return ClaudeChatClient()
            }
            return DisabledClaudeChatService()
        }
    }()
    private lazy var claudeProvider: any AIChatProvider = ClaudeAPIProvider(
        service: claudeService,
        credentials: claudeCredentials
    )
    private lazy var ollamaService: any OllamaChatServing = OllamaChatClient()
    private lazy var ollamaProvider: any AIChatProvider = OllamaAIProvider(
        service: ollamaService
    )
    private lazy var codexProvider: any AIChatProvider = {
        if environment.usesLiveAIIntegration {
            return CodexAIProvider(
                configuredExecutablePath: aiProviderPreferences.codexExecutablePath
            )
        }
        return UITestAIChatProvider(providerID: .codex)
    }()
    private lazy var openAIChatViewModel = AIChatViewModel(
        catalog: AIConversationCatalog(
            providerID: .openAIAPI,
            store: store,
            initialConversations: environment.aiConversationFixtures
        ),
        provider: environment.usesLiveAIIntegration
            ? openAIProvider
            : UITestAIChatProvider(providerID: .openAIAPI),
        preferences: openAIAIChatPreferences
    )
    private lazy var codexChatViewModel = AIChatViewModel(
        catalog: AIConversationCatalog(
            providerID: .codex,
            store: store,
            initialConversations: environment.aiConversationFixtures
        ),
        provider: codexProvider,
        preferences: codexAIChatPreferences
    )
    private lazy var claudeChatViewModel = AIChatViewModel(
        catalog: AIConversationCatalog(
            providerID: .claude,
            store: store,
            initialConversations: environment.aiConversationFixtures
        ),
        provider: environment.usesLiveAIIntegration
            ? claudeProvider
            : UITestAIChatProvider(providerID: .claude),
        preferences: claudeAIChatPreferences
    )
    private lazy var ollamaChatViewModel = AIChatViewModel(
        catalog: AIConversationCatalog(
            providerID: .ollama,
            store: store,
            initialConversations: environment.aiConversationFixtures
        ),
        provider: environment.usesLiveAIIntegration
            ? ollamaProvider
            : UITestAIChatProvider(providerID: .ollama),
        preferences: ollamaAIChatPreferences
    )
    private lazy var aiChatViewModelStore = AIChatViewModelStore(
        viewModels: [
            codexChatViewModel,
            openAIChatViewModel,
            claudeChatViewModel,
            ollamaChatViewModel,
        ],
        providerPreferences: aiProviderPreferences
    )

    lazy var viewModel = LauncherViewModel(
        catalog: catalog,
        featureCatalog: featureCatalog,
        clipboardCatalog: clipboardCatalog,
        snippetCatalog: snippetCatalog,
        clipboardPreferences: clipboardPreferences,
        commandInputModeController: commandInputModeController,
        urlPreviewService: urlPreviewService,
        shortcutSettings: AppShortcutSettings(
            usesIsolatedStorage: environment.isolatesShortcutSettings
        ),
        aiChatViewModelStore: aiChatViewModelStore,
        translationPreferences: translationPreferences,
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
    private var applicationDirectoryMonitor: ApplicationDirectoryMonitor?
    private var automaticReindexTask: Task<Void, Never>?
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
            KeyboardShortcuts.onKeyUp(for: .openAIChat) { [weak self] in
                guard let self,
                      let providerID = self.aiProviderPreferences.defaultProviderID else {
                    return
                }
                self.paletteController.toggle(route: .ai(providerID: providerID))
            }
        }

        viewModel.start()
        startApplicationDirectoryMonitorIfNeeded()
        if let store, !aiProviderPreferences.isEnabled(.openAIAPI) {
            Task { @MainActor [weak self] in
                guard let self,
                      let conversations = try? await store.loadAIConversationIndex(
                          providerID: .openAIAPI
                      ),
                      !conversations.isEmpty else {
                    return
                }
                self.aiProviderPreferences.enableOpenAIForLegacyCredential()
            }
        }
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
        if environment.startsCommandInputModeSwitching {
            commandInputModeController.start()
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

    func applicationDidBecomeActive(_ notification: Notification) {
        commandInputModeController.refreshAuthorization()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Reconcile once AppKit has completed the foreground transition. The
        // Command-key service is process-scoped and must remain active when the
        // settings panel or palette is no longer visible.
        DispatchQueue.main.async { [weak self] in
            self?.commandInputModeController.refreshAuthorization()
        }
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
        automaticReindexTask?.cancel()
        automaticReindexTask = nil
        applicationDirectoryMonitor?.stop()
        applicationDirectoryMonitor = nil
        commandInputModeController.stop()
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
        commandInputModeController.stop()
        if environment.registersGlobalShortcuts {
            KeyboardShortcuts.disable(
                .toggleLauncher,
                .openClipboardHistory,
                .openSnippets,
                .openAliases,
                .openAIChat
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

    private func startApplicationDirectoryMonitorIfNeeded() {
        guard environment.monitorsApplicationDirectories,
              applicationDirectoryMonitor == nil else {
            return
        }

        let monitor = ApplicationDirectoryMonitor { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleAutomaticReindex()
            }
        }
        guard monitor.start() else {
            logger.error("Application directory monitoring could not be started")
            return
        }
        applicationDirectoryMonitor = monitor
    }

    private func scheduleAutomaticReindex() {
        automaticReindexTask?.cancel()
        automaticReindexTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.viewModel.reindex()
        }
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
