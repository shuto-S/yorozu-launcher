import AppKit
import Foundation
import ImageIO
import Observation
import os
import SwiftUI

enum LauncherActionID: String, CaseIterable, Identifiable {
    case open
    case paste
    case copy
    case copyCalculationExpression
    case togglePin
    case editAlias
    case deleteAlias
    case reveal
    case editSnippet
    case duplicateSnippet
    case delete
    case aiOpenChat
    case aiOpenInCodex
    case aiNewChat
    case translationChangeLanguage
    case translationLanguage1
    case translationLanguage2
    case translationLanguage3
    case translationLanguage4
    case translationLanguage5
    case translationLanguage6
    case translationLanguage7
    case translationLanguage8
    case translationLanguage9
    case translationLanguage10
    case translationLanguage11
    case translationLanguage12
    case translationChangeProvider
    case translationProvider1
    case translationProvider2
    case translationProvider3
    case translationProvider4
    case aiChangeModel
    case aiChangeReasoning
    case aiModelTerra
    case aiModelSol
    case aiModelLuna
    case aiModel4
    case aiModel5
    case aiModel6
    case aiModel7
    case aiModel8
    case aiModel9
    case aiModel10
    case aiReasoning1
    case aiReasoning2
    case aiReasoning3
    case aiReasoning4
    case aiReasoning5
    case aiReasoning6
    case aiReasoning7
    case aiReasoning8
    case aiReasoning9
    case aiReasoning10
    case aiToggleWebSearch
    case aiAttachFiles
    case aiArchive
    case aiDelete
    case aiToggleArchiveScope
    case aiCopyLastResponse
    case aiStopGenerating

    var id: Self { self }
}

struct LauncherActionItem: Identifiable, Equatable {
    let id: LauncherActionID
    let title: String
    let symbolName: String
    let shortcutGlyphs: [String]
    var role: ButtonRole?
}

enum LauncherFooterActionID: String, Identifiable {
    case primary
    case copy
    case newSnippet
    case addAlias
    case actions

    var id: Self { self }
}

struct LauncherFooterAction: Identifiable, Equatable {
    let id: LauncherFooterActionID
    let shortcut: String
    let title: String
}

enum AliasEditorMode: Equatable {
    case selectingApplication
    case editing(ApplicationIdentity)
}

enum SnippetEditorMode: Equatable {
    case new
    case editing(UUID)
}

enum PaletteConfirmation: Equatable {
    case deleteClipboard(UUID)
    case deleteSnippet(UUID)
    case deleteAlias(ApplicationIdentity)
    case deleteAIConversation(AIConversationReference)
    case clearClipboardHistory(includePinned: Bool)
    case codexSignOut
    case removeOpenAIAPIKey
    case removeClaudeAPIKey
}

enum PaletteModal: Equatable {
    case snippetEditor(SnippetEditorMode)
    case aliasApplicationPicker
    case aliasEditor(ApplicationIdentity)
    case openAIAPIKey
    case claudeAPIKey
    case codexExecutablePath
    case confirmation(PaletteConfirmation)
}

@MainActor
@Observable
final class LauncherViewModel {
    var query = "" {
        didSet {
            guard query != oldValue, !isApplyingRouteState else { return }
            refreshSearch(preserveSelection: false)
        }
    }

    private(set) var route: PaletteRoute = .root
    private(set) var presentationOrigin: PalettePresentationOrigin = .direct
    private(set) var results: [CommandResult] = []
    private(set) var resultsRevision = 0
    var selectedID: CommandResultID? {
        didSet {
            guard selectedID != oldValue, !isApplyingRouteState else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            detailSelectionStartedAt = startedAt
            LauncherPerformanceTrace.duration(
                "detail_placeholder",
                startedAt: startedAt
            )
            if route == .clipboard
                || selectedClipboardImage != nil
                || isClipboardImageLoading {
                loadSelectedClipboardImage()
            }
            if route != .clipboard || selectedClipboardItem?.kind != .image {
                LauncherPerformanceTrace.duration(
                    "detail_content_ready",
                    startedAt: startedAt
                )
            }
        }
    }
    private(set) var isIndexing = false
    private(set) var indexCount = 0
    private(set) var lastIndexedAt: Date?
    private(set) var storageAvailable = true
    private(set) var installedApplications: [LaunchableApplication] = []
    private(set) var featureCommands: [FeatureCommandState] = []
    @ObservationIgnored private(set) var clipboardItems: [ClipboardItem] = []
    @ObservationIgnored private(set) var snippets: [Snippet] = []
    private(set) var clipboardItemCount = 0
    private(set) var snippetCount = 0
    private(set) var selectedClipboardImage: CGImage?
    private(set) var isClipboardImageLoading = false
    var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var storageRecoveryNotice: StorageRecoveryNotice?
    private(set) var focusRequest = 0
    private(set) var isActionPanelPresented = false
    private(set) var paletteModal: PaletteModal?
    private(set) var isModalProcessing = false
    private(set) var modalFocusRequest = 0
    var modalErrorMessage: String?
    var snippetNameDraft = ""
    var snippetKeywordDraft = ""
    var snippetContentDraft = ""
    var openAIAPIKeyDraft = ""
    var claudeAPIKeyDraft = ""
    var codexExecutablePathDraft = ""
    var actionQuery = "" {
        didSet {
            guard actionQuery != oldValue else { return }
            reconcileActionSelection()
        }
    }
    var selectedActionID: LauncherActionID?
    private(set) var aliasEditorMode: AliasEditorMode?
    var aliasDraft = "" {
        didSet {
            if aliasValidationMessage != nil {
                aliasValidationMessage = nil
            }
        }
    }
    var aliasApplicationQuery = "" {
        didSet {
            guard aliasApplicationQuery != oldValue,
                  aliasEditorMode == .selectingApplication else {
                return
            }
            reconcileAliasApplicationSelection()
        }
    }
    var selectedAliasApplicationID: ApplicationIdentity?
    private(set) var aliasValidationMessage: String?
    private(set) var isSavingAlias = false
    private(set) var aliasFocusRequest = 0

    var dismissForLaunch: (() -> Void)?
    var reopenAfterLaunchFailure: (() -> Void)?
    var dismissAndRestorePreviousApplication: (() -> Void)?
    var selectedTextForTranslation: (() -> String?)?
    var selectedTextPermissionUnavailableForTranslation: (() -> Bool)?
    var pasteContent: ((
        PasteboardContent,
        @escaping @MainActor (PasteResult) -> Void
    ) -> Void)?
    var copyContent: ((PasteboardContent) async -> PasteboardReplacementResult)?

    let clipboardPreferences: ClipboardPreferences
    let urlPreviewService: URLPreviewService
    let shortcutSettings: AppShortcutSettings
    let aiChatViewModelStore: AIChatViewModelStore
    let translationViewModel: TranslationViewModel

    var aiProviderPreferences: AIProviderPreferences {
        aiChatViewModelStore.providerPreferences
    }

    var aiChatViewModel: AIChatViewModel {
        if let providerID = route.aiProviderID,
           let value = aiChatViewModelStore.viewModel(for: providerID) {
            return value
        }
        return aiChatViewModelStore.defaultViewModel() ?? .disabled()
    }

    func aiChatViewModel(for providerID: AIProviderID) -> AIChatViewModel? {
        aiChatViewModelStore.viewModel(for: providerID)
    }

    var aiProviderViewModels: [AIChatViewModel] {
        aiChatViewModelStore.orderedViewModels
    }

    func resolvedAISettingsProviderID(
        preferred providerID: AIProviderID?
    ) -> AIProviderID? {
        aiChatViewModelStore.resolvedProviderID(preferred: providerID)
    }

    private let catalog: ApplicationCatalog
    private let featureCatalog: FeatureCommandCatalog
    private let clipboardCatalog: ClipboardCatalog
    private let snippetCatalog: SnippetCatalog
    private let launcher: any ApplicationLaunching
    private var searchRevision = 0
    private var searchTask: Task<Void, Never>?
    private var clipboardImageLoadTask: Task<Void, Never>?
    private var startupTasks: [Task<Void, Never>] = []
    private var clipboardImageGeneration = 0
    private let clipboardImageDecoder: any ClipboardImageDecoding
    @ObservationIgnored private let clipboardImageCache = NSCache<NSUUID, CGImage>()
    private var detailSelectionStartedAt: TimeInterval?
    private var rootDefaultResults: [CommandResult] = []
    private var clipboardDefaultResults: [CommandResult] = []
    private var snippetDefaultResults: [CommandResult] = []
    @ObservationIgnored private var resultIndexByID: [CommandResultID: Int] = [:]
    @ObservationIgnored private var clipboardItemByID: [UUID: ClipboardItem] = [:]
    @ObservationIgnored private var snippetByID: [UUID: Snippet] = [:]
    private var selectionByRoute: [PaletteRoute: CommandResultID] = [:]
    private var isApplyingRouteState = false
    private var hasStarted = false
    private var reindexRequestedWhileIndexing = false
    private let logger = Logger(subsystem: "com.yorozu.app", category: "launcher")

