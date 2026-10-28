import Foundation

/// A shared, disposable view cache, not a conversation's source of truth.
/// Visible and streaming conversations may exceed the budget; leaving them
/// makes them evictable without discarding drafts or provider-owned history.
@MainActor
final class AIMessageCache {
    struct Statistics: Equatable, Sendable {
        let conversationCount: Int
        let estimatedByteCount: Int
        let protectedByteCount: Int
        let evictionCount: Int
    }

    private struct Entry {
        var messages: [AIChatMessage]
        var byteCount: Int
    }

    let maximumByteCount: Int
    let maximumConversationCount: Int
    private var entries: [AIConversationReference: Entry] = [:]
    private var leastRecentlyUsed: [AIConversationReference] = []
    private var protections: [AIProviderID: Set<AIConversationReference>] = [:]
    private(set) var estimatedByteCount = 0
    private(set) var evictionCount = 0

    init(maximumByteCount: Int = 8 * 1_024 * 1_024, maximumConversationCount: Int = 8) {
        self.maximumByteCount = max(0, maximumByteCount)
        self.maximumConversationCount = max(0, maximumConversationCount)
    }

    var statistics: Statistics {
        let protected = protectedReferences
        return Statistics(
            conversationCount: entries.count,
            estimatedByteCount: estimatedByteCount,
            protectedByteCount: entries.reduce(0) { total, item in
                total + (protected.contains(item.key) ? item.value.byteCount : 0)
            },
            evictionCount: evictionCount
        )
    }

    func messages(for reference: AIConversationReference) -> [AIChatMessage]? {
        guard let entry = entries[reference] else { return nil }
        touch(reference)
        return entry.messages
    }

    func store(_ messages: [AIChatMessage], for reference: AIConversationReference) {
        let cost = messages.reduce(128 + reference.providerConversationID.utf8.count) {
            $0 + Self.estimatedByteCount(of: $1)
        }
        estimatedByteCount += cost - (entries[reference]?.byteCount ?? 0)
        entries[reference] = Entry(messages: messages, byteCount: cost)
        touch(reference)
        trim()
    }

    /// Streaming only recounts the changed message, not the entire transcript.
    func updateMessage(
        id: String,
        in reference: AIConversationReference,
        _ update: (inout AIChatMessage) -> Void
    ) -> [AIChatMessage]? {
        guard var entry = entries[reference],
              let index = entry.messages.firstIndex(where: { $0.id == id }) else { return nil }
        let oldCost = Self.estimatedByteCount(of: entry.messages[index])
        update(&entry.messages[index])
        let delta = Self.estimatedByteCount(of: entry.messages[index]) - oldCost
        entry.byteCount += delta
        estimatedByteCount += delta
        entries[reference] = entry
        touch(reference)
        trim()
        return entry.messages
    }

    func protect(_ references: Set<AIConversationReference>, for providerID: AIProviderID) {
        protections[providerID] = references
        trim()
    }

    func remove(_ reference: AIConversationReference) {
        if let entry = entries.removeValue(forKey: reference) {
            estimatedByteCount -= entry.byteCount
        }
        leastRecentlyUsed.removeAll { $0 == reference }
    }

    func removeAll(for providerID: AIProviderID) {
        for reference in leastRecentlyUsed.filter({ $0.providerID == providerID }) {
            remove(reference)
        }
        protections.removeValue(forKey: providerID)
    }

    private var protectedReferences: Set<AIConversationReference> {
        protections.values.reduce(into: []) { $0.formUnion($1) }
    }

    private func touch(_ reference: AIConversationReference) {
        leastRecentlyUsed.removeAll { $0 == reference }
        leastRecentlyUsed.append(reference)
    }

    private func trim() {
        let protected = protectedReferences
        while estimatedByteCount > maximumByteCount || entries.count > maximumConversationCount {
            guard let candidate = leastRecentlyUsed.first(where: { !protected.contains($0) }) else {
                return
            }
            remove(candidate)
            evictionCount += 1
        }
    }

    static func estimatedByteCount(of message: AIChatMessage) -> Int {
        // Budget stored UTF-8 plus container overhead without encoding/copying
        // message bodies. Attachment bytes are not retained in this cache.
        var bytes = 256 + message.id.utf8.count + message.text.utf8.count
        for citation in message.citations {
            bytes += 128 + citation.id.utf8.count + citation.title.utf8.count
                + citation.url.absoluteString.utf8.count
        }
        for attachment in message.attachments {
            bytes += 128 + attachment.id.utf8.count + attachment.filename.utf8.count
                + (attachment.fileID?.utf8.count ?? 0)
                + (attachment.localURL?.absoluteString.utf8.count ?? 0)
        }
        return bytes
    }
}
