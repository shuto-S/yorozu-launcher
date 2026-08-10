import Foundation

actor AIConversationCatalog {
    let providerID: AIProviderID
    private let store: LauncherStore?
    private var conversations: [AIConversationSummary] = []
    private var hasLoaded = false

    init(
        providerID: AIProviderID,
        store: LauncherStore?,
        initialConversations: [AIConversationSummary] = []
    ) {
        self.providerID = providerID
        self.store = store
        conversations = initialConversations.filter { $0.providerID == providerID }.sorted {
            if $0.lastMessageAt != $1.lastMessageAt {
                return $0.lastMessageAt > $1.lastMessageAt
            }
            return $0.id < $1.id
        }
    }

    func load() async -> FeatureSnapshot<AIConversationSummary> {
        if hasLoaded {
            return snapshot()
        }
        hasLoaded = true
        guard let store else {
            return snapshot(
                storageAvailable: false,
                message: "Chat history index is unavailable."
            )
        }
        do {
            let persisted = try await store.loadAIConversationIndex(providerID: providerID)
            if !persisted.isEmpty || conversations.isEmpty {
                conversations = persisted
            }
            sort()
            return snapshot()
        } catch {
            return snapshot(
                storageAvailable: false,
                message: "Chat history index could not be loaded."
            )
        }
    }

    func search(
        query: String,
        scope: AIChatListScope
    ) -> [AIConversationSummary] {
        let normalizedQuery = query.launcherNormalized
        return conversations.filter { conversation in
            let matchesScope = scope == .archived
                ? conversation.isArchived
                : !conversation.isArchived
            guard matchesScope else { return false }
            return normalizedQuery.isEmpty
                || conversation.title.launcherNormalized.contains(normalizedQuery)
        }
    }

    func conversation(id: String) -> AIConversationSummary? {
        conversations.first(where: { $0.id == id })
    }

    func save(
        _ conversation: AIConversationSummary
    ) async -> FeatureSnapshot<AIConversationSummary> {
        let conversation = mergingLocalModelIfNeeded(conversation)
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        sort()
        guard let store else {
            return snapshot(
                storageAvailable: false,
                message: "Chat history changes are available until Yorozu quits."
            )
        }
        do {
            try await store.saveAIConversation(conversation)
            return snapshot()
        } catch {
            return snapshot(
                storageAvailable: false,
                message: "Chat history changes could not be saved."
            )
        }
    }

    func remove(id: String) async -> FeatureSnapshot<AIConversationSummary> {
        conversations.removeAll(where: { $0.id == id })
        guard let store else {
            return snapshot(
                storageAvailable: false,
                message: "The local chat index is unavailable."
            )
        }
        do {
            try await store.deleteAIConversationIndex(providerID: providerID, id: id)
            return snapshot()
        } catch {
            return snapshot(
                storageAvailable: false,
                message: "The local chat index could not be updated."
            )
        }
    }

    func replace(
        _ values: [AIConversationSummary],
        scope: AIChatListScope
    ) async -> FeatureSnapshot<AIConversationSummary> {
        let scopedValues = values
            .filter {
                $0.providerID == providerID
                    && (scope == .archived ? $0.isArchived : !$0.isArchived)
            }
            .map(mergingLocalModelIfNeeded)
        let incomingIDs = Set(scopedValues.map(\.id))
        let retained = conversations.filter {
            (scope == .archived ? !$0.isArchived : $0.isArchived)
                && !incomingIDs.contains($0.id)
        }
        conversations = retained + scopedValues
        sort()
        guard let store else {
            return snapshot(
                storageAvailable: false,
                message: "Chat history changes are available until Yorozu quits."
            )
        }
        do {
            try await store.replaceAIConversationIndex(
                providerID: providerID,
                scope: scope,
                conversations: scopedValues
            )
            return snapshot()
        } catch {
            return snapshot(
                storageAvailable: false,
                message: "Chat history changes could not be saved."
            )
        }
    }

    private func sort() {
        conversations.sort {
            if $0.lastMessageAt != $1.lastMessageAt {
                return $0.lastMessageAt > $1.lastMessageAt
            }
            return $0.id < $1.id
        }
    }

    private func mergingLocalModelIfNeeded(
        _ incoming: AIConversationSummary
    ) -> AIConversationSummary {
        guard (!incoming.isModelAuthoritative || !incoming.isReasoningEffortAuthoritative),
              let existing = conversations.first(where: { $0.id == incoming.id }) else {
            return incoming
        }
        var merged = incoming
        if !incoming.isModelAuthoritative {
            merged.model = existing.model
            merged.isModelAuthoritative = existing.isModelAuthoritative
        }
        if !incoming.isReasoningEffortAuthoritative {
            merged.reasoningEffort = existing.reasoningEffort
            merged.isReasoningEffortAuthoritative = existing.isReasoningEffortAuthoritative
        }
        return merged
    }

    private func snapshot(
        storageAvailable: Bool = true,
        message: String? = nil
    ) -> FeatureSnapshot<AIConversationSummary> {
        FeatureSnapshot(
            values: conversations,
            storageAvailable: storageAvailable,
            message: message
        )
    }
}

