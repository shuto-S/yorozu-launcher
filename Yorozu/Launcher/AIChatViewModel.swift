import AppKit
import Foundation
import ImageIO
import Observation
import SwiftUI

@MainActor
@Observable
final class AIChatViewModel {
    static let newChatSelectionID = "__yorozu_new_chat__"
    private static let modelActionIDs: [LauncherActionID] = [
        .aiModelTerra, .aiModelSol, .aiModelLuna, .aiModel4, .aiModel5,
        .aiModel6, .aiModel7, .aiModel8, .aiModel9, .aiModel10,
    ]
    private static let reasoningActionIDs: [LauncherActionID] = [
        .aiReasoning1, .aiReasoning2, .aiReasoning3, .aiReasoning4,
        .aiReasoning5, .aiReasoning6, .aiReasoning7, .aiReasoning8,
        .aiReasoning9, .aiReasoning10,
    ]

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshList(preserveSelection: false)
        }
    }
    private(set) var destination: AIChatDestination = .list(.active)
    private(set) var conversations: [AIConversationSummary] = []
    private(set) var visibleConversations: [AIConversationSummary] = []
    var selectedListID: String?
    private(set) var messages: [AIChatMessage] = []
    private(set) var messageContentRevision = 0
    private(set) var scrollToLatestRequest = 0
    var prompt = ""
    private(set) var attachments: [AIChatAttachment] = []
    private(set) var currentModel: AIModel
    private(set) var currentReasoningEffort: AIReasoningEffort?
    private(set) var enablesWebSearch: Bool
    private(set) var isLoadingConversation = false
    private(set) var isStreaming = false
    private(set) var isSearchingWeb = false
    private(set) var isDeleting = false
    private(set) var focusRequest = 0
    private(set) var composerFocusRequest = 0
    private(set) var hasMoreMessages = false
    private(set) var nextCursor: String?
    private(set) var storageMessage: String?
    private(set) var availableModels: [AIModel]
    private var hasLoadedAvailableModels = false
    private(set) var hasAPIKey = false
    private(set) var credentialStatus: AICredentialStatus = .checking
    private(set) var credentialStatusMessage: String?
    private(set) var isChoosingModel = false
    private(set) var isChoosingReasoningEffort = false
    var errorMessage: String?
    var statusMessage: String?

    var credentialStatusTitle: String {
        if providerID == .codex {
            switch credentialStatus {
            case .checking:
                return "Checking Codex…"
            case .saved:
                return "Signed in with ChatGPT"
            case .notSaved:
                return "ChatGPT sign-in required"
            case .unavailable:
                return "Codex status unavailable"
            }
        }
        switch credentialStatus {
        case .checking:
            return "Checking Keychain…"
        case .saved:
            return "API key saved"
        case .notSaved:
            return "No API key saved"
        case .unavailable:
            return "API key status unavailable"
        }
    }

    var credentialStatusDetail: String {
        if providerID == .codex {
            switch credentialStatus {
            case .checking:
                return "Checking the installed Codex app-server."
            case .saved:
                return "Codex manages authentication without exposing tokens to Yorozu."
            case .notSaved:
                return "Sign in with ChatGPT to use your Codex plan."
            case .unavailable:
                return "Install or select Codex, then refresh the status."
            }
        }
        switch credentialStatus {
        case .checking:
            return "Checking whether Yorozu has a key in macOS Keychain."
        case .saved:
            return "A key is securely stored in macOS Keychain."
        case .notSaved:
            return "Add a key below to enable AI Chat."
        case .unavailable:
            return "Yorozu could not read the Keychain. Try checking again."
        }
    }

    var credentialStatusSymbolName: String {
        switch credentialStatus {
        case .checking:
            "hourglass"
        case .saved:
            "checkmark.circle.fill"
        case .notSaved:
            "key"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    let preferences: AIChatPreferences
    let providerID: AIProviderID
    let providerDescriptor: AIProviderDescriptor

    private let provider: any AIChatProvider
    private let coordinator: AIConversationCoordinator
    @ObservationIgnored
    private let openExternalURL: (URL) -> Bool
    private var hasLoadedCatalog = false
    private var loadTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var credentialStatusTask: Task<Void, Never>?
    private var listSearchTask: Task<Void, Never>?
    private var listSearchRevision = 0
    private var conversationLoadRevision = 0
    private var draftByConversation: [String: String] = [:]
    private var messageCache: [String: [AIChatMessage]] = [:]
    private var messageCacheOrder: [String] = []
    private var activeStreamConversationID: String?
    private let maximumCachedConversationCount = 8
    @ObservationIgnored
    private lazy var pasteboard = SystemPasteboardAccessor()

    var preferencesBinding: Binding<AIModel> {
        Binding(
            get: { self.preferences.defaultModel },
            set: { self.setDefaultModel($0) }
        )
    }

    var reasoningPreferenceBinding: Binding<AIReasoningEffort?> {
        Binding(
            get: { self.preferences.defaultReasoningEffort },
            set: { self.preferences.defaultReasoningEffort = $0 }
        )
    }

    var defaultModelReasoningEfforts: [AIReasoningEffort] {
        resolvedModel(for: preferences.defaultModel)?.supportedReasoningEfforts ?? []
    }

    var availableReasoningEfforts: [AIReasoningEffort] {
        resolvedModel(for: currentModel)?.supportedReasoningEfforts ?? []
    }

    var webSearchPreferenceBinding: Binding<Bool> {
        Binding(
            get: { self.preferences.enablesWebSearchByDefault },
            set: { self.preferences.enablesWebSearchByDefault = $0 }
        )
    }

    init(
        catalog: AIConversationCatalog,
        provider: any AIChatProvider,
        preferences: AIChatPreferences,
        openExternalURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.provider = provider
        coordinator = AIConversationCoordinator(catalog: catalog, provider: provider)
        self.openExternalURL = openExternalURL
        providerID = provider.descriptor.id
        providerDescriptor = provider.descriptor
        self.preferences = preferences
        currentModel = preferences.defaultModel
        currentReasoningEffort = preferences.defaultReasoningEffort
        availableModels = [preferences.defaultModel]
        enablesWebSearch = preferences.enablesWebSearchByDefault
    }

    var listScope: AIChatListScope {
        if case let .list(scope) = destination {
            return scope
        }
        return .active
    }

    var isListVisible: Bool {
        if case .list = destination { return true }
        return false
    }

    var showsNewChatCommand: Bool {
        isListVisible && listScope == .active && query.isEmpty
    }

    var conversationTitle: String {
        switch destination {
        case .newChat:
            "New Chat"
        case let .conversation(id):
            conversations.first(where: { $0.id == id })?.title ?? "Chat"
        case .list:
            "AI Chat · \(providerDescriptor.displayName)"
        }
    }

    var selectedConversation: AIConversationSummary? {
        guard selectedListID != Self.newChatSelectionID else { return nil }
        return conversations.first(where: { $0.id == selectedListID })
    }

    var currentConversation: AIConversationSummary? {
        guard case let .conversation(id) = destination else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    var canSend: Bool {
        !isStreaming
            && !isDeleting
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    var actionPanelTitle: String {
        if isChoosingReasoningEffort {
            return "Change Reasoning"
        }
        if isChoosingModel {
            return "Change Model"
        }
        if isListVisible {
            return selectedConversation?.title ?? "AI Chat"
        }
        return conversationTitle
    }

    var actionItems: [LauncherActionItem] {
        if isChoosingReasoningEffort {
            return availableReasoningEfforts.prefix(10).enumerated().map { index, effort in
                LauncherActionItem(
                    id: Self.reasoningActionIDs[index],
                    title: effort == currentReasoningEffort
                        ? "\(effort.title) ✓"
                        : effort.title,
                    symbolName: "brain",
                    shortcutGlyphs: []
                )
            }
        }
        if isChoosingModel {
            return availableModels.prefix(10).enumerated().map { index, model in
                LauncherActionItem(
                    id: Self.modelActionIDs[index],
                    title: model == currentModel ? "\(model.title) ✓" : model.title,
                    symbolName: model.symbolName,
                    shortcutGlyphs: []
                )
            }
        }

        if isListVisible {
            var items = [
                LauncherActionItem(
                    id: .aiOpenChat,
                    title: selectedConversation == nil ? "New Chat" : "Open Chat",
                    symbolName: selectedConversation == nil ? "square.and.pencil" : "arrow.right",
                    shortcutGlyphs: ["↩"]
                ),
                LauncherActionItem(
                    id: .aiNewChat,
                    title: "New Chat",
                    symbolName: "square.and.pencil",
                    shortcutGlyphs: ["⌘", "N"]
                ),
            ]
            if let selectedConversation {
                if providerID == .codex {
                    items.insert(
                        LauncherActionItem(
                            id: .aiOpenInCodex,
                            title: "Open in Codex",
                            symbolName: "arrow.up.forward.app",
                            shortcutGlyphs: []
                        ),
                        at: 1
                    )
                }
                items.append(
                    LauncherActionItem(
                        id: .aiArchive,
                        title: selectedConversation.isArchived
                            ? "Unarchive Chat"
                            : "Archive Chat",
                        symbolName: selectedConversation.isArchived
                            ? "tray.and.arrow.up"
                            : "archivebox",
                        shortcutGlyphs: []
                    )
                )
                items.append(
                    LauncherActionItem(
                        id: .aiDelete,
                        title: selectedConversation.deletionState == .failed
                            ? "Retry Delete"
                            : "Delete Chat",
                        symbolName: "trash",
                        shortcutGlyphs: ["⌘", "⌫"],
                        role: .destructive
                    )
                )
            }
            items.append(
                LauncherActionItem(
                    id: .aiToggleArchiveScope,
                    title: listScope == .active
                        ? "Show Archived Chats"
                        : "Show Active Chats",
                    symbolName: listScope == .active ? "archivebox" : "bubble.left.and.bubble.right",
                    shortcutGlyphs: []
                )
            )
            return items
        }

        var items = [
            LauncherActionItem(
                id: .aiNewChat,
                title: "New Chat",
                symbolName: "square.and.pencil",
                shortcutGlyphs: ["⌘", "N"]
            ),
            LauncherActionItem(
                id: .aiChangeModel,
                title: "Change Model…",
                symbolName: "cpu",
                shortcutGlyphs: []
            ),
        ]
        if providerDescriptor.capabilities.contains(.reasoningEffort),
           !availableReasoningEfforts.isEmpty {
            items.append(
                LauncherActionItem(
                    id: .aiChangeReasoning,
                    title: "Change Reasoning…",
                    symbolName: "brain",
                    shortcutGlyphs: []
                )
            )
        }
        if providerDescriptor.capabilities.contains(.webSearch) {
            items.append(
                LauncherActionItem(
                    id: .aiToggleWebSearch,
                    title: enablesWebSearch ? "Disable Web Search" : "Enable Web Search",
                    symbolName: enablesWebSearch ? "globe.badge.minus" : "globe",
                    shortcutGlyphs: []
                )
            )
        }
        if providerDescriptor.capabilities.contains(.attachments) {
            items.append(
                LauncherActionItem(
                    id: .aiAttachFiles,
                    title: "Attach Files…",
                    symbolName: "paperclip",
                    shortcutGlyphs: []
                )
            )
        }
        if let currentConversation {
            if providerID == .codex {
                items.insert(
                    LauncherActionItem(
                        id: .aiOpenInCodex,
                        title: "Open in Codex",
                        symbolName: "arrow.up.forward.app",
                        shortcutGlyphs: []
                    ),
                    at: 0
                )
            }
            items.append(
                LauncherActionItem(
                    id: .aiArchive,
                    title: currentConversation.isArchived
                        ? "Unarchive Chat"
                        : "Archive Chat",
                    symbolName: currentConversation.isArchived
                        ? "tray.and.arrow.up"
                        : "archivebox",
                    shortcutGlyphs: []
                )
            )
            items.append(
                LauncherActionItem(
                    id: .aiDelete,
                    title: "Delete Chat",
                    symbolName: "trash",
                    shortcutGlyphs: ["⌘", "⌫"],
                    role: .destructive
                )
            )
        }
        if messages.last(where: { $0.role == .assistant }) != nil {
            items.append(
                LauncherActionItem(
                    id: .aiCopyLastResponse,
                    title: "Copy Last Response",
                    symbolName: "doc.on.doc",
                    shortcutGlyphs: []
                )
            )
        }
        if isStreaming {
            items.append(
                LauncherActionItem(
                    id: .aiStopGenerating,
                    title: "Stop Generating",
                    symbolName: "stop.circle",
                    shortcutGlyphs: ["Esc"]
                )
            )
        }
        return items
    }

    func prepareForPresentation() {
        loadTask?.cancel()
        loadTask = nil
        conversationLoadRevision &+= 1
        isLoadingConversation = false
        isChoosingModel = false
        isChoosingReasoningEffort = false
        errorMessage = nil
        statusMessage = nil
        if isListVisible {
            focusRequest += 1
        } else {
            composerFocusRequest += 1
            scrollToLatestRequest &+= 1
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await loadCatalogIfNeeded()
            guard !Task.isCancelled else { return }
            loadTask = nil
        }
    }

    func paletteDidBecomeVisible() {
        guard !isListVisible else { return }
        scrollToLatestRequest &+= 1
    }

    func shutdown() {
        loadTask?.cancel()
        loadTask = nil
        conversationLoadRevision &+= 1
        streamTask?.cancel()
        streamTask = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        credentialStatusTask?.cancel()
        credentialStatusTask = nil
        listSearchTask?.cancel()
        listSearchTask = nil
        Task { await coordinator.shutdown() }
    }

    func refreshList(
        preserveSelection: Bool = true,
        refreshProvider: Bool = true
    ) {
        listSearchTask?.cancel()
        listSearchRevision &+= 1
        let revision = listSearchRevision
        let previous = preserveSelection ? selectedListID : nil
        let scope = listScope
        let searchQuery = query
        listSearchTask = Task {
            let values = await coordinator.search(query: searchQuery, scope: scope)
            guard !Task.isCancelled,
                  revision == listSearchRevision,
                  isListVisible,
                  listScope == scope,
                  query == searchQuery else {
                return
            }
            visibleConversations = values
            if let previous,
               previous == Self.newChatSelectionID
                || values.contains(where: { $0.id == previous }) {
                selectedListID = previous
            } else if showsNewChatCommand {
                selectedListID = Self.newChatSelectionID
            } else {
                selectedListID = values.first?.id
            }

            guard refreshProvider,
                  coordinator.policies.conversationListAuthority == .provider else {
                return
            }
            if !searchQuery.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            do {
                let snapshot = try await coordinator.refreshIndex(
                    query: searchQuery,
                    scope: scope
                )
                guard !Task.isCancelled,
                      revision == listSearchRevision,
                      isListVisible,
                      listScope == scope,
                      query == searchQuery else {
                    return
                }
                apply(snapshot: snapshot, refreshProvider: false)
            } catch is CancellationError {
                return
            } catch {
                guard revision == listSearchRevision else { return }
                errorMessage = "Couldn’t refresh \(providerDescriptor.displayName) chats."
            }
        }
    }

    func selectListItem(_ id: String) {
        selectedListID = id
    }

    func moveSelection(by delta: Int) {
        guard isListVisible else { return }
        let ids = (showsNewChatCommand ? [Self.newChatSelectionID] : [])
            + visibleConversations.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selectedListID.flatMap(ids.firstIndex) ?? 0
        selectedListID = ids[min(max(index + delta, 0), ids.count - 1)]
    }

    func performPrimaryAction() {
        guard isListVisible else { return }
        if selectedListID == Self.newChatSelectionID {
            beginNewChat()
        } else if let id = selectedListID {
            openConversation(id: id)
        }
    }

    func beginNewChat() {
        saveCurrentDraft()
        loadTask?.cancel()
        loadTask = nil
        conversationLoadRevision &+= 1
        isLoadingConversation = false
        destination = .newChat
        messages = []
        prompt = draftByConversation["new"] ?? ""
        attachments = []
        currentModel = preferredAvailableModel()
        currentReasoningEffort = preferredReasoningEffort(
            for: currentModel,
            preferred: preferences.defaultReasoningEffort
        )
        enablesWebSearch = preferences.enablesWebSearchByDefault
        errorMessage = nil
        statusMessage = nil
        composerFocusRequest += 1
    }

    func openConversation(id: String) {
        saveCurrentDraft()
        destination = .conversation(id)
        prompt = draftByConversation[id] ?? ""
        attachments = []
        errorMessage = nil
        statusMessage = nil
        if let conversation = conversations.first(where: { $0.id == id }) {
            currentModel = availableModels.first {
                $0.rawValue == conversation.model.rawValue
            } ?? (hasLoadedAvailableModels
                ? preferredAvailableModel()
                : conversation.model)
            currentReasoningEffort = preferredReasoningEffort(
                for: currentModel,
                preferred: conversation.reasoningEffort
                    ?? preferences.defaultReasoningEffort
            )
        }
        isLoadingConversation = true
        messages = messageCache[id] ?? []
        scrollToLatestRequest &+= 1
        nextCursor = nil
        hasMoreMessages = false
        loadTask?.cancel()
        conversationLoadRevision &+= 1
        let revision = conversationLoadRevision
        loadTask = Task {
            defer {
                if revision == conversationLoadRevision {
                    isLoadingConversation = false
                }
            }
            do {
                let page = try await coordinator.loadConversation(
                    conversationID: id,
                    limit: 100,
                    after: nil
                )
                guard !Task.isCancelled,
                      revision == conversationLoadRevision,
                      destination == .conversation(id) else {
                    return
                }
                storeCachedMessages(page.messages, for: id)
                messages = page.messages
                nextCursor = page.nextCursor
                hasMoreMessages = page.hasMore
                composerFocusRequest += 1
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = userMessage(for: error)
            }
        }
    }

    func loadOlderMessages() {
        guard case let .conversation(id) = destination,
              hasMoreMessages,
              !isLoadingConversation,
              let nextCursor else {
            return
        }
        isLoadingConversation = true
        conversationLoadRevision &+= 1
        let revision = conversationLoadRevision
        Task {
            defer {
                if revision == conversationLoadRevision {
                    isLoadingConversation = false
                }
            }
            do {
                let page = try await coordinator.loadConversation(
                    conversationID: id,
                    limit: 100,
                    after: nextCursor
                )
                var cached = messageCache[id] ?? messages
                cached.insert(contentsOf: page.messages, at: 0)
                storeCachedMessages(cached, for: id)
                guard revision == conversationLoadRevision,
                      destination == .conversation(id) else {
                    return
                }
                messages = cached
                self.nextCursor = page.nextCursor
                hasMoreMessages = page.hasMore
            } catch {
                if destination == .conversation(id) {
                    errorMessage = userMessage(for: error)
                }
            }
        }
    }

    func returnToList() {
        saveCurrentDraft()
        cacheVisibleMessages()
        loadTask?.cancel()
        loadTask = nil
        conversationLoadRevision &+= 1
        isLoadingConversation = false
        destination = .list(.active)
        query = ""
        isChoosingModel = false
        isChoosingReasoningEffort = false
        focusRequest += 1
        refreshList(preserveSelection: true)
    }

    func handleEscape() -> Bool {
        if isChoosingModel || isChoosingReasoningEffort {
            isChoosingModel = false
            isChoosingReasoningEffort = false
            return true
        }
        if isStreaming {
            stopGenerating()
            return true
        }
        if !isListVisible {
            returnToList()
            return true
        }
        return false
    }

    func send() {
        guard canSend else { return }
        let originalPrompt = prompt
        let originalAttachments = attachments
        let requestModel = currentModel
        let requestReasoningEffort = currentReasoningEffort
        let requestEnablesWebSearch = enablesWebSearch
        prompt = ""
        attachments = []
        errorMessage = nil
        statusMessage = nil
        isSearchingWeb = false
        isStreaming = true

        streamTask = Task {
            var didStartGenerationRequest = false
            do {
                guard availableModels.contains(requestModel) else {
                    throw AIChatError.modelUnavailable
                }
                let conversationID = try await ensureConversation(
                    firstPrompt: originalPrompt,
                    model: requestModel
                )
                activeStreamConversationID = conversationID
                if messageCache[conversationID] == nil {
                    storeCachedMessages(messages, for: conversationID)
                }
                let uploaded = try await upload(
                    originalAttachments
                )
                let userMessage = AIChatMessage(
                    id: "local-user-\(UUID().uuidString)",
                    role: .user,
                    text: originalPrompt,
                    citations: [],
                    attachments: uploaded.map {
                        AIChatAttachment(
                            id: $0.fileID,
                            kind: $0.kind,
                            filename: $0.filename,
                            fileID: $0.fileID,
                            localURL: nil,
                            byteCount: nil
                        )
                    },
                    isStreaming: false
                )
                updateMessages(for: conversationID) {
                    $0.append(userMessage)
                }
                let assistantID = "local-assistant-\(UUID().uuidString)"
                updateMessages(for: conversationID) {
                    $0.append(
                        AIChatMessage(
                            id: assistantID,
                            role: .assistant,
                            text: "",
                            citations: [],
                            attachments: [],
                            isStreaming: true
                        )
                    )
                }
                let request = AIChatSendRequest(
                    conversationID: conversationID,
                    model: requestModel,
                    reasoningEffort: requestReasoningEffort,
                    prompt: originalPrompt,
                    attachments: uploaded,
                    enablesWebSearch: requestEnablesWebSearch,
                    clientRequestID: UUID().uuidString
                )
                var pendingDelta = ""
                let clock = ContinuousClock()
                var lastPublishedAt = clock.now
                didStartGenerationRequest = true
                streamEvents: for try await event in coordinator.streamResponse(request: request) {
                    try Task.checkCancellation()
                    switch event {
                    case .responseCreated:
                        break
                    case .webSearchStarted:
                        isSearchingWeb = true
                    case let .textDelta(delta):
                        pendingDelta += delta
                        let now = clock.now
                        let elapsed = lastPublishedAt.duration(to: now)
                        if elapsed >= .milliseconds(33) {
                            append(
                                delta: pendingDelta,
                                to: assistantID,
                                conversationID: conversationID
                            )
                            pendingDelta = ""
                            lastPublishedAt = now
                        }
                    case let .citation(citation):
                        append(
                            citation: citation,
                            to: assistantID,
                            conversationID: conversationID
                        )
                    case .completed:
                        break streamEvents
                    }
                }
                if !pendingDelta.isEmpty {
                    append(
                        delta: pendingDelta,
                        to: assistantID,
                        conversationID: conversationID
                    )
                }
                finishStreamingMessage(
                    id: assistantID,
                    conversationID: conversationID
                )
                isStreaming = false
                isSearchingWeb = false
                activeStreamConversationID = nil
                try await refreshAfterSuccessfulResponse(
                    conversationID: conversationID,
                    model: requestModel,
                    reasoningEffort: requestReasoningEffort
                )
            } catch is CancellationError {
                markLastAssistantStopped(conversationID: activeStreamConversationID)
                isStreaming = false
                isSearchingWeb = false
                activeStreamConversationID = nil
            } catch {
                let failedConversationID = activeStreamConversationID
                markLastAssistantStopped(conversationID: failedConversationID)
                if let failedConversationID {
                    await reconcileAfterStreamFailure(
                        conversationID: failedConversationID
                    )
                }
                if !didStartGenerationRequest {
                    if let failedConversationID,
                       destination == .conversation(failedConversationID) {
                        prompt = originalPrompt
                        attachments = originalAttachments
                    } else if let failedConversationID {
                        draftByConversation[failedConversationID] = originalPrompt
                    } else {
                        prompt = originalPrompt
                        attachments = originalAttachments
                    }
                }
                isStreaming = false
                isSearchingWeb = false
                activeStreamConversationID = nil
                errorMessage = userMessage(for: error)
            }
        }
    }

    func stopGenerating() {
        let conversationID = activeStreamConversationID
        streamTask?.cancel()
        streamTask = nil
        if let conversationID {
            Task { await coordinator.stopGeneration(conversationID: conversationID) }
        }
    }

    func toggleWebSearch() {
        enablesWebSearch.toggle()
        statusMessage = enablesWebSearch ? "Web Search enabled." : "Web Search disabled."
    }

    func dismissNotice() {
        errorMessage = nil
        statusMessage = nil
    }

    func beginChoosingModel() {
        isChoosingModel = true
        isChoosingReasoningEffort = false
    }

    func beginChoosingReasoningEffort() {
        guard !availableReasoningEfforts.isEmpty else { return }
        isChoosingModel = false
        isChoosingReasoningEffort = true
    }

    func cancelActionNavigation() {
        isChoosingModel = false
        isChoosingReasoningEffort = false
    }

    func chooseModel(_ model: AIModel) {
        let previousEffort = currentReasoningEffort
        currentModel = resolvedModel(for: model) ?? model
        currentReasoningEffort = preferredReasoningEffort(
            for: currentModel,
            preferred: previousEffort
        )
        isChoosingModel = false
        isChoosingReasoningEffort = false
        statusMessage = "\(model.title) will be used for the next message."
        if var conversation = currentConversation {
            conversation.model = currentModel
            conversation.isModelAuthoritative = true
            conversation.reasoningEffort = currentReasoningEffort
            conversation.isReasoningEffortAuthoritative = true
            conversation.updatedAt = Date()
            Task {
                do {
                    try await coordinator.updateConversation(
                        conversationID: conversation.id,
                        title: conversation.title,
                        model: currentModel,
                        isArchived: conversation.isArchived
                    )
                    apply(snapshot: await coordinator.save(conversation))
                } catch {
                    errorMessage = userMessage(for: error)
                }
            }
        }
    }

    func chooseReasoningEffort(_ effort: AIReasoningEffort) {
        guard availableReasoningEfforts.contains(effort) else { return }
        currentReasoningEffort = effort
        isChoosingReasoningEffort = false
        isChoosingModel = false
        statusMessage = "\(effort.title) reasoning will be used for the next message."
        guard var conversation = currentConversation else { return }
        conversation.reasoningEffort = effort
        conversation.isReasoningEffortAuthoritative = true
        conversation.updatedAt = Date()
        Task {
            apply(snapshot: await coordinator.save(conversation))
        }
    }

    func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            do {
                attachments = try await Task.detached(priority: .userInitiated) {
                    try Self.validatedAttachments(urls)
                }.value
            } catch {
                errorMessage = userMessage(for: error)
            }
        }
    }

    func removeAttachment(id: String) {
        attachments.removeAll(where: { $0.id == id })
    }

    func copyLastResponse() {
        guard let message = messages.last(where: { $0.role == .assistant }),
              !message.text.isEmpty else {
            return
        }
        copyMessage(message.text)
    }

    func copyMessage(_ text: String) {
        guard !text.isEmpty,
              case let .captured(original) = pasteboard.snapshot() else {
            errorMessage = "The current clipboard is too large to preserve safely."
            return
        }
        switch pasteboard.replace(with: .text(text), preserving: original) {
        case .written:
            statusMessage = "Response copied."
        case .preservationLimitExceeded:
            errorMessage = "The current clipboard is too large to preserve safely."
        case .invalidContent, .writeFailedAndRestored, .writeFailedAndRestoreFailed:
            errorMessage = "The response could not be copied."
        }
    }

    func toggleArchiveScope() {
        destination = .list(listScope == .active ? .archived : .active)
        query = ""
        focusRequest += 1
        refreshList(preserveSelection: false)
    }

    func archiveSelectedConversation() {
        let conversation = isListVisible ? selectedConversation : currentConversation
        guard var conversation else { return }
        let targetArchiveState = !conversation.isArchived
        Task {
            do {
                try await coordinator.setConversationArchived(
                    conversationID: conversation.id,
                    title: conversation.title,
                    model: conversation.model,
                    isArchived: targetArchiveState
                )
                conversation.isArchived = targetArchiveState
                conversation.updatedAt = Date()
                apply(snapshot: await coordinator.save(conversation))
                destination = .list(targetArchiveState ? .active : .archived)
                refreshList(preserveSelection: false)
                statusMessage = targetArchiveState ? "Chat archived." : "Chat unarchived."
            } catch {
                errorMessage = userMessage(for: error)
            }
        }
    }

    var deletionTarget: AIConversationSummary? {
        isListVisible ? selectedConversation : currentConversation
    }

    func deleteConversation(
        reference: AIConversationReference,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        guard !isDeleting,
              var conversation = conversations.first(where: { $0.reference == reference })
                ?? (currentConversation?.reference == reference ? currentConversation : nil) else {
            completion(false, "The chat is no longer available.")
            return
        }
        isDeleting = true
        conversation.isArchived = true
        conversation.deletionState = .pending
        conversation.updatedAt = Date()
        Task {
            apply(snapshot: await coordinator.save(conversation))
            do {
                try await coordinator.deleteConversationCompletely(
                    conversationID: conversation.id
                )
                apply(snapshot: await coordinator.remove(id: conversation.id))
                destination = .list(.active)
                refreshList(preserveSelection: false)
                statusMessage = "Chat deleted."
                completion(true, nil)
            } catch {
                conversation.deletionState = .failed
                conversation.updatedAt = Date()
                apply(snapshot: await coordinator.save(conversation))
                destination = .list(.archived)
                refreshList(preserveSelection: false)
                errorMessage = AIChatError.deletionFailed.localizedDescription
                completion(false, AIChatError.deletionFailed.localizedDescription)
            }
            isDeleting = false
        }
    }

    func loadCredentialStatus() {
        credentialStatusTask?.cancel()
        credentialStatus = .checking
        observeAuthenticationUpdatesIfNeeded()
        credentialStatusTask = Task { [weak self] in
            guard let self else { return }
            let state = await provider.authenticationState()
            guard !Task.isCancelled else { return }
            apply(authenticationState: state)
            credentialStatusTask = nil
        }
    }

    private func observeAuthenticationUpdatesIfNeeded() {
        guard authenticationTask == nil,
              let manager = provider as? any CodexAuthenticationManaging else {
            return
        }
        authenticationTask = Task {
            let updates = await manager.authenticationUpdates()
            for await state in updates {
                guard !Task.isCancelled else { return }
                apply(authenticationState: state)
            }
        }
    }

    private func apply(authenticationState state: AIAuthenticationState) {
        switch state {
        case .checking:
            credentialStatus = .checking
        case let .authenticated(detail):
            hasAPIKey = providerID == .openAIAPI
            credentialStatus = .saved
            credentialStatusMessage = detail
        case .authenticationRequired:
            hasAPIKey = false
            credentialStatus = .notSaved
            credentialStatusMessage = nil
        case let .failed(message):
            hasAPIKey = false
            credentialStatus = .unavailable
            credentialStatusMessage = message
        }
    }

    func saveAPIKey(
        _ value: String,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        let draft = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            completion(false, "Enter an API key first.")
            return
        }
        Task {
            do {
                guard let provider = provider as? any OpenAIAPIKeyManaging else {
                    throw AIChatError.authenticationFailed
                }
                try await provider.saveAPIKey(draft)
                hasAPIKey = true
                credentialStatus = .saved
                credentialStatusMessage = "API key saved securely."
                await testConnection()
                completion(true, nil)
            } catch {
                credentialStatus = hasAPIKey ? .saved : .unavailable
                credentialStatusMessage = "The API key could not be saved."
                completion(false, credentialStatusMessage)
            }
        }
    }

    func removeAPIKey(completion: @escaping @MainActor (Bool, String?) -> Void) {
        Task {
            do {
                guard let provider = provider as? any OpenAIAPIKeyManaging else {
                    throw AIChatError.authenticationFailed
                }
                try await provider.removeAPIKey()
                hasAPIKey = false
                credentialStatus = .notSaved
                credentialStatusMessage = "API key removed."
                completion(true, nil)
            } catch {
                credentialStatus = hasAPIKey ? .saved : .unavailable
                credentialStatusMessage = "The API key could not be removed."
                completion(false, credentialStatusMessage)
            }
        }
    }

    func signInWithChatGPT() {
        Task {
            do {
                guard let manager = provider as? any CodexAuthenticationManaging else {
                    throw AIChatError.authenticationFailed
                }
                let url = try await manager.signInWithChatGPT()
                NSWorkspace.shared.open(url)
                credentialStatusMessage = "Complete ChatGPT sign-in in your browser, then check again."
            } catch {
                credentialStatusMessage = userMessage(for: error)
            }
        }
    }

    func signOut(completion: @escaping @MainActor (Bool, String?) -> Void) {
        Task {
            do {
                guard let manager = provider as? any CodexAuthenticationManaging else {
                    throw AIChatError.authenticationFailed
                }
                try await manager.signOut()
                credentialStatus = .notSaved
                credentialStatusMessage = "Signed out of ChatGPT."
                completion(true, nil)
            } catch {
                credentialStatusMessage = userMessage(for: error)
                completion(false, credentialStatusMessage)
            }
        }
    }

    func updateCodexExecutablePath(
        _ path: String,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        Task {
            guard let manager = provider as? any CodexAuthenticationManaging else {
                completion(false, "Codex is unavailable.")
                return
            }
            await manager.updateExecutablePath(path)
            loadCredentialStatus()
            completion(true, nil)
        }
    }

    func testConnection() async {
        do {
            applyAvailableModels(try await coordinator.availableModels())
            if availableModels.isEmpty {
                credentialStatusMessage = "Connected, but no models are available."
            } else {
                credentialStatusMessage = "Connected to \(providerDescriptor.displayName)."
            }
        } catch {
            credentialStatusMessage = userMessage(for: error)
        }
    }

    func loadModelMetadataForSettings() async {
        do {
            applyAvailableModels(try await coordinator.availableModels())
        } catch {
            // Connection status already owns the user-facing error state in Settings.
        }
    }

    func performAction(_ action: LauncherActionID) {
        if let index = Self.modelActionIDs.firstIndex(of: action),
           availableModels.indices.contains(index) {
            chooseModel(availableModels[index])
            return
        }
        if let index = Self.reasoningActionIDs.firstIndex(of: action),
           availableReasoningEfforts.indices.contains(index) {
            chooseReasoningEffort(availableReasoningEfforts[index])
            return
        }
        switch action {
        case .aiOpenChat:
            performPrimaryAction()
        case .aiOpenInCodex:
            openSelectedConversationInCodex()
        case .aiNewChat:
            beginNewChat()
        case .aiChangeModel:
            beginChoosingModel()
        case .aiChangeReasoning:
            beginChoosingReasoningEffort()
        case .aiModelTerra, .aiModelSol, .aiModelLuna,
             .aiModel4, .aiModel5, .aiModel6, .aiModel7,
             .aiModel8, .aiModel9, .aiModel10:
            break
        case .aiReasoning1, .aiReasoning2, .aiReasoning3, .aiReasoning4,
             .aiReasoning5, .aiReasoning6, .aiReasoning7, .aiReasoning8,
             .aiReasoning9, .aiReasoning10:
            break
        case .aiToggleWebSearch:
            toggleWebSearch()
        case .aiAttachFiles:
            attachFiles()
        case .aiArchive:
            archiveSelectedConversation()
        case .aiDelete:
            break
        case .aiToggleArchiveScope:
            toggleArchiveScope()
        case .aiCopyLastResponse:
            copyLastResponse()
        case .aiStopGenerating:
            stopGenerating()
        default:
            break
        }
    }

    private func openSelectedConversationInCodex() {
        guard providerID == .codex else { return }
        let conversation = isListVisible ? selectedConversation : currentConversation
        guard let conversation,
              let url = Self.codexThreadURL(
                providerConversationID: conversation.providerConversationID
              ) else {
            errorMessage = "This chat can’t be opened in Codex."
            return
        }
        guard openExternalURL(url) else {
            errorMessage = "Codex couldn’t open this chat."
            return
        }
        errorMessage = nil
    }

    private static func codexThreadURL(providerConversationID: String) -> URL? {
        let threadID = providerConversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(threadID)"
        return components.url
    }

    private func loadCatalogIfNeeded() async {
        let isInitialLoad = !hasLoadedCatalog
        if isInitialLoad {
            hasLoadedCatalog = true
            apply(snapshot: await coordinator.loadIndex(), refreshProvider: false)
        }
        loadCredentialStatus()
        Task { await testConnection() }
        refreshList(preserveSelection: !isInitialLoad)
    }

    private func preferredAvailableModel() -> AIModel {
        let preferred = preferences.defaultModel
        return availableModels.first(where: { $0.rawValue == preferred.rawValue })
            ?? availableModels.first(where: \.isDefault)
            ?? availableModels.first
            ?? preferred
    }

    private func resolvedModel(for model: AIModel) -> AIModel? {
        availableModels.first(where: { $0.rawValue == model.rawValue })
    }

    private func applyAvailableModels(_ models: [AIModel]) {
        availableModels = models
        hasLoadedAvailableModels = true
        if let resolved = resolvedModel(for: currentModel) {
            currentModel = resolved
        } else if let fallback = availableModels.first(where: \.isDefault)
            ?? availableModels.first {
            currentModel = fallback
            preferences.defaultModel = fallback
        }
        currentReasoningEffort = preferredReasoningEffort(
            for: currentModel,
            preferred: currentReasoningEffort
                ?? preferences.defaultReasoningEffort
        )
        if let defaultModel = resolvedModel(for: preferences.defaultModel),
           let preferred = preferences.defaultReasoningEffort,
           !defaultModel.supportedReasoningEfforts.contains(preferred) {
            preferences.defaultReasoningEffort = nil
        }
    }

    private func preferredReasoningEffort(
        for model: AIModel,
        preferred: AIReasoningEffort?
    ) -> AIReasoningEffort? {
        let resolved = resolvedModel(for: model) ?? model
        if resolved.supportedReasoningEfforts.isEmpty {
            return preferred ?? resolved.defaultReasoningEffort
        }
        if let preferred,
           let supported = resolved.supportedReasoningEfforts.first(
               where: { $0.rawValue == preferred.rawValue }
           ) {
            return supported
        }
        if let modelDefault = resolved.defaultReasoningEffort {
            return resolved.supportedReasoningEfforts.first(
                where: { $0.rawValue == modelDefault.rawValue }
            ) ?? modelDefault
        }
        return resolved.supportedReasoningEfforts.first
    }

    private func setDefaultModel(_ model: AIModel) {
        preferences.defaultModel = model
        guard let selected = preferences.defaultReasoningEffort,
              !defaultModelReasoningEfforts.contains(selected) else {
            return
        }
        preferences.defaultReasoningEffort = nil
    }

    private func ensureConversation(
        firstPrompt: String,
        model: AIModel
    ) async throws -> String {
        if case let .conversation(id) = destination {
            return id
        }
        let title = AIConversationSummary.title(from: firstPrompt)
        let id = try await coordinator.createConversation(
            title: title,
            model: model
        )
        let now = Date()
        let conversation = AIConversationSummary(
            providerID: providerID,
            providerConversationID: id,
            title: title,
            model: model,
            reasoningEffort: currentReasoningEffort,
            isArchived: false,
            deletionState: nil,
            createdAt: now,
            lastMessageAt: now,
            updatedAt: now
        )
        apply(snapshot: await coordinator.save(conversation))
        destination = .conversation(id)
        draftByConversation.removeValue(forKey: "new")
        return id
    }

    private func upload(
        _ attachments: [AIChatAttachment]
    ) async throws -> [AIUploadedAttachment] {
        var uploaded: [AIUploadedAttachment] = []
        for attachment in attachments {
            uploaded.append(
                try await coordinator.uploadAttachment(attachment)
            )
        }
        return uploaded
    }

    private func reconcileAfterStreamFailure(
        conversationID: String
    ) async {
        guard let page = try? await coordinator.loadConversation(
            conversationID: conversationID,
            limit: 100,
            after: nil
        ) else {
            return
        }
        storeCachedMessages(page.messages, for: conversationID)
        guard destination == .conversation(conversationID) else { return }
        messages = page.messages
        nextCursor = page.nextCursor
        hasMoreMessages = page.hasMore
    }

    private func refreshAfterSuccessfulResponse(
        conversationID: String,
        model: AIModel,
        reasoningEffort: AIReasoningEffort?
    ) async throws {
        let page = try await coordinator.loadConversation(
            conversationID: conversationID,
            limit: 100,
            after: nil
        )
        storeCachedMessages(page.messages, for: conversationID)
        if destination == .conversation(conversationID) {
            messages = page.messages
        }
        nextCursor = page.nextCursor
        hasMoreMessages = page.hasMore
        guard var conversation = conversations.first(where: { $0.id == conversationID }) else {
            return
        }
        let now = Date()
        conversation.lastMessageAt = now
        conversation.updatedAt = now
        conversation.model = model
        conversation.reasoningEffort = reasoningEffort
        conversation.isReasoningEffortAuthoritative = true
        apply(snapshot: await coordinator.save(conversation))
    }

    private func append(
        delta: String,
        to messageID: String,
        conversationID: String
    ) {
        updateMessages(for: conversationID) { values in
            guard let index = values.firstIndex(where: { $0.id == messageID }) else { return }
            values[index].text += delta
        }
    }

    private func append(
        citation: AIChatCitation,
        to messageID: String,
        conversationID: String
    ) {
        updateMessages(for: conversationID) { values in
            guard let index = values.firstIndex(where: { $0.id == messageID }),
                  !values[index].citations.contains(where: { $0.id == citation.id }) else {
                return
            }
            values[index].citations.append(citation)
        }
    }

    private func finishStreamingMessage(
        id: String,
        conversationID: String
    ) {
        updateMessages(for: conversationID) { values in
            guard let index = values.firstIndex(where: { $0.id == id }) else { return }
            values[index].isStreaming = false
        }
    }

    private func markLastAssistantStopped(conversationID: String?) {
        guard let conversationID else { return }
        updateMessages(for: conversationID) { values in
            guard let index = values.lastIndex(where: { $0.role == .assistant }) else { return }
            values[index].isStreaming = false
        }
    }

    private func saveCurrentDraft() {
        switch destination {
        case .newChat:
            draftByConversation["new"] = prompt
        case let .conversation(id):
            draftByConversation[id] = prompt
        case .list:
            break
        }
    }

    private func cacheVisibleMessages() {
        guard case let .conversation(id) = destination else { return }
        storeCachedMessages(messages, for: id)
    }

    private func updateMessages(
        for conversationID: String,
        _ update: (inout [AIChatMessage]) -> Void
    ) {
        var values: [AIChatMessage]
        if let cached = messageCache[conversationID] {
            values = cached
        } else if destination == .conversation(conversationID) {
            values = messages
        } else {
            values = []
        }
        update(&values)
        storeCachedMessages(values, for: conversationID)
        if destination == .conversation(conversationID) {
            messageContentRevision &+= 1
            messages = values
        }
    }

    private func storeCachedMessages(
        _ values: [AIChatMessage],
        for conversationID: String
    ) {
        messageCache[conversationID] = values
        messageCacheOrder.removeAll { $0 == conversationID }
        messageCacheOrder.append(conversationID)

        while messageCacheOrder.count > maximumCachedConversationCount {
            guard let evictionIndex = messageCacheOrder.firstIndex(where: { candidate in
                candidate != activeStreamConversationID
                    && destination != .conversation(candidate)
            }) else {
                break
            }
            let evictedID = messageCacheOrder.remove(at: evictionIndex)
            messageCache.removeValue(forKey: evictedID)
        }
    }

    private nonisolated static func validatedAttachments(
        _ urls: [URL]
    ) throws -> [AIChatAttachment] {
        guard urls.count <= 5 else {
            throw AIChatError.attachmentLimitExceeded
        }
        let allowedExtensions: Set<String> = [
            "png", "jpg", "jpeg", "webp", "gif",
            "pdf", "txt", "md", "markdown", "json", "html", "xml",
            "csv", "tsv", "xls", "xlsx", "doc", "docx", "rtf",
            "ppt", "pptx", "swift", "py", "js", "ts", "css", "sql",
        ]
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
        var total = 0
        var result: [AIChatAttachment] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else {
                throw AIChatError.invalidAttachment
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size < 50 * 1_024 * 1_024 else {
                throw AIChatError.attachmentLimitExceeded
            }
            total += size
            guard total <= 50 * 1_024 * 1_024 else {
                throw AIChatError.attachmentLimitExceeded
            }
            if imageExtensions.contains(ext) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      ext != "gif" || CGImageSourceGetCount(source) == 1 else {
                    throw AIChatError.invalidAttachment
                }
            }
            result.append(
                AIChatAttachment(
                    id: UUID().uuidString,
                    kind: imageExtensions.contains(ext) ? .image : .file,
                    filename: url.lastPathComponent,
                    fileID: nil,
                    localURL: url,
                    byteCount: size
                )
            )
        }
        return result
    }

    private func apply(
        snapshot: FeatureSnapshot<AIConversationSummary>,
        refreshProvider: Bool = false
    ) {
        conversations = snapshot.values
        storageMessage = snapshot.message
        refreshList(preserveSelection: true, refreshProvider: refreshProvider)
    }

    private func userMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return "The AI request could not be completed."
    }

    static func disabled() -> AIChatViewModel {
        let suiteName = "com.yorozu.app.ai-disabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AIChatViewModel(
            catalog: AIConversationCatalog(providerID: .openAIAPI, store: nil),
            provider: DisabledAIChatProvider(),
            preferences: AIChatPreferences(defaults: defaults)
        )
    }
}