    init(
        catalog: ApplicationCatalog,
        featureCatalog: FeatureCommandCatalog,
        clipboardCatalog: ClipboardCatalog,
        snippetCatalog: SnippetCatalog,
        clipboardPreferences: ClipboardPreferences,
        urlPreviewService: URLPreviewService,
        shortcutSettings: AppShortcutSettings = AppShortcutSettings(),
        aiChatViewModel: AIChatViewModel? = nil,
        aiChatViewModelStore: AIChatViewModelStore? = nil,
        translationPreferences: TranslationPreferences? = nil,
        launcher: any ApplicationLaunching,
        clipboardImageDecoder: any ClipboardImageDecoding = ClipboardImageDecoder(),
        storageRecoveryNotice: StorageRecoveryNotice? = nil
    ) {
        self.catalog = catalog
        self.featureCatalog = featureCatalog
        self.clipboardCatalog = clipboardCatalog
        self.snippetCatalog = snippetCatalog
        self.clipboardPreferences = clipboardPreferences
        self.urlPreviewService = urlPreviewService
        self.shortcutSettings = shortcutSettings
        let resolvedAIStore: AIChatViewModelStore
        if let aiChatViewModelStore {
            resolvedAIStore = aiChatViewModelStore
        } else {
            let value = aiChatViewModel ?? .disabled()
            let suite = UserDefaults(
                suiteName: "com.yorozu.app.ai-provider-fallback.\(UUID().uuidString)"
            ) ?? .standard
            resolvedAIStore = AIChatViewModelStore(
                viewModels: [value],
                providerPreferences: AIProviderPreferences(defaults: suite)
            )
        }
        self.aiChatViewModelStore = resolvedAIStore
        let resolvedTranslationPreferences = translationPreferences ?? TranslationPreferences(
            defaults: UserDefaults(
                suiteName: "com.yorozu.app.translation-fallback.\(UUID().uuidString)"
            ) ?? .standard
        )
        self.translationViewModel = TranslationViewModel(
            providerStore: resolvedAIStore,
            preferences: resolvedTranslationPreferences
        )
        self.launcher = launcher
        self.clipboardImageDecoder = clipboardImageDecoder
        self.storageRecoveryNotice = storageRecoveryNotice
        clipboardImageCache.countLimit = 8
        clipboardImageCache.totalCostLimit = 32 * 1_024 * 1_024
        self.aiProviderPreferences.didChange = { [weak self] in
            self?.handleAIProviderPreferencesChange()
        }
    }

    var selectedResult: CommandResult? {
        guard let selectedID,
              let index = resultIndexByID[selectedID],
              results.indices.contains(index) else {
            return nil
        }
        return results[index]
    }

    var selectedApplication: LaunchableApplication? {
        guard case let .application(application) = selectedResult?.payload else { return nil }
        return application
    }

    var selectedClipboardItem: ClipboardItem? {
        guard case let .clipboard(id) = selectedResult?.payload else { return nil }
        return clipboardItemByID[id]
    }

    var selectedSnippet: Snippet? {
        guard case let .snippet(id) = selectedResult?.payload else { return nil }
        return snippetByID[id]
    }

    func resultIndex(for id: CommandResultID) -> Int? {
        resultIndexByID[id]
    }

    var aliasEditingApplication: LaunchableApplication? {
        guard case let .editing(identity) = aliasEditorMode else { return nil }
        return installedApplications.first(where: { $0.id == identity })
    }

    var aliasApplicationCandidates: [LaunchableApplication] {
        let trimmedQuery = aliasApplicationQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmedQuery.isEmpty {
            return installedApplications.sorted {
                $0.primaryName.localizedStandardCompare($1.primaryName)
                    == .orderedAscending
            }
        }
        return SearchScorer.rank(
            applications: installedApplications,
            query: trimmedQuery,
            limit: installedApplications.count
        )
    }

    var isModalPresented: Bool {
        paletteModal != nil
    }

    var modalSnippet: Snippet? {
        guard case let .snippetEditor(.editing(id)) = paletteModal else { return nil }
        return snippetByID[id]
    }

    var modalConfirmationTitle: String {
        guard case let .confirmation(confirmation) = paletteModal else { return "" }
        switch confirmation {
        case .deleteClipboard:
            return "Delete Clipboard Item?"
        case .deleteSnippet:
            return "Delete Snippet?"
        case .deleteAlias:
            return "Delete Alias?"
        case .deleteAIConversation:
            return "Delete Chat?"
        case let .clearClipboardHistory(includePinned):
            return includePinned ? "Clear All Clipboard History?" : "Clear Clipboard History?"
        case .codexSignOut:
            return "Sign Out of ChatGPT?"
        case .removeOpenAIAPIKey:
            return "Remove OpenAI API Key?"
        case .removeClaudeAPIKey:
            return "Remove Anthropic API Key?"
        }
    }

    var modalConfirmationMessage: String {
        guard case let .confirmation(confirmation) = paletteModal else { return "" }
        switch confirmation {
        case .deleteClipboard:
            return "This item will be permanently removed from clipboard history."
        case let .deleteSnippet(id):
            let name = snippetByID[id]?.name ?? "This snippet"
            return "\u{201c}\(name)\u{201d} will be permanently deleted."
        case let .deleteAlias(identity):
            let name = installedApplications.first(where: { $0.id == identity })?.primaryName
                ?? "this application"
            return "The alias for \(name) will be removed. The application and its usage history will not be affected."
        case .deleteAIConversation:
            return "The chat and its provider conversation items will be permanently deleted."
        case let .clearClipboardHistory(includePinned):
            return includePinned
                ? "Pinned items will also be permanently deleted."
                : "Pinned items will be kept."
        case .codexSignOut:
            return "Yorozu will stop using your ChatGPT account until you sign in again."
        case .removeOpenAIAPIKey:
            return "The saved key will be removed from macOS Keychain."
        case .removeClaudeAPIKey:
            return "The saved Anthropic key will be removed from macOS Keychain."
        }
    }

    var modalConfirmationActionTitle: String {
        guard case let .confirmation(confirmation) = paletteModal else { return "" }
        switch confirmation {
        case .deleteClipboard, .deleteSnippet, .deleteAlias, .deleteAIConversation:
            return "Delete"
        case let .clearClipboardHistory(includePinned):
            return includePinned ? "Clear All" : "Clear History"
        case .codexSignOut:
            return "Sign Out"
        case .removeOpenAIAPIKey:
            return "Remove Key"
        case .removeClaudeAPIKey:
            return "Remove Key"
        }
    }

    var actionPanelTitle: String {
        if route == .translation {
            return translationViewModel.actionPanelTitle
        }
        if route.isAI {
            return aiChatViewModel.actionPanelTitle
        }
        return selectedResult?.title ?? ""
    }

    var searchPlaceholder: String {
        route.searchPlaceholder
    }

    var searchAccessibilityLabel: String {
        route.searchAccessibilityLabel
    }

    var emptyStateTitle: String {
        switch route {
        case .root:
            isIndexing ? "Indexing Applications…" : "No Results"
        case .translation:
            "Translate"
        case .clipboard:
            clipboardPreferences.isEnabled
                ? "No Clipboard Items"
                : "Clipboard History Is Off"
        case .snippets:
            "No Snippets"
        case .aliases:
            query.isEmpty ? "No Aliases Yet" : "No Matching Aliases"
        case .ai:
            "No Chats Yet"
        case .settings:
            "Settings"
        }
    }

    var emptyStateSymbol: String {
        switch route {
        case .root:
            isIndexing ? "arrow.trianglehead.2.clockwise.rotate.90" : "magnifyingglass"
        case .translation:
            "character.bubble"
        case .clipboard:
            "clipboard"
        case .snippets:
            "text.quote"
        case .aliases:
            "character.cursor.ibeam"
        case .ai:
            "bubble.left.and.bubble.right"
        case .settings:
            "gearshape"
        }
    }

    var footerText: String {
        if let statusMessage {
            return statusMessage
        }
        switch route {
        case .root:
            return "\(indexCount) apps"
        case .translation:
            return "Translation"
        case .clipboard:
            return "\(clipboardItemCount) items"
        case .snippets:
            return "\(snippetCount) snippets"
        case .aliases:
            let count = installedApplications.lazy.filter {
                $0.preference.alias?.isEmpty == false
            }.count
            return "\(count) aliases"
        case .ai:
            return "AI Chat"
        case .settings:
            return "Settings"
        }
    }

