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

    private func sort() {
        conversations.sort {
            if $0.lastMessageAt != $1.lastMessageAt {
                return $0.lastMessageAt > $1.lastMessageAt
            }
            return $0.id < $1.id
        }
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
