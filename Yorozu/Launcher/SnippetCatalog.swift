import Foundation

actor SnippetCatalog {
    private let store: LauncherStore?
    private var snippets: [Snippet] = []
    private let storageAvailable: Bool

    init(store: LauncherStore?, initialSnippets: [Snippet] = []) {
        self.store = store
        snippets = initialSnippets.sorted(by: Self.sort)
        storageAvailable = store != nil
    }

    func load() async -> FeatureSnapshot<Snippet> {
        guard let store else {
            return snapshot(message: "Snippet storage is unavailable.")
        }
        do {
            snippets = try await store.loadSnippets().sorted(by: Self.sort)
            return snapshot(message: nil)
        } catch {
            return snapshot(message: "Snippets could not be loaded.")
        }
    }

    func search(query: String, limit: Int = 50) -> [Snippet] {
        let normalized = query.launcherNormalized
        if normalized.isEmpty {
            return Array(snippets.prefix(limit))
        }
        return Array(
            snippets.lazy
                .filter { $0.normalizedSearchText.contains(normalized) }
                .prefix(limit)
        )
    }

    func save(_ snippet: Snippet) async throws -> FeatureSnapshot<Snippet> {
        if let keyword = snippet.normalizedKeyword,
           snippets.contains(where: { $0.id != snippet.id && $0.normalizedKeyword == keyword }) {
            throw SnippetValidationError.duplicateKeyword
        }

        guard let store else {
            upsert(snippet)
            return snapshot(message: "The snippet is available only for this session.")
        }
        do {
            try await store.saveSnippet(snippet)
            upsert(snippet)
            return snapshot(message: nil)
        } catch {
            throw SnippetCatalogError.saveFailed
        }
    }

    func duplicate(_ snippet: Snippet, now: Date = Date()) async throws -> FeatureSnapshot<Snippet> {
        let copy = try Snippet.validated(
            name: "\(snippet.name) Copy",
            keyword: "",
            content: snippet.content,
            now: now
        )
        return try await save(copy)
    }

    func delete(id: UUID) async -> FeatureSnapshot<Snippet> {
        guard let store else {
            snippets.removeAll(where: { $0.id == id })
            return snapshot(message: "The snippet was removed only for this session.")
        }
        do {
            try await store.deleteSnippet(id: id)
            snippets.removeAll(where: { $0.id == id })
            return snapshot(message: nil)
        } catch {
            return snapshot(message: "The snippet could not be deleted.")
        }
    }

    func recordUse(id: UUID, usedAt: Date = Date()) async -> FeatureSnapshot<Snippet> {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else {
            return snapshot(message: nil)
        }

        guard let store else {
            updateUse(at: index, usedAt: usedAt)
            return snapshot(message: nil)
        }
        do {
            try await store.recordSnippetUse(id: id, usedAt: usedAt)
            guard let refreshedIndex = snippets.firstIndex(where: { $0.id == id }) else {
                return snapshot(message: nil)
            }
            updateUse(at: refreshedIndex, usedAt: usedAt)
            return snapshot(message: nil)
        } catch {
            return snapshot(message: "Snippet usage could not be saved.")
        }
    }

    private nonisolated static func sort(_ lhs: Snippet, _ rhs: Snippet) -> Bool {
        if lhs.lastUsedAt != rhs.lastUsedAt {
            return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
        }
        if lhs.useCount != rhs.useCount {
            return lhs.useCount > rhs.useCount
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        snippets.sort(by: Self.sort)
    }

    private func updateUse(at index: Int, usedAt: Date) {
        snippets[index].useCount += 1
        snippets[index].lastUsedAt = usedAt
        snippets.sort(by: Self.sort)
    }

    private func snapshot(message: String?) -> FeatureSnapshot<Snippet> {
        FeatureSnapshot(
            values: snippets,
            storageAvailable: storageAvailable,
            message: message
        )
    }
}

enum SnippetCatalogError: LocalizedError {
    case saveFailed

    var errorDescription: String? {
        "The snippet could not be saved. Try again."
    }
}