    var footerActions: [LauncherFooterAction] {
        switch route {
        case .root:
            if isCalculationErrorSelected {
                return [
                    LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
                ]
            }
            return [
                LauncherFooterAction(
                    id: .primary,
                    shortcut: "↩",
                    title: isCalculationSelected ? "Copy" : "Open"
                ),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .translation:
            return []
        case .clipboard:
            return [
                LauncherFooterAction(id: .primary, shortcut: "↩", title: "Paste"),
                LauncherFooterAction(id: .copy, shortcut: "⌘↩", title: "Copy"),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .snippets:
            return [
                LauncherFooterAction(id: .primary, shortcut: "↩", title: "Paste"),
                LauncherFooterAction(id: .newSnippet, shortcut: "⌘N", title: "New"),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .aliases:
            return [
                LauncherFooterAction(id: .primary, shortcut: "↩", title: "Open"),
                LauncherFooterAction(id: .addAlias, shortcut: "⌘N", title: "Add Alias"),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .ai:
            return []
        case .settings:
            return []
        }
    }

    private var isCalculationSelected: Bool {
        if case .calculation = selectedResult?.payload {
            return true
        }
        return false
    }

    private var isCalculationErrorSelected: Bool {
        if case .calculationError = selectedResult?.payload {
            return true
        }
        return false
    }

    func isFooterActionEnabled(_ action: LauncherFooterActionID) -> Bool {
        switch action {
        case .primary, .actions:
            selectedResult != nil
        case .copy:
            selectedClipboardItem != nil || selectedSnippet != nil
        case .newSnippet:
            route == .snippets
        case .addAlias:
            route == .aliases
        }
    }

    func performFooterAction(_ action: LauncherFooterActionID) {
        guard isFooterActionEnabled(action) else { return }
        switch action {
        case .primary:
            performPrimaryAction()
        case .copy:
            copySelected()
        case .newSnippet:
            newSnippet()
        case .addAlias:
            beginAddAlias()
        case .actions:
            showActionMenu()
        }
    }

    var actionItems: [LauncherActionItem] {
        if route == .translation {
            return translationViewModel.actionItems
        }
        if route.isAI {
            return aiChatViewModel.actionItems
        }
        guard let result = selectedResult else { return [] }
        switch result.payload {
        case let .application(application):
            if route == .aliases {
                return [
                    action(.open, "Open Application", "arrow.up.forward.app", ["↩"]),
                    action(
                        .editAlias,
                        "Edit Alias",
                        "character.cursor.ibeam",
                        ["⌘", "E"]
                    ),
                    action(
                        .deleteAlias,
                        "Delete Alias",
                        "trash",
                        ["⌘", "⌫"],
                        role: .destructive
                    ),
                    action(.reveal, "Show in Finder", "folder", ["⇧", "⌘", "F"]),
                ]
            }
            return [
                action(.open, "Open", "arrow.up.forward.app", ["↩"]),
                action(
                    .togglePin,
                    application.preference.isPinned ? "Unpin" : "Pin",
                    application.preference.isPinned ? "pin.slash" : "pin",
                    ["⌘", "P"]
                ),
                action(.editAlias, "Edit Alias", "character.cursor.ibeam", ["⌘", "E"]),
                action(.reveal, "Show in Finder", "folder", ["⇧", "⌘", "F"]),
            ]
        case .feature:
            return [
                action(.open, "Open", "arrow.right", ["↩"]),
            ]
        case .calculation:
            return [
                action(.copy, "Copy Result", "doc.on.doc", ["↩"]),
                action(
                    .copyCalculationExpression,
                    "Copy Expression",
                    "function",
                    []
                ),
            ]
        case .calculationError:
            return []
        case .clipboard:
            let isPinned = selectedClipboardItem?.isPinned == true
            return [
                action(.paste, "Paste", "doc.on.clipboard", ["↩"]),
                action(.copy, "Copy", "doc.on.doc", ["⌘", "↩"]),
                action(
                    .togglePin,
                    isPinned ? "Unpin" : "Pin",
                    isPinned ? "pin.slash" : "pin",
                    ["⌘", "P"]
                ),
                action(.delete, "Delete", "trash", ["⌘", "⌫"], role: .destructive),
            ]
        case .snippet:
            return [
                action(.paste, "Paste", "doc.on.clipboard", ["↩"]),
                action(.copy, "Copy", "doc.on.doc", ["⌘", "↩"]),
                action(.editSnippet, "Edit", "pencil", ["⌘", "E"]),
                action(.duplicateSnippet, "Duplicate", "plus.square.on.square", ["⌘", "D"]),
                action(.delete, "Delete", "trash", ["⌘", "⌫"], role: .destructive),
            ]
        }
    }

    var filteredActionItems: [LauncherActionItem] {
        let trimmedQuery = actionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return actionItems }
        return actionItems.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        startupTasks = [
            Task {
                let snapshot = await clipboardCatalog.load()
                guard !Task.isCancelled else { return }
                apply(clipboardSnapshot: snapshot)
                let settings = clipboardPreferences.recordingSettings
                let prunedSnapshot = await clipboardCatalog.prune(
                    retentionDays: settings.retentionDays,
                    maximumItems: settings.maximumItems
                )
                guard !Task.isCancelled else { return }
                apply(clipboardSnapshot: prunedSnapshot)
                if route == .clipboard {
                    refreshSearch(preserveSelection: true)
                }
            },
            Task {
                let snapshot = await snippetCatalog.load()
                guard !Task.isCancelled else { return }
                apply(snippetSnapshot: snapshot)
                if route == .snippets {
                    refreshSearch(preserveSelection: true)
                }
            },
            Task {
                let snapshot = await featureCatalog.load()
                guard !Task.isCancelled else { return }
                apply(featureSnapshot: snapshot)
                if route == .root {
                    refreshSearch(preserveSelection: true)
                }
            },
            Task {
                let cachedSnapshot = await catalog.loadCachedApplications()
                guard !Task.isCancelled else { return }
                apply(snapshot: cachedSnapshot)
                if route == .root || route == .aliases {
                    refreshSearch(preserveSelection: true)
                }
                await reindex()
            },
        ]
    }

    func shutdown() {
        dismissModal(restoreFocus: false)
        searchTask?.cancel()
        searchTask = nil
        clipboardImageLoadTask?.cancel()
        clipboardImageLoadTask = nil
        urlPreviewService.cancel(resetState: true)
        startupTasks.forEach { $0.cancel() }
        startupTasks.removeAll(keepingCapacity: false)
        aiChatViewModelStore.shutdown()
        translationViewModel.shutdown()
    }

    func prepareForPresentation(
        route: PaletteRoute = .root,
        origin: PalettePresentationOrigin = .direct,
        selectedText: String? = nil,
        selectedTextPermissionUnavailable: Bool = false
    ) {
        dismissActionPanel(restoreSearchFocus: false)
        dismissModal(restoreFocus: false)
        resetClipboardImagePreview()
        errorMessage = nil
        statusMessage = nil
        focusRequest += 1
        transitionRoute(
            to: route,
            origin: origin,
            resetsSelection: route == .root
        )
        if route.isAI {
            aiChatViewModel.prepareForPresentation()
        } else if route == .translation {
            translationViewModel.prepareForPresentation(
                initialText: selectedText ?? selectedTextForTranslation?(),
                selectionPermissionUnavailable: selectedTextPermissionUnavailable
                    || selectedTextPermissionUnavailableForTranslation?() == true
            )
        }
        if let feature = FeatureCommand(route: route) {
            recordFeatureUse(feature)
        }
    }

    func switchRouteFromShortcut(_ route: PaletteRoute) {
        prepareForPresentation(route: route, origin: .direct)
    }

    func handleClipboardSnapshot(_ snapshot: FeatureSnapshot<ClipboardItem>) {
        apply(clipboardSnapshot: snapshot)
        if route == .clipboard {
            refreshSearch(preserveSelection: true)
        }
    }

    func reindex() async {
        if isIndexing {
            reindexRequestedWhileIndexing = true
            return
        }

        repeat {
            reindexRequestedWhileIndexing = false
            isIndexing = true
            let state = await catalog.reindex()
            isIndexing = false
            apply(snapshot: state)
            refreshSearch()
        } while reindexRequestedWhileIndexing && !Task.isCancelled
    }

    func moveSelection(by delta: Int) {
        guard paletteModal == nil else { return }
        if route.isAI {
            aiChatViewModel.moveSelection(by: delta)
            return
        }
        if aliasEditorMode == .selectingApplication {
            moveAliasApplicationSelection(by: delta)
            return
        }
        guard !results.isEmpty else { return }
        let currentIndex = selectedID.flatMap { resultIndexByID[$0] } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), results.count - 1)
        selectedID = results[nextIndex].id
    }

    func performPrimaryAction() {
        guard paletteModal == nil else { return }
        if route.isAI {
            aiChatViewModel.performPrimaryAction()
            return
        }
        switch aliasEditorMode {
        case .selectingApplication:
            chooseSelectedAliasApplication()
            return
        case .editing:
            saveAlias()
            return
        case nil:
            break
        }
        guard let result = selectedResult else {
            if route == .snippets { newSnippet() }
            return
        }
        switch result.payload {
        case .application:
            openSelectedApplication()
        case let .feature(feature):
            openFeature(feature)
        case .calculation:
            copySelected()
        case .calculationError:
            return
        case .clipboard, .snippet:
            pasteSelected()
        }
    }

    func openSelectedApplication() {
        guard let application = selectedApplication else { return }
        dismissForLaunch?()

        Task {
            do {
                try await launcher.launch(application)
                apply(snapshot: await catalog.recordSuccessfulLaunch(identity: application.id))
            } catch {
                logger.error("Application launch failed")
                apply(snapshot: await catalog.remove(identity: application.id))
                errorMessage = LauncherError.applicationUnavailable(application.primaryName)
                    .localizedDescription
                refreshSearch()
                reopenAfterLaunchFailure?()
            }
        }
    }

    func openFeature(_ feature: FeatureCommand) {
        dismissActionPanel(restoreSearchFocus: false)
        recordFeatureUse(feature)
        resetClipboardImagePreview()
        statusMessage = nil
        focusRequest += 1
        transitionRoute(to: feature.route, origin: .root)
        if feature.route.isAI {
            aiChatViewModel.prepareForPresentation()
        } else if feature.route == .translation {
            translationViewModel.prepareForPresentation(
                initialText: selectedTextForTranslation?(),
                selectionPermissionUnavailable:
                    selectedTextPermissionUnavailableForTranslation?() == true
            )
        }
    }

    func openSettingsFromTranslation() {
        guard route == .translation else { return }
        dismissActionPanel(restoreSearchFocus: false)
        dismissModal(restoreFocus: false)
        resetClipboardImagePreview()
        statusMessage = nil
        focusRequest += 1
        transitionRoute(to: .settings, origin: presentationOrigin)
    }

    func togglePinForSelectedResult() {
        guard let result = selectedResult else { return }
        switch result.payload {
        case let .application(application):
            Task {
                apply(snapshot: await catalog.togglePin(identity: application.id))
                refreshSearch()
            }
        case let .clipboard(id):
            Task {
                apply(clipboardSnapshot: await clipboardCatalog.togglePin(id: id))
                refreshSearch()
            }
        case .feature, .calculation, .calculationError, .snippet:
            break
        }
    }

    func togglePinForSelectedApplication() {
        togglePinForSelectedResult()
    }

    func editAliasForSelectedApplication() {
        guard let application = selectedApplication else { return }
        dismissActionPanel(restoreSearchFocus: false)
        if route != .aliases {
            recordFeatureUse(.aliases)
            resetClipboardImagePreview()
            statusMessage = nil
            transitionRoute(to: .aliases, origin: .root)
        }
        beginEditingAlias(for: application)
    }

    func beginAddAlias() {
        guard route == .aliases else { return }
        dismissActionPanel(restoreSearchFocus: false)
        aliasEditorMode = .selectingApplication
        aliasApplicationQuery = ""
        selectedAliasApplicationID = aliasApplicationCandidates.first?.id
        aliasDraft = ""
        aliasValidationMessage = nil
        aliasFocusRequest += 1
        presentModal(.aliasApplicationPicker)
    }

    func beginEditingSelectedAlias() {
        guard let application = selectedApplication else { return }
        beginEditingAlias(for: application)
    }

    func chooseAliasApplication(_ identity: ApplicationIdentity) {
        guard aliasEditorMode == .selectingApplication,
              let application = installedApplications.first(where: { $0.id == identity }) else {
            return
        }
        selectedAliasApplicationID = identity
        beginEditingAlias(for: application)
    }

    func chooseSelectedAliasApplication() {
        guard let selectedAliasApplicationID else { return }
        chooseAliasApplication(selectedAliasApplicationID)
    }

    func cancelAliasEditing() {
        guard aliasEditorMode != nil
                || !aliasDraft.isEmpty
                || !aliasApplicationQuery.isEmpty
                || aliasValidationMessage != nil else {
            return
        }
        aliasEditorMode = nil
        aliasDraft = ""
        aliasApplicationQuery = ""
        selectedAliasApplicationID = nil
        aliasValidationMessage = nil
        isSavingAlias = false
        focusRequest += 1
    }

    func saveAlias() {
        guard case let .editing(identity) = aliasEditorMode,
              !isSavingAlias else {
            return
        }

        let alias: String
        do {
            alias = try Self.validatedAlias(aliasDraft)
        } catch {
            errorMessage = LauncherError.invalidAlias.localizedDescription
            aliasValidationMessage = LauncherError.invalidAlias.localizedDescription
            return
        }

        isSavingAlias = true
        aliasValidationMessage = nil
        Task {
            do {
                let snapshot = try await catalog.updateAlias(
                    identity: identity,
                    alias: alias
                )
                apply(snapshot: snapshot)
                isSavingAlias = false
                aliasEditorMode = nil
                aliasDraft = ""
                aliasApplicationQuery = ""
                selectedAliasApplicationID = nil
                statusMessage = "Alias saved"
                selectedID = Self.applicationResultID(identity)
                refreshSearch()
                dismissModal()
            } catch {
                isSavingAlias = false
                aliasValidationMessage = error.localizedDescription
                modalErrorMessage = error.localizedDescription
            }
        }
    }

    nonisolated static func validatedAlias(_ rawAlias: String) throws -> String {
        let trimmed = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            throw LauncherError.invalidAlias
        }
        return trimmed
    }