private extension AIModel {
    var symbolName: String { isDefault ? "checkmark.circle" : "cpu" }
}

@MainActor
final class AIChatViewModelStore {
    private var viewModels: [AIProviderID: AIChatViewModel]
    private let providerOrder: [AIProviderID]
    let providerPreferences: AIProviderPreferences

    init(
        viewModels: [AIChatViewModel],
        providerPreferences: AIProviderPreferences
    ) {
        providerOrder = viewModels.map(\.providerID)
        self.viewModels = Dictionary(
            uniqueKeysWithValues: viewModels.map { ($0.providerID, $0) }
        )
        self.providerPreferences = providerPreferences
    }

    func viewModel(for providerID: AIProviderID) -> AIChatViewModel? {
        viewModels[providerID]
    }

    var orderedViewModels: [AIChatViewModel] {
        providerOrder.compactMap { viewModels[$0] }
    }

    func resolvedProviderID(preferred providerID: AIProviderID?) -> AIProviderID? {
        if let providerID, viewModels[providerID] != nil {
            return providerID
        }
        if let defaultProviderID = providerPreferences.defaultProviderID,
           viewModels[defaultProviderID] != nil {
            return defaultProviderID
        }
        return providerOrder.first(where: { viewModels[$0] != nil })
    }

    func defaultViewModel() -> AIChatViewModel? {
        providerPreferences.defaultProviderID.flatMap { viewModels[$0] }
            ?? orderedViewModels.first
    }

    func shutdown() {
        viewModels.values.forEach { $0.shutdown() }
    }
}
