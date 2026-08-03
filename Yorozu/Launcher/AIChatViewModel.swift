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
    var prompt = ""
    private(set) var attachments: [AIChatAttachment] = []
    private(set) var currentModel: AIModel
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
    private(set) var hasAPIKey = false
    private(set) var credentialStatus: AICredentialStatus = .checking
    private(set) var credentialStatusMessage: String?
    private(set) var isChoosingModel = false
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

    private let catalog: AIConversationCatalog
    private let provider: any AIChatProvider
    private var hasLoadedCatalog = false
    private var loadTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
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
            set: { self.preferences.defaultModel = $0 }
        )
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
        preferences: AIChatPreferences
    ) {
        self.catalog = catalog
        self.provider = provider
        providerID = provider.descriptor.id
        providerDescriptor = provider.descriptor
        self.preferences = preferences
        currentModel = preferences.defaultModel
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
        if isChoosingModel {
            return "Change Model"
        }
        if isListVisible {
            return selectedConversation?.title ?? "AI Chat"
        }
        return conversationTitle
    }

    var actionItems: [LauncherActionItem] {
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
        errorMessage = nil
        statusMessage = nil
        if isListVisible {
            focusRequest += 1
        } else {
            composerFocusRequest += 1
        }
        Task {
            await loadCatalogIfNeeded()
        }
    }

    func shutdown() {
        loadTask?.cancel()
        loadTask = nil
        conversationLoadRevision &+= 1
        streamTask?.cancel()
        streamTask = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        listSearchTask?.cancel()
        listSearchTask = nil
        Task { await provider.shutdown() }
    }

    func refreshList(preserveSelection: Bool = true) {
        listSearchTask?.cancel()
        listSearchRevision &+= 1
        let revision = listSearchRevision
        let previous = preserveSelection ? selectedListID : nil
        let scope = listScope
        let searchQuery = query
        listSearchTask = Task {
            let values = await catalog.search(query: searchQuery, scope: scope)
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
            currentModel = conversation.model
        }
        isLoadingConversation = true
        messages = messageCache[id] ?? []
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
                let page = try await provider.loadConversation(
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
                let page = try await provider.loadConversation(
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
        focusRequest += 1
        refreshList(preserveSelection: true)
    }

    func handleEscape() -> Bool {
        if isChoosingModel {
            isChoosingModel = false
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
                    prompt: originalPrompt,
                    attachments: uploaded,
                    enablesWebSearch: requestEnablesWebSearch,
                    clientRequestID: UUID().uuidString
                )
                var pendingDelta = ""
                let clock = ContinuousClock()
                var lastPublishedAt = clock.now
                didStartGenerationRequest = true
                streamEvents: for try await event in provider.streamResponse(request: request) {
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
                    model: requestModel
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
            Task { await provider.stopGeneration(conversationID: conversationID) }
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
    }

    func cancelActionNavigation() {
        isChoosingModel = false
    }

    func chooseModel(_ model: AIModel) {
        currentModel = model
        isChoosingModel = false
        statusMessage = "\(model.title) will be used for the next message."
        if var conversation = currentConversation {
            conversation.model = model
            conversation.updatedAt = Date()
            Task {
                do {
                    try await provider.updateConversation(
                        conversationID: conversation.id,
                        title: conversation.title,
                        model: model,
                        isArchived: conversation.isArchived
                    )
                    apply(snapshot: await catalog.save(conversation))
                } catch {
                    errorMessage = userMessage(for: error)
                }
            }
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
                try await provider.setConversationArchived(
                    conversationID: conversation.id,
                    title: conversation.title,
                    model: conversation.model,
                    isArchived: targetArchiveState
                )
                conversation.isArchived = targetArchiveState
                conversation.updatedAt = Date()
                apply(snapshot: await catalog.save(conversation))
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
            apply(snapshot: await catalog.save(conversation))
            do {
                try await provider.deleteConversationCompletely(
                    conversationID: conversation.id
                )
                apply(snapshot: await catalog.remove(id: conversation.id))
                destination = .list(.active)
                refreshList(preserveSelection: false)
                statusMessage = "Chat deleted."
                completion(true, nil)
            } catch {
                conversation.deletionState = .failed
                conversation.updatedAt = Date()
                apply(snapshot: await catalog.save(conversation))
                destination = .list(.archived)
                refreshList(preserveSelection: false)
                errorMessage = AIChatError.deletionFailed.localizedDescription
                completion(false, AIChatError.deletionFailed.localizedDescription)
            }
            isDeleting = false
        }
    }

    func loadCredentialStatus() {
        credentialStatus = .checking
        observeAuthenticationUpdatesIfNeeded()
        Task {
            apply(authenticationState: await provider.authenticationState())
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
            availableModels = try await provider.availableModels()
            if !availableModels.contains(currentModel),
               let fallback = availableModels.first(where: \.isDefault)
                    ?? availableModels.first {
                currentModel = fallback
                preferences.defaultModel = fallback
            }
            if availableModels.isEmpty {
                credentialStatusMessage = "Connected, but no models are available."
            } else {
                credentialStatusMessage = "Connected to \(providerDescriptor.displayName)."
            }
        } catch {
            credentialStatusMessage = userMessage(for: error)
        }
    }

    func performAction(_ action: LauncherActionID) {
        if let index = Self.modelActionIDs.firstIndex(of: action),
           availableModels.indices.contains(index) {
            chooseModel(availableModels[index])
            return
        }
        switch action {
        case .aiOpenChat:
            performPrimaryAction()
        case .aiNewChat:
            beginNewChat()
        case .aiChangeModel:
            beginChoosingModel()
        case .aiModelTerra, .aiModelSol, .aiModelLuna,
             .aiModel4, .aiModel5, .aiModel6, .aiModel7,
             .aiModel8, .aiModel9, .aiModel10:
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

    private func loadCatalogIfNeeded() async {
        let isInitialLoad = !hasLoadedCatalog
        if isInitialLoad {
            hasLoadedCatalog = true
            apply(snapshot: await catalog.load())
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

    private func ensureConversation(
        firstPrompt: String,
        model: AIModel
    ) async throws -> String {
        if case let .conversation(id) = destination {
            return id
        }
        let title = AIConversationSummary.title(from: firstPrompt)
        let id = try await provider.createConversation(
            title: title,
            model: model
        )
        let now = Date()
        let conversation = AIConversationSummary(
            providerID: providerID,
            providerConversationID: id,
            title: title,
            model: model,
            isArchived: false,
            deletionState: nil,
            createdAt: now,
            lastMessageAt: now,
            updatedAt: now
        )
        apply(snapshot: await catalog.save(conversation))
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
                try await provider.uploadAttachment(attachment)
            )
        }
        return uploaded
    }

    private func reconcileAfterStreamFailure(
        conversationID: String
    ) async {
        guard let page = try? await provider.loadConversation(
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
        model: AIModel
    ) async throws {
        let page = try await provider.loadConversation(
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
        apply(snapshot: await catalog.save(conversation))
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
        snapshot: FeatureSnapshot<AIConversationSummary>
    ) {
        conversations = snapshot.values
        storageMessage = snapshot.message
        refreshList(preserveSelection: true)
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
    let providerPreferences: AIProviderPreferences

    init(
        viewModels: [AIChatViewModel],
        providerPreferences: AIProviderPreferences
    ) {
        self.viewModels = Dictionary(
            uniqueKeysWithValues: viewModels.map { ($0.providerID, $0) }
        )
        self.providerPreferences = providerPreferences
    }

    func viewModel(for providerID: AIProviderID) -> AIChatViewModel? {
        viewModels[providerID]
    }

    func defaultViewModel() -> AIChatViewModel? {
        providerPreferences.defaultProviderID.flatMap { viewModels[$0] }
            ?? viewModels.values.first
    }

    func shutdown() {
        viewModels.values.forEach { $0.shutdown() }
    }
}