    func requestAliasDeletion() {
        guard aliasEditorMode == nil,
              let application = selectedApplication,
              application.preference.alias != nil else {
            return
        }
        presentModal(.confirmation(.deleteAlias(application.id)))
    }

    func confirmAliasDeletion() {
        guard case let .confirmation(.deleteAlias(identity)) = paletteModal,
              let application = installedApplications.first(where: { $0.id == identity }) else {
            return
        }
        let deletedIndex = results.firstIndex {
            $0.id == Self.applicationResultID(application.id)
        } ?? 0
        isModalProcessing = true
        modalErrorMessage = nil
        Task {
            do {
                apply(
                    snapshot: try await catalog.updateAlias(
                        identity: application.id,
                        alias: nil
                    )
                )
                statusMessage = "Alias deleted"
                refreshSearch(
                    preserveSelection: false,
                    preferredSelectionIndex: deletedIndex
                )
                dismissModal()
            } catch {
                isModalProcessing = false
                modalErrorMessage = error.localizedDescription
            }
        }
    }

    func revealSelectedApplicationInFinder() {
        guard let application = selectedApplication else { return }
        dismissForLaunch?()
        launcher.revealInFinder(application)
    }

    func pasteSelected() {
        guard let result = selectedResult else { return }
        switch result.payload {
        case .clipboard:
            guard let item = selectedClipboardItem else { return }
            if item.kind == .image {
                pasteImageItem(item)
            } else {
                performPaste(item.pasteboardContent) { [weak self] in
                    self?.recordClipboardUse(item.id)
                }
            }
        case .snippet:
            guard let snippet = selectedSnippet else { return }
            performPaste(.text(snippet.content)) { [weak self] in
                self?.recordSnippetUse(snippet.id)
            }
        case .application, .feature, .calculation, .calculationError:
            return
        }
    }

    func copySelected() {
        guard let result = selectedResult else { return }
        switch result.payload {
        case .clipboard:
            guard let item = selectedClipboardItem else { return }
            if item.kind == .image {
                copyImageItem(item)
            } else {
                performCopy(item.pasteboardContent) { [weak self] in
                    self?.recordClipboardUse(item.id)
                }
            }
        case .snippet:
            guard let snippet = selectedSnippet else { return }
            performCopy(.text(snippet.content)) { [weak self] in
                self?.recordSnippetUse(snippet.id)
            }
        case let .calculation(_, result):
            performCopy(.text(result)) {}
        case .application, .feature, .calculationError:
            return
        }
    }

    func copyCalculationExpression() {
        guard case let .calculation(expression, result) = selectedResult?.payload else {
            return
        }
        performCopy(.text("\(expression) = \(result)")) {}
    }

    private func performPaste(
        _ content: PasteboardContent,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        dismissActionPanel(restoreSearchFocus: false)
        pasteContent?(content) { [weak self] result in
            switch result {
            case .pasted:
                onSuccess()
            case .copiedBecausePermissionDenied:
                onSuccess()
                self?.statusMessage = "Copied. Allow Accessibility to paste automatically."
            case .copiedBecauseTargetUnavailable:
                onSuccess()
                self?.statusMessage = "Copied. The target application is no longer available."
            case .copiedBecauseActivationFailed:
                onSuccess()
                self?.statusMessage = "Copied. Yorozu couldn’t activate the target application."
            case .failedBecauseClipboardCouldNotBePreserved:
                self?.errorMessage =
                    "The current clipboard is too large to preserve safely."
            case .failed:
                self?.errorMessage = "The selected content couldn’t be pasted."
            }
        }
    }

    private func performCopy(
        _ content: PasteboardContent,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        Task {
            guard let result = await copyContent?(content) else {
                errorMessage = "The selected content could not be copied."
                return
            }
            switch result {
            case .written:
                onSuccess()
                statusMessage = "Copied to Clipboard"
            case .preservationLimitExceeded:
                errorMessage = "The current clipboard is too large to preserve safely."
            case .invalidContent:
                errorMessage = "The selected content is no longer available."
            case .writeFailedAndRestored:
                errorMessage = "The selected content could not be copied."
            case .writeFailedAndRestoreFailed:
                errorMessage =
                    "Copy failed, and the previous clipboard could not be restored."
            }
        }
    }

    private func pasteImageItem(_ item: ClipboardItem) {
        Task {
            guard let data = await clipboardCatalog.imageData(id: item.id), !data.isEmpty else {
                errorMessage = "The selected image could not be loaded."
                return
            }
            performPaste(.image(data)) { [weak self] in
                self?.recordClipboardUse(item.id)
            }
        }
    }

    private func copyImageItem(_ item: ClipboardItem) {
        Task {
            guard let data = await clipboardCatalog.imageData(id: item.id), !data.isEmpty else {
                errorMessage = "The selected image could not be loaded."
                return
            }
            performCopy(.image(data)) { [weak self] in
                self?.recordClipboardUse(item.id)
            }
        }
    }