actor AIConversationCoordinator {
    nonisolated let descriptor: AIProviderDescriptor
    nonisolated let policies: AIProviderPolicies

    private let catalog: AIConversationCatalog
    nonisolated private let provider: any AIChatProvider

    init(catalog: AIConversationCatalog, provider: any AIChatProvider) {
        self.catalog = catalog
        self.provider = provider
        descriptor = provider.descriptor
        policies = provider.policies
    }

    func loadIndex() async -> FeatureSnapshot<AIConversationSummary> {
        await catalog.load()
    }

    func search(query: String, scope: AIChatListScope) async -> [AIConversationSummary] {
        await catalog.search(query: query, scope: scope)
    }

    func refreshIndex(
        query: String,
        scope: AIChatListScope
    ) async throws -> FeatureSnapshot<AIConversationSummary> {
        guard policies.conversationListAuthority == .provider else {
            return await catalog.load()
        }

        var cursor: String?
        var seenCursors: Set<String> = []
        var values: [AIConversationSummary] = []
        repeat {
            try Task.checkCancellation()
            let page = try await provider.listConversations(
                request: AIConversationListRequest(
                    scope: scope,
                    query: query,
                    cursor: cursor,
                    limit: 50
                )
            )
            values.append(contentsOf: page.conversations)
            if let nextCursor = page.nextCursor,
               !seenCursors.insert(nextCursor).inserted {
                throw AIChatError.protocolError
            }
            cursor = page.nextCursor
        } while cursor != nil

        if query.launcherNormalized.isEmpty {
            return await catalog.replace(values, scope: scope)
        }
        var snapshot = await catalog.load()
        for value in values {
            snapshot = await catalog.save(value)
        }
        return snapshot
    }

    func availability() async -> AIProviderAvailability { await provider.availability() }
    func authenticationState() async -> AIAuthenticationState {
        await provider.authenticationState()
    }
    func availableModels() async throws -> [AIModel] { try await provider.availableModels() }
    func createConversation(title: String, model: AIModel) async throws -> String {
        try await provider.createConversation(title: title, model: model)
    }
    func updateConversation(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        try await provider.updateConversation(
            conversationID: conversationID,
            title: title,
            model: model,
            isArchived: isArchived
        )
    }
    func setConversationArchived(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        try await provider.setConversationArchived(
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
        try await provider.loadConversation(
            conversationID: conversationID,
            limit: limit,
            after: after
        )
    }
    func uploadAttachment(_ attachment: AIChatAttachment) async throws -> AIUploadedAttachment {
        try await provider.uploadAttachment(attachment)
    }
    nonisolated func streamResponse(
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        provider.streamResponse(request: request)
    }
    nonisolated func streamTranslation(
        request: AITranslationRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        provider.streamTranslation(request: request)
    }
    func stopGeneration(conversationID: String) async {
        await provider.stopGeneration(conversationID: conversationID)
    }
    func deleteConversationCompletely(conversationID: String) async throws {
        try await provider.deleteConversationCompletely(conversationID: conversationID)
    }
    func save(_ conversation: AIConversationSummary) async -> FeatureSnapshot<AIConversationSummary> {
        await catalog.save(conversation)
    }
    func remove(id: String) async -> FeatureSnapshot<AIConversationSummary> {
        await catalog.remove(id: id)
    }
    func shutdown() async { await provider.shutdown() }
}
