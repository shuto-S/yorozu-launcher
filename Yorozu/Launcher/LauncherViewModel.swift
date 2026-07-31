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
    case togglePin
    case editAlias
    case deleteAlias
    case reveal
    case editSnippet
    case duplicateSnippet
    case delete

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
    private(set) var aliasDeletionCandidate: LaunchableApplication?

    var dismissForLaunch: (() -> Void)?
    var reopenAfterLaunchFailure: (() -> Void)?
    var dismissAndRestorePreviousApplication: (() -> Void)?
    var presentSnippetEditor: ((Snippet?) -> Void)?
    var confirmDelete: ((CommandResult) -> Void)?
    var pasteContent: ((
        PasteboardContent,
        @escaping @MainActor (PasteResult) -> Void
    ) -> Void)?
    var copyContent: ((PasteboardContent) async -> PasteboardReplacementResult)?

    let clipboardPreferences: ClipboardPreferences
    let urlPreviewService: URLPreviewService
    let shortcutSettings: AppShortcutSettings

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
    private let logger = Logger(subsystem: "com.yorozu.app", category: "launcher")

    init(
        catalog: ApplicationCatalog,
        featureCatalog: FeatureCommandCatalog,
        clipboardCatalog: ClipboardCatalog,
        snippetCatalog: SnippetCatalog,
        clipboardPreferences: ClipboardPreferences,
        urlPreviewService: URLPreviewService,
        shortcutSettings: AppShortcutSettings = AppShortcutSettings(),
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
        self.launcher = launcher
        self.clipboardImageDecoder = clipboardImageDecoder
        self.storageRecoveryNotice = storageRecoveryNotice
        clipboardImageCache.countLimit = 8
        clipboardImageCache.totalCostLimit = 32 * 1_024 * 1_024
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

    var actionPanelTitle: String {
        selectedResult?.title ?? ""
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
        case .clipboard:
            clipboardPreferences.isEnabled
                ? "No Clipboard Items"
                : "Clipboard History Is Off"
        case .snippets:
            "No Snippets"
        case .aliases:
            query.isEmpty ? "No Aliases Yet" : "No Matching Aliases"
        case .settings:
            "Settings"
        }
    }

    var emptyStateSymbol: String {
        switch route {
        case .root:
            isIndexing ? "arrow.trianglehead.2.clockwise.rotate.90" : "magnifyingglass"
        case .clipboard:
            "clipboard"
        case .snippets:
            "text.quote"
        case .aliases:
            "character.cursor.ibeam"
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
        case .clipboard:
            return "\(clipboardItemCount) items"
        case .snippets:
            return "\(snippetCount) snippets"
        case .aliases:
            let count = installedApplications.lazy.filter {
                $0.preference.alias?.isEmpty == false
            }.count
            return "\(count) aliases"
        case .settings:
            return "Settings"
        }
    }

    var footerActions: [LauncherFooterAction] {
        switch route {
        case .root:
            [
                LauncherFooterAction(id: .primary, shortcut: "↩", title: "Open"),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .clipboard:
            [
                LauncherFooterAction(id: .primary, shortcut: "↩", title: "Paste"),
                LauncherFooterAction(id: .copy, shortcut: "⌘↩", title: "Copy"),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .snippets:
            [
                LauncherFooterAction(id: .primary, shortcut: "↩", title: "Paste"),
                LauncherFooterAction(id: .newSnippet, shortcut: "⌘N", title: "New"),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .aliases:
            [
                LauncherFooterAction(id: .primary, shortcut: "↩", title: "Open"),
                LauncherFooterAction(id: .addAlias, shortcut: "⌘N", title: "Add Alias"),
                LauncherFooterAction(id: .actions, shortcut: "⌘K", title: "Actions"),
            ]
        case .settings:
            []
        }
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
        searchTask?.cancel()
        searchTask = nil
        clipboardImageLoadTask?.cancel()
        clipboardImageLoadTask = nil
        urlPreviewService.cancel(resetState: true)
        startupTasks.forEach { $0.cancel() }
        startupTasks.removeAll(keepingCapacity: false)
    }

    func prepareForPresentation(
        route: PaletteRoute = .root,
        origin: PalettePresentationOrigin = .direct
    ) {
        dismissActionPanel(restoreSearchFocus: false)
        cancelAliasEditing()
        aliasDeletionCandidate = nil
        resetClipboardImagePreview()
        errorMessage = nil
        statusMessage = nil
        focusRequest += 1
        transitionRoute(to: route, origin: origin)
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
        guard !isIndexing else { return }
        isIndexing = true
        let state = await catalog.reindex()
        isIndexing = false
        apply(snapshot: state)
        refreshSearch()
    }

    func moveSelection(by delta: Int) {
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
            if route == .snippets {
                presentSnippetEditor?(nil)
            }
            return
        }
        switch result.payload {
        case .application:
            openSelectedApplication()
        case let .feature(feature):
            openFeature(feature)
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
        case .feature, .snippet:
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
                focusRequest += 1
            } catch {
                isSavingAlias = false
                aliasValidationMessage = error.localizedDescription
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
        dismissActionPanel()
        aliasDeletionCandidate = application
    }

    func cancelAliasDeletion() {
        aliasDeletionCandidate = nil
    }

    func confirmAliasDeletion() {
        guard let application = aliasDeletionCandidate else { return }
        let deletedIndex = results.firstIndex {
            $0.id == Self.applicationResultID(application.id)
        } ?? 0
        aliasDeletionCandidate = nil

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
            } catch {
                errorMessage = error.localizedDescription
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
        case .application, .feature:
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
        case .application, .feature:
            return
        }
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
        presentSnippetEditor?(nil)
    }

    func editSelectedSnippet() {
        guard let snippet = selectedSnippet else { return }
        dismissActionPanel(restoreSearchFocus: false)
        presentSnippetEditor?(snippet)
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
        confirmDelete?(selectedResult)
    }

    func deleteConfirmed(_ result: CommandResult) {
        Task {
            switch result.payload {
            case let .clipboard(id):
                apply(clipboardSnapshot: await clipboardCatalog.delete(id: id))
            case let .snippet(id):
                apply(snippetSnapshot: await snippetCatalog.delete(id: id))
            case .application, .feature:
                return
            }
            refreshSearch()
        }
    }

    func clearClipboardHistory(includePinned: Bool) {
        Task {
            apply(
                clipboardSnapshot: await clipboardCatalog.clear(includePinned: includePinned)
            )
            refreshSearch()
        }
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
        guard selectedResult != nil,
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
        switch action {
        case .open:
            dismissActionPanel(restoreSearchFocus: false)
            performPrimaryAction()
        case .paste:
            pasteSelected()
        case .copy:
            dismissActionPanel()
            copySelected()
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
        }
    }

    func escape() {
        if isActionPanelPresented {
            dismissActionPanel()
        } else if aliasDeletionCandidate != nil {
            cancelAliasDeletion()
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
        cancelAliasEditing()
        aliasDeletionCandidate = nil
        resetClipboardImagePreview()
        statusMessage = nil
        focusRequest += 1
        transitionRoute(to: .root, origin: .direct)
    }

    func focusRequestForPopoverDismissal() {
        focusRequest += 1
    }

    func paletteDidHide() {
        searchTask?.cancel()
        searchRevision += 1
        resetClipboardImagePreview()
        urlPreviewService.cancel(resetState: true)
    }

    private func beginEditingAlias(for application: LaunchableApplication) {
        aliasEditorMode = .editing(application.id)
        aliasDraft = application.preference.alias ?? ""
        aliasApplicationQuery = ""
        selectedAliasApplicationID = application.id
        aliasValidationMessage = nil
        selectedID = Self.applicationResultID(application.id)
        aliasFocusRequest += 1
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
        origin: PalettePresentationOrigin
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
        let rememberedSelection = shouldResetSelectionOnEntry(newRoute)
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
        } else if newRoute != .settings {
            refreshSearch(preserveSelection: true)
        }
    }

    private func shouldResetSelectionOnEntry(_ route: PaletteRoute) -> Bool {
        route == .clipboard || route == .snippets
    }

    private func cachedDefaultResults(
        for route: PaletteRoute
    ) -> [CommandResult]? {
        switch route {
        case .root:
            rootDefaultResults
        case .clipboard:
            clipboardDefaultResults
        case .snippets:
            snippetDefaultResults
        case .settings:
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

    private func rootResults(
        query: String,
        applications: [LaunchableApplication]
    ) -> [CommandResult] {
        let applicationResults = applications.map {
            Self.applicationResult($0, query: query)
        }
        let combined = featureResults(query: query) + applicationResults
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
        case .clipboard, .snippet:
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