    func restoreSelectionAfterOperation(_ selection: CommandResultID?) {
        guard let selection, resultIndexByID[selection] != nil else { return }
        selectedID = selection
    }

    func newSnippet() {
        guard route == .snippets else { return }
        dismissActionPanel(restoreSearchFocus: false)
        snippetNameDraft = ""
        snippetKeywordDraft = ""
        snippetContentDraft = ""
        presentModal(.snippetEditor(.new))
    }

    func editSelectedSnippet() {
        guard let snippet = selectedSnippet else { return }
        dismissActionPanel(restoreSearchFocus: false)
        snippetNameDraft = snippet.name
        snippetKeywordDraft = snippet.keyword ?? ""
        snippetContentDraft = snippet.content
        presentModal(.snippetEditor(.editing(snippet.id)))
    }

    func saveSnippetFromModal() {
        guard case let .snippetEditor(mode) = paletteModal,
              !isModalProcessing else { return }
        let existing: Snippet?
        switch mode {
        case .new:
            existing = nil
        case let .editing(id):
            existing = snippetByID[id]
        }
        isModalProcessing = true
        modalErrorMessage = nil
        saveSnippet(
            existing: existing,
            name: snippetNameDraft,
            keyword: snippetKeywordDraft,
            content: snippetContentDraft
        ) { [weak self] success, message in
            guard let self else { return }
            self.isModalProcessing = false
            if success {
                self.statusMessage = existing == nil ? "Snippet created" : "Snippet saved"
                self.dismissModal()
            } else {
                self.modalErrorMessage = message ?? "The snippet could not be saved."
            }
        }
    }

    func saveSnippet(
        existing: Snippet?,
        name: String,
        keyword: String,
        content: String,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        let snippet: Snippet
        do {
            snippet = try Snippet.validated(
                name: name,
                keyword: keyword,
                content: content,
                existing: existing
            )
        } catch {
            completion(false, error.localizedDescription)
            return
        }

        Task {
            do {
                apply(snippetSnapshot: try await snippetCatalog.save(snippet))
                refreshSearch()
                completion(true, nil)
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }

    func duplicateSelectedSnippet() {
        guard let snippet = selectedSnippet else { return }
        Task {
            do {
                apply(snippetSnapshot: try await snippetCatalog.duplicate(snippet))
                statusMessage = "Snippet duplicated"
                refreshSearch()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestDeleteSelected() {
        guard let selectedResult,
              selectedResult.kind == .clipboard || selectedResult.kind == .snippet else {
            return
        }
        switch selectedResult.payload {
        case let .clipboard(id):
            presentModal(.confirmation(.deleteClipboard(id)))
        case let .snippet(id):
            presentModal(.confirmation(.deleteSnippet(id)))
        case .application, .feature, .calculation, .calculationError:
            break
        }
    }

    private func deleteConfirmed(_ confirmation: PaletteConfirmation) {
        isModalProcessing = true
        modalErrorMessage = nil
        Task {
            switch confirmation {
            case let .deleteClipboard(id):
                apply(clipboardSnapshot: await clipboardCatalog.delete(id: id))
            case let .deleteSnippet(id):
                apply(snippetSnapshot: await snippetCatalog.delete(id: id))
            default:
                isModalProcessing = false
                return
            }
            refreshSearch()
            dismissModal()
        }
    }

    func requestClearClipboardHistory(includePinned: Bool) {
        presentModal(.confirmation(.clearClipboardHistory(includePinned: includePinned)))
    }

    func applyClipboardRetentionSettings() {
        let settings = clipboardPreferences.recordingSettings
        Task {
            apply(
                clipboardSnapshot: await clipboardCatalog.prune(
                    retentionDays: settings.retentionDays,
                    maximumItems: settings.maximumItems
                )
            )
            refreshSearch()
        }
    }

    func revealStorageRecoveryBackup() {
        guard let storageRecoveryNotice else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            storageRecoveryNotice.backupDirectory,
        ])
    }

    func dismissStorageRecoveryNotice() {
        storageRecoveryNotice = nil
    }

    func showActionMenu() {
        let hasActions: Bool
        if route.isAI {
            hasActions = !aiChatViewModel.actionItems.isEmpty
        } else if route == .translation {
            hasActions = !translationViewModel.actionItems.isEmpty
        } else {
            hasActions = selectedResult != nil
        }
        guard hasActions,
              paletteModal == nil,
              route != .aliases || aliasEditorMode == nil else {
            return
        }
        if isActionPanelPresented {
            dismissActionPanel()
        } else {
            actionQuery = ""
            isActionPanelPresented = true
            selectedActionID = filteredActionItems.first?.id
        }
    }

    func dismissActionPanel(restoreSearchFocus: Bool = true) {
        guard isActionPanelPresented || !actionQuery.isEmpty || selectedActionID != nil else {
            return
        }
        isActionPanelPresented = false
        actionQuery = ""
        selectedActionID = nil
        if route.isAI {
            aiChatViewModel.cancelActionNavigation()
        } else if route == .translation {
            translationViewModel.cancelActionNavigation()
        }
        if restoreSearchFocus {
            focusRequest += 1
        }
    }

    func selectAction(_ id: LauncherActionID) {
        guard filteredActionItems.contains(where: { $0.id == id }) else { return }
        selectedActionID = id
    }

    func moveActionSelection(by delta: Int) {
        let actions = filteredActionItems
        guard !actions.isEmpty else { return }
        let currentIndex = selectedActionID.flatMap { id in
            actions.firstIndex(where: { $0.id == id })
        } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), actions.count - 1)
        selectedActionID = actions[nextIndex].id
    }

    func performSelectedAction() {
        guard let selectedActionID else { return }
        performAction(selectedActionID)
    }

    func performAction(_ action: LauncherActionID) {
        if route == .translation {
            let keepsActionPanel = translationViewModel.performAction(action)
            if keepsActionPanel {
                actionQuery = ""
                selectedActionID = filteredActionItems.first?.id
            } else {
                dismissActionPanel()
            }
            return
        }
        if action.rawValue.hasPrefix("ai") {
            if action == .aiDelete {
                requestAIConversationDeletion()
                return
            }
            aiChatViewModel.performAction(action)
            if action == .aiChangeModel || action == .aiChangeReasoning {
                actionQuery = ""
                selectedActionID = filteredActionItems.first?.id
            } else {
                dismissActionPanel()
            }
            return
        }
        switch action {
        case .open:
            dismissActionPanel(restoreSearchFocus: false)
            performPrimaryAction()
        case .paste:
            pasteSelected()
        case .copy:
            dismissActionPanel()
            copySelected()
        case .copyCalculationExpression:
            dismissActionPanel()
            copyCalculationExpression()
        case .togglePin:
            dismissActionPanel()
            togglePinForSelectedResult()
        case .editAlias:
            dismissActionPanel(restoreSearchFocus: false)
            editAliasForSelectedApplication()
        case .deleteAlias:
            dismissActionPanel()
            requestAliasDeletion()
        case .reveal:
            dismissActionPanel(restoreSearchFocus: false)
            revealSelectedApplicationInFinder()
        case .editSnippet:
            editSelectedSnippet()
        case .duplicateSnippet:
            dismissActionPanel()
            duplicateSelectedSnippet()
        case .delete:
            dismissActionPanel()
            requestDeleteSelected()
        case .aiOpenChat, .aiOpenInCodex, .aiNewChat,
             .translationChangeLanguage,
             .translationLanguage1, .translationLanguage2,
             .translationLanguage3, .translationLanguage4,
             .translationLanguage5, .translationLanguage6,
             .translationLanguage7, .translationLanguage8,
             .translationLanguage9, .translationLanguage10,
             .translationLanguage11, .translationLanguage12,
             .translationChangeProvider, .translationProvider1,
             .translationProvider2, .translationProvider3,
             .translationProvider4, .aiChangeModel,
             .aiChangeReasoning, .aiModelTerra,
             .aiModelSol, .aiModelLuna, .aiModel4, .aiModel5, .aiModel6,
             .aiModel7, .aiModel8, .aiModel9, .aiModel10,
             .aiReasoning1, .aiReasoning2, .aiReasoning3, .aiReasoning4,
             .aiReasoning5, .aiReasoning6, .aiReasoning7, .aiReasoning8,
             .aiReasoning9, .aiReasoning10,
             .aiToggleWebSearch, .aiAttachFiles,
             .aiArchive, .aiDelete, .aiToggleArchiveScope,
             .aiCopyLastResponse, .aiStopGenerating:
            break
        }
    }

    func escape() {
        if paletteModal != nil {
            dismissModal()
        } else if isActionPanelPresented {
            dismissActionPanel()
        } else if route.isAI, aiChatViewModel.handleEscape() {
            return
        } else if aliasEditorMode != nil {
            cancelAliasEditing()
        } else if route != .root, presentationOrigin == .root {
            resetClipboardImagePreview()
            statusMessage = nil
            focusRequest += 1
            transitionRoute(to: .root, origin: .direct)
        } else {
            dismissAndRestorePreviousApplication?()
        }
    }

    func returnToRoot() {
        dismissActionPanel(restoreSearchFocus: false)
        dismissModal(restoreFocus: false)
        resetClipboardImagePreview()
        statusMessage = nil
        focusRequest += 1
        transitionRoute(to: .root, origin: .direct)
    }

    func presentOpenAIAPIKeyModal() {
        openAIAPIKeyDraft = ""
        presentModal(.openAIAPIKey)
    }

    func presentClaudeAPIKeyModal() {
        claudeAPIKeyDraft = ""
        presentModal(.claudeAPIKey)
    }

    func presentCodexExecutablePathModal() {
        codexExecutablePathDraft = aiProviderPreferences.codexExecutablePath
        presentModal(.codexExecutablePath)
    }

    func saveOpenAIAPIKeyFromModal() {
        guard paletteModal == .openAIAPIKey,
              !isModalProcessing,
              let viewModel = aiChatViewModel(for: .openAIAPI) else { return }
        isModalProcessing = true
        modalErrorMessage = nil
        viewModel.saveAPIKey(openAIAPIKeyDraft) { [weak self] success, message in
            guard let self else { return }
            self.isModalProcessing = false
            if success {
                self.dismissModal()
            } else {
                self.modalErrorMessage = message ?? "The API key could not be saved."
            }
        }
    }

    func saveClaudeAPIKeyFromModal() {
        guard paletteModal == .claudeAPIKey,
              !isModalProcessing,
              let viewModel = aiChatViewModel(for: .claude) else { return }
        isModalProcessing = true
        modalErrorMessage = nil
        viewModel.saveAPIKey(claudeAPIKeyDraft) { [weak self] success, message in
            guard let self else { return }
            self.isModalProcessing = false
            if success {
                self.dismissModal()
            } else {
                self.modalErrorMessage = message ?? "The API key could not be saved."
            }
        }
    }

    func saveCodexExecutablePathFromModal() {
        guard paletteModal == .codexExecutablePath,
              !isModalProcessing,
              let viewModel = aiChatViewModel(for: .codex) else { return }
        let path = codexExecutablePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isModalProcessing = true
        modalErrorMessage = nil
        viewModel.updateCodexExecutablePath(path) { [weak self] success, message in
            guard let self else { return }
            self.isModalProcessing = false
            if success {
                self.aiProviderPreferences.codexExecutablePath = path
                self.dismissModal()
            } else {
                self.modalErrorMessage = message ?? "The executable path could not be saved."
            }
        }
    }

    func useAutomaticCodexDetection() {
        codexExecutablePathDraft = ""
        saveCodexExecutablePathFromModal()
    }

    func requestCodexSignOut() {
        presentModal(.confirmation(.codexSignOut))
    }

    func requestOpenAIAPIKeyRemoval() {
        presentModal(.confirmation(.removeOpenAIAPIKey))
    }

    func requestClaudeAPIKeyRemoval() {
        presentModal(.confirmation(.removeClaudeAPIKey))
    }

    func requestAIConversationDeletion() {
        guard let target = aiChatViewModel.deletionTarget else { return }
        presentModal(.confirmation(.deleteAIConversation(target.reference)))
    }

    func confirmModalAction() {
        guard case let .confirmation(confirmation) = paletteModal,
              !isModalProcessing else { return }
        switch confirmation {
        case .deleteClipboard, .deleteSnippet:
            deleteConfirmed(confirmation)
        case .deleteAlias:
            confirmAliasDeletion()
        case let .deleteAIConversation(reference):
            guard let viewModel = aiChatViewModel(for: reference.providerID) else {
                modalErrorMessage = "The AI provider is unavailable."
                return
            }
            isModalProcessing = true
            modalErrorMessage = nil
            viewModel.deleteConversation(reference: reference) { [weak self] success, message in
                guard let self else { return }
                self.isModalProcessing = false
                if success {
                    self.dismissModal()
                } else {
                    self.modalErrorMessage = message ?? "The chat could not be deleted."
                }
            }
        case let .clearClipboardHistory(includePinned):
            isModalProcessing = true
            Task {
                apply(
                    clipboardSnapshot: await clipboardCatalog.clear(
                        includePinned: includePinned
                    )
                )
                refreshSearch()
                dismissModal()
            }
        case .codexSignOut:
            guard let viewModel = aiChatViewModel(for: .codex) else {
                modalErrorMessage = "Codex is unavailable."
                return
            }
            isModalProcessing = true
            viewModel.signOut { [weak self] success, message in
                guard let self else { return }
                self.isModalProcessing = false
                if success {
                    self.dismissModal()
                } else {
                    self.modalErrorMessage = message ?? "Yorozu could not sign out."
                }
            }
        case .removeOpenAIAPIKey:
            guard let viewModel = aiChatViewModel(for: .openAIAPI) else {
                modalErrorMessage = "OpenAI API is unavailable."
                return
            }
            isModalProcessing = true
            viewModel.removeAPIKey { [weak self] success, message in
                guard let self else { return }
                self.isModalProcessing = false
                if success {
                    self.dismissModal()
                } else {
                    self.modalErrorMessage = message ?? "The API key could not be removed."
                }
            }
        case .removeClaudeAPIKey:
            guard let viewModel = aiChatViewModel(for: .claude) else {
                modalErrorMessage = "Claude is unavailable."
                return
            }
            isModalProcessing = true
            viewModel.removeAPIKey { [weak self] success, message in
                guard let self else { return }
                self.isModalProcessing = false
                if success {
                    self.dismissModal()
                } else {
                    self.modalErrorMessage = message ?? "The API key could not be removed."
                }
            }
        }
    }

    func performModalSubmit() {
        switch paletteModal {
        case .snippetEditor:
            saveSnippetFromModal()
        case .aliasApplicationPicker:
            chooseSelectedAliasApplication()
        case .aliasEditor:
            saveAlias()
        case .openAIAPIKey:
            saveOpenAIAPIKeyFromModal()
        case .claudeAPIKey:
            saveClaudeAPIKeyFromModal()
        case .codexExecutablePath:
            saveCodexExecutablePathFromModal()
        case .confirmation, nil:
            break
        }
    }

    func dismissModal(restoreFocus: Bool = true) {
        guard paletteModal != nil
                || aliasEditorMode != nil
                || !snippetNameDraft.isEmpty
                || !snippetKeywordDraft.isEmpty
                || !snippetContentDraft.isEmpty
                || !openAIAPIKeyDraft.isEmpty
                || !claudeAPIKeyDraft.isEmpty
                || !codexExecutablePathDraft.isEmpty else { return }
        paletteModal = nil
        modalErrorMessage = nil
        isModalProcessing = false
        snippetNameDraft = ""
        snippetKeywordDraft = ""
        snippetContentDraft = ""
        openAIAPIKeyDraft = ""
        claudeAPIKeyDraft = ""
        codexExecutablePathDraft = ""
        aliasEditorMode = nil
        aliasDraft = ""
        aliasApplicationQuery = ""
        selectedAliasApplicationID = nil
        aliasValidationMessage = nil
        isSavingAlias = false
        if restoreFocus { focusRequest += 1 }
    }

    private func presentModal(_ modal: PaletteModal) {
        dismissActionPanel(restoreSearchFocus: false)
        paletteModal = modal
        modalErrorMessage = nil
        isModalProcessing = false
        modalFocusRequest += 1
    }

    func paletteDidHide() {
        dismissModal(restoreFocus: false)
        searchTask?.cancel()
        searchRevision += 1
        resetClipboardImagePreview()
        urlPreviewService.cancel(resetState: true)
    }

    func paletteDidBecomeVisible() {
        if route.isAI {
            aiChatViewModel.paletteDidBecomeVisible()
        } else if route == .translation {
            translationViewModel.requestInputFocus()
        }
    }

    private func beginEditingAlias(for application: LaunchableApplication) {
        aliasEditorMode = .editing(application.id)
        aliasDraft = application.preference.alias ?? ""
        aliasApplicationQuery = ""
        selectedAliasApplicationID = application.id
        aliasValidationMessage = nil
        selectedID = Self.applicationResultID(application.id)
        aliasFocusRequest += 1
        presentModal(.aliasEditor(application.id))
    }

    private func reconcileAliasApplicationSelection() {
        let candidates = aliasApplicationCandidates
        if let selectedAliasApplicationID,
           candidates.contains(where: { $0.id == selectedAliasApplicationID }) {
            return
        }
        selectedAliasApplicationID = candidates.first?.id
    }

    private func moveAliasApplicationSelection(by delta: Int) {
        let candidates = aliasApplicationCandidates
        guard !candidates.isEmpty else { return }
        let currentIndex = selectedAliasApplicationID.flatMap { identity in
            candidates.firstIndex(where: { $0.id == identity })
        } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), candidates.count - 1)
        selectedAliasApplicationID = candidates[nextIndex].id
    }

    private func refreshSearch(
        preserveSelection: Bool = true,
        preferredSelectionIndex: Int? = nil
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        searchTask?.cancel()
        searchRevision += 1
        let revision = searchRevision
        let currentQuery = query
        let currentRoute = route
        let previousSelection = preserveSelection ? selectedID : nil

        if currentQuery.isEmpty,
           let cachedResults = cachedDefaultResults(for: currentRoute) {
            publishSearchResults(
                cachedResults,
                previousSelection: previousSelection,
                preferredSelectionIndex: preferredSelectionIndex
            )
            LauncherPerformanceTrace.duration(
                "query_results_published",
                startedAt: startedAt
            )
            return
        }

        searchTask = Task {
            let matches: [CommandResult]
            switch currentRoute {
            case .root:
                let applications = await catalog.search(query: currentQuery)
                matches = rootResults(
                    query: currentQuery,
                    applications: applications
                )
            case .clipboard:
                let items = await clipboardCatalog.search(query: currentQuery)
                matches = items.map(Self.clipboardResult)
            case .snippets:
                let snippets = await snippetCatalog.search(query: currentQuery)
                matches = snippets.map(Self.snippetResult)
            case .aliases:
                let applications = await catalog.searchAliases(query: currentQuery)
                matches = applications.map {
                    Self.applicationResult($0, query: currentQuery)
                }
            case .ai, .translation:
                matches = []
            case .settings:
                matches = []
            }

            guard revision == searchRevision, !Task.isCancelled, currentRoute == route else {
                return
            }
            publishSearchResults(
                matches,
                previousSelection: previousSelection,
                preferredSelectionIndex: preferredSelectionIndex
            )
            LauncherPerformanceTrace.duration(
                "query_results_published",
                startedAt: startedAt
            )
        }
    }

    private func transitionRoute(
        to newRoute: PaletteRoute,
        origin: PalettePresentationOrigin,
        resetsSelection: Bool = false
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        if let selectedID {
            selectionByRoute[route] = selectedID
        }
        searchTask?.cancel()
        searchRevision += 1

        isApplyingRouteState = true
        if !query.isEmpty {
            query = ""
        }
        if route != newRoute {
            route = newRoute
        }
        if presentationOrigin != origin {
            presentationOrigin = origin
        }
        let initialResults = cachedDefaultResults(for: newRoute) ?? []
        if results != initialResults {
            results = initialResults
            resultIndexByID = Self.makeResultIndex(initialResults)
            resultsRevision &+= 1
        }
        // Clipboard and Snippets are frequently reopened as fresh pickers.
        // Their previous selection can be far below the visible viewport, so
        // always start those routes at the newest/highest-ranked item. Other
        // routes still restore their selection (for example, returning to the
        // feature row in Root Search).
        let rememberedSelection = (resetsSelection || shouldResetSelectionOnEntry(newRoute))
            ? nil
            : selectionByRoute[newRoute]
        let nextSelection: CommandResultID?
        if let rememberedSelection,
           initialResults.contains(where: { $0.id == rememberedSelection }) {
            nextSelection = rememberedSelection
        } else {
            nextSelection = initialResults.first?.id
        }
        if selectedID != nextSelection {
            selectedID = nextSelection
        }
        isApplyingRouteState = false
        loadSelectedClipboardImage()

        LauncherPerformanceTrace.duration(
            "route_published",
            startedAt: startedAt
        )
        if cachedDefaultResults(for: newRoute) != nil {
            LauncherPerformanceTrace.duration(
                "route_usable_list",
                startedAt: startedAt
            )
        } else if newRoute != .settings, !newRoute.isAI, newRoute != .translation {
            refreshSearch(preserveSelection: true)
        }
    }

    private func shouldResetSelectionOnEntry(_ route: PaletteRoute) -> Bool {
        route == .clipboard || route == .snippets || route == .translation
    }

    private func cachedDefaultResults(
        for route: PaletteRoute
    ) -> [CommandResult]? {
        switch route {
        case .root:
            rootDefaultResults
        case .translation:
            []
        case .clipboard:
            clipboardDefaultResults
        case .snippets:
            snippetDefaultResults
        case .settings:
            []
        case .ai:
            []
        case .aliases:
            nil
        }
    }

    private func publishSearchResults(
        _ matches: [CommandResult],
        previousSelection: CommandResultID?,
        preferredSelectionIndex: Int?
    ) {
        let nextSelection: CommandResultID?
        if let previousSelection,
           matches.contains(where: { $0.id == previousSelection }) {
            nextSelection = previousSelection
        } else if let preferredSelectionIndex, !matches.isEmpty {
            nextSelection = matches[
                min(preferredSelectionIndex, matches.count - 1)
            ].id
        } else {
            nextSelection = matches.first?.id
        }

        if results != matches {
            results = matches
            resultIndexByID = Self.makeResultIndex(matches)
            resultsRevision &+= 1
        }
        if selectedID != nextSelection {
            selectedID = nextSelection
        }
    }

    private func featureResults(query: String) -> [CommandResult] {
        let normalized = query.launcherNormalized
        return featureCommands.compactMap { state in
            let feature = state.command
            if let providerID = feature.providerID,
               !aiProviderPreferences.isEnabled(providerID) {
                return nil
            }
            let score: Int
            if normalized.isEmpty {
                score = 0
            } else if let matchedScore = SearchScorer.totalScore(
                title: feature.title,
                subtitle: feature.subtitle,
                preference: state.preference,
                query: query
            ) {
                score = matchedScore
            } else {
                return nil
            }
            return CommandResult(
                id: CommandResultID(rawValue: "feature:\(feature.rawValue)"),
                kind: .feature,
                title: feature.title,
                subtitle: feature.subtitle,
                icon: .system(feature.symbolName),
                score: score,
                isPinned: state.preference.isPinned,
                payload: .feature(feature)
            )
        }
    }

    private func handleAIProviderPreferencesChange() {
        translationViewModel.refreshProviderAvailability()
        rebuildRootDefaultResults()
        if let providerID = route.aiProviderID,
           !aiProviderPreferences.isEnabled(providerID) {
            aiChatViewModel.stopGenerating()
            transitionRoute(to: .settings, origin: .direct)
        }
        if route == .root {
            refreshSearch(preserveSelection: true)
        }
    }

    private func rootResults(
        query: String,
        applications: [LaunchableApplication]
    ) -> [CommandResult] {
        let applicationResults = applications.map {
            Self.applicationResult($0, query: query)
        }
        var combined = featureResults(query: query) + applicationResults
        if !query.launcherNormalized.isEmpty,
           let evaluation = ArithmeticExpressionEvaluator.evaluateDetailed(query) {
            switch evaluation {
            case let .result(calculation):
                combined.append(
                    CommandResult(
                        id: CommandResultID(rawValue: "calculation:\(query.launcherNormalized)"),
                        kind: .calculation,
                        title: calculation,
                        subtitle: query,
                        icon: .system("equal.circle"),
                        score: 1_200,
                        isPinned: false,
                        payload: .calculation(expression: query, result: calculation)
                    )
                )
            case .divisionByZero:
                combined.append(
                    CommandResult(
                        id: CommandResultID(rawValue: "calculation-error:\(query.launcherNormalized)"),
                        kind: .calculation,
                        title: "Cannot divide by zero",
                        subtitle: query,
                        icon: .system("exclamationmark.triangle"),
                        score: 1_200,
                        isPinned: false,
                        payload: .calculationError(
                            expression: query,
                            message: "Cannot divide by zero"
                        )
                    )
                )
            }
        }
        let sorted: [CommandResult]
        if query.launcherNormalized.isEmpty {
            sorted = combined.sorted(by: rootEmptyQueryComparator)
        } else {
            sorted = combined.sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return rootEmptyQueryComparator(lhs, rhs)
            }
        }
        return Array(sorted.prefix(20))
    }

    private func rootEmptyQueryComparator(
        _ lhs: CommandResult,
        _ rhs: CommandResult
    ) -> Bool {
        let lhsPreference = rootPreference(for: lhs)
        let rhsPreference = rootPreference(for: rhs)
        if lhsPreference.isPinned != rhsPreference.isPinned {
            return lhsPreference.isPinned
        }
        if lhsPreference.isPinned,
           lhsPreference.pinnedAt != rhsPreference.pinnedAt {
            return (lhsPreference.pinnedAt ?? .distantFuture)
                < (rhsPreference.pinnedAt ?? .distantFuture)
        }
        if lhsPreference.lastLaunchedAt != rhsPreference.lastLaunchedAt {
            return (lhsPreference.lastLaunchedAt ?? .distantPast)
                > (rhsPreference.lastLaunchedAt ?? .distantPast)
        }
        if lhsPreference.launchCount != rhsPreference.launchCount {
            return lhsPreference.launchCount > rhsPreference.launchCount
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func rootPreference(for result: CommandResult) -> LauncherPreference {
        switch result.payload {
        case let .application(application):
            return application.preference
        case let .feature(feature):
            return featureCommands.first(where: { $0.command == feature })?.preference ?? .empty
        case .calculation, .calculationError, .clipboard, .snippet:
            return .empty
        }
    }

    private func recordFeatureUse(_ feature: FeatureCommand) {
        Task {
            apply(featureSnapshot: await featureCatalog.recordUse(of: feature))
            if route == .root {
                refreshSearch()
            }
        }
    }

    private func apply(
        featureSnapshot snapshot: FeatureSnapshot<FeatureCommandState>
    ) {
        featureCommands = snapshot.values
        rebuildRootDefaultResults()
        storageAvailable = storageAvailable && snapshot.storageAvailable
        if let message = snapshot.message {
            errorMessage = message
        }
    }

    private func recordSnippetUse(_ id: UUID) {
        let usedAt = Date()
        Task {
            apply(
                snippetSnapshot: await snippetCatalog.recordUse(
                    id: id,
                    usedAt: usedAt
                )
            )
            if route == .snippets {
                refreshSearch(preserveSelection: true)
            }
        }
    }

    private func recordClipboardUse(_ id: UUID) {
        let usedAt = Date()
        Task {
            apply(
                clipboardSnapshot: await clipboardCatalog.recordUse(
                    id: id,
                    usedAt: usedAt
                )
            )
            if route == .clipboard {
                refreshSearch(preserveSelection: true)
            }
        }
    }

    private func apply(snapshot: CatalogSnapshot) {
        installedApplications = snapshot.applications
        rebuildRootDefaultResults()
        indexCount = snapshot.applications.count
        lastIndexedAt = snapshot.lastIndexedAt ?? lastIndexedAt
        storageAvailable = snapshot.storageAvailable
        if let message = snapshot.message {
            errorMessage = message
        }
    }

    private func rebuildRootDefaultResults() {
        rootDefaultResults = rootResults(
            query: "",
            applications: installedApplications
        )
    }

    private func apply(clipboardSnapshot snapshot: FeatureSnapshot<ClipboardItem>) {
        clipboardItems = snapshot.values
        clipboardItemByID = Dictionary(
            uniqueKeysWithValues: snapshot.values.map { ($0.id, $0) }
        )
        clipboardItemCount = snapshot.values.count
        clipboardDefaultResults = snapshot.values.prefix(50).map(Self.clipboardResult)
        storageAvailable = storageAvailable && snapshot.storageAvailable
        if let message = snapshot.message {
            errorMessage = message
        }
    }

    private func apply(snippetSnapshot snapshot: FeatureSnapshot<Snippet>) {
        snippets = snapshot.values
        snippetByID = Dictionary(
            uniqueKeysWithValues: snapshot.values.map { ($0.id, $0) }
        )
        snippetCount = snapshot.values.count
        snippetDefaultResults = snapshot.values.prefix(50).map(Self.snippetResult)
        storageAvailable = storageAvailable && snapshot.storageAvailable
        if let message = snapshot.message {
            errorMessage = message
        }
    }

    private func loadSelectedClipboardImage() {
        clipboardImageLoadTask?.cancel()
        clipboardImageLoadTask = nil
        clipboardImageGeneration += 1
        let generation = clipboardImageGeneration
        if selectedClipboardImage != nil {
            selectedClipboardImage = nil
        }
        if isClipboardImageLoading {
            isClipboardImageLoading = false
        }

        guard route == .clipboard,
              let item = selectedClipboardItem,
              item.kind == .image else {
            return
        }
        if let cachedImage = clipboardImageCache.object(
            forKey: item.id as NSUUID
        ) {
            selectedClipboardImage = cachedImage
            LauncherPerformanceTrace.duration(
                "detail_content_ready",
                startedAt: detailSelectionStartedAt ?? ProcessInfo.processInfo.systemUptime
            )
            return
        }
        if let data = item.imageData, !data.isEmpty {
            isClipboardImageLoading = true
            decodeClipboardImage(data, itemID: item.id)
            return
        }

        let itemID = item.id
        isClipboardImageLoading = true
        clipboardImageLoadTask = Task { [weak self] in
            guard let self else { return }
            let data = await clipboardCatalog.imageData(id: itemID)
            guard !Task.isCancelled,
                  generation == clipboardImageGeneration,
                  route == .clipboard,
                  selectedClipboardItem?.id == itemID,
                  let data,
                  !data.isEmpty else {
                if generation == clipboardImageGeneration {
                    isClipboardImageLoading = false
                }
                return
            }
            let image = await clipboardImageDecoder.decode(data)
            guard !Task.isCancelled,
                  generation == clipboardImageGeneration,
                  route == .clipboard,
                  selectedClipboardItem?.id == itemID,
                  let image else {
                isClipboardImageLoading = false
                return
            }
            selectedClipboardImage = image
            cacheClipboardImage(image, id: itemID)
            isClipboardImageLoading = false
            if let detailSelectionStartedAt {
                LauncherPerformanceTrace.duration(
                    "detail_content_ready",
                    startedAt: detailSelectionStartedAt
                )
            }
        }
    }

    private func resetClipboardImagePreview() {
        clipboardImageLoadTask?.cancel()
        clipboardImageLoadTask = nil
        clipboardImageGeneration += 1
        if selectedClipboardImage != nil {
            selectedClipboardImage = nil
        }
        if isClipboardImageLoading {
            isClipboardImageLoading = false
        }
    }

    private func decodeClipboardImage(_ data: Data, itemID: UUID) {
        let generation = clipboardImageGeneration
        clipboardImageLoadTask = Task { [weak self] in
            guard let self else { return }
            let image = await clipboardImageDecoder.decode(data)
            guard !Task.isCancelled,
                  generation == clipboardImageGeneration,
                  route == .clipboard,
                  selectedClipboardItem?.id == itemID,
                  let image else {
                isClipboardImageLoading = false
                return
            }
            selectedClipboardImage = image
            cacheClipboardImage(image, id: itemID)
            isClipboardImageLoading = false
            if let detailSelectionStartedAt {
                LauncherPerformanceTrace.duration(
                    "detail_content_ready",
                    startedAt: detailSelectionStartedAt
                )
            }
        }
    }

    private func cacheClipboardImage(_ image: CGImage, id: UUID) {
        let bytesPerRow = max(1, image.bytesPerRow)
        let cost = bytesPerRow.multipliedReportingOverflow(by: max(1, image.height))
        clipboardImageCache.setObject(
            image,
            forKey: id as NSUUID,
            cost: cost.overflow ? Int.max : cost.partialValue
        )
    }

    private func reconcileActionSelection() {
        guard isActionPanelPresented else { return }
        let actions = filteredActionItems
        if let selectedActionID,
           actions.contains(where: { $0.id == selectedActionID }) {
            return
        }
        selectedActionID = actions.first?.id
    }

    private func action(
        _ id: LauncherActionID,
        _ title: String,
        _ symbolName: String,
        _ shortcutGlyphs: [String],
        role: ButtonRole? = nil
    ) -> LauncherActionItem {
        LauncherActionItem(
            id: id,
            title: title,
            symbolName: symbolName,
            shortcutGlyphs: shortcutGlyphs,
            role: role
        )
    }

    private nonisolated static func makeResultIndex(
        _ results: [CommandResult]
    ) -> [CommandResultID: Int] {
        Dictionary(
            uniqueKeysWithValues: results.enumerated().map { ($1.id, $0) }
        )
    }

    private nonisolated static func applicationResult(
        _ application: LaunchableApplication,
        query: String
    ) -> CommandResult {
        CommandResult(
            id: CommandResultID(rawValue: "application:\(application.id.rawValue)"),
            kind: .application,
            title: application.primaryName,
            subtitle: application.subtitle,
            icon: .application(application.canonicalURL),
            score: SearchScorer.totalScore(for: application, query: query) ?? 0,
            isPinned: application.preference.isPinned,
            payload: .application(application)
        )
    }

    private nonisolated static func applicationResultID(
        _ identity: ApplicationIdentity
    ) -> CommandResultID {
        CommandResultID(rawValue: "application:\(identity.rawValue)")
    }

    private nonisolated static func clipboardResult(_ item: ClipboardItem) -> CommandResult {
        let source = item.sourceApplicationName ?? item.kindLabel
        return CommandResult(
            id: CommandResultID(rawValue: "clipboard:\(item.id.uuidString)"),
            kind: .clipboard,
            title: item.title,
            subtitle: "\(source) · \(item.copiedAt.formatted(.relative(presentation: .named)))",
            icon: .system(Self.clipboardSymbol(for: item.kind)),
            score: 0,
            isPinned: item.isPinned,
            payload: .clipboard(item.id)
        )
    }

    private nonisolated static func snippetResult(_ snippet: Snippet) -> CommandResult {
        let subtitle = snippet.keyword.map { "\($0) · \(Self.preview(snippet.content))" }
            ?? Self.preview(snippet.content)
        return CommandResult(
            id: CommandResultID(rawValue: "snippet:\(snippet.id.uuidString)"),
            kind: .snippet,
            title: snippet.name,
            subtitle: subtitle,
            icon: .system("text.quote"),
            score: 0,
            isPinned: false,
            payload: .snippet(snippet.id)
        )
    }

    private nonisolated static func preview(_ value: String) -> String {
        String(value.prefix(240))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func clipboardSymbol(for kind: ClipboardItemKind) -> String {
        switch kind {
        case .text:
            "text.alignleft"
        case .url:
            "link"
        case .files:
            "doc"
        case .image:
            "photo"
        }
    }
}

protocol ClipboardImageDecoding: Sendable {
    func decode(_ data: Data) async -> CGImage?
}

actor ClipboardImageDecoder: ClipboardImageDecoding {
    private static let maximumPreviewPixelSize = 1_200

    func decode(_ data: Data) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumPreviewPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        )
    }
}
