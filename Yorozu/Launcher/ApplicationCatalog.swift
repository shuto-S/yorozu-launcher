import Foundation

actor ApplicationCatalog {
    typealias AliasPreferenceSaver = @Sendable (
        ApplicationIdentity,
        LauncherPreference
    ) async throws -> Void

    private let store: LauncherStore?
    private let discoverer: any ApplicationDiscovering
    private let aliasPreferenceSaver: AliasPreferenceSaver?
    private var applications: [LaunchableApplication] = []
    private var lastIndexedAt: Date?
    private var storageAvailable: Bool

    init(
        store: LauncherStore?,
        discoverer: any ApplicationDiscovering,
        aliasPreferenceSaver: AliasPreferenceSaver? = nil
    ) {
        self.store = store
        self.discoverer = discoverer
        if let aliasPreferenceSaver {
            self.aliasPreferenceSaver = aliasPreferenceSaver
        } else if let store {
            self.aliasPreferenceSaver = { identity, preference in
                try await store.savePreference(
                    identity: identity,
                    preference: preference
                )
            }
        } else {
            self.aliasPreferenceSaver = nil
        }
        storageAvailable = store != nil
    }

    func loadCachedApplications() async -> CatalogSnapshot {
        guard let store else {
            return snapshot(message: "History storage is unavailable.")
        }
        do {
            applications = try await store.loadApplications()
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "The saved application index could not be loaded.")
        }
    }

    func reindex() async -> CatalogSnapshot {
        do {
            let discovered = try await discoverer.discoverApplications()
            let indexedAt = Date()
            if let store, storageAvailable {
                do {
                    try await store.replaceApplications(discovered, indexedAt: indexedAt)
                    applications = try await store.loadApplications()
                } catch {
                    storageAvailable = false
                    applications = mergeInMemory(discovered)
                    lastIndexedAt = indexedAt
                    return snapshot(message: "The index was updated, but history could not be saved.")
                }
            } else {
                applications = mergeInMemory(discovered)
            }
            lastIndexedAt = indexedAt
            return snapshot(message: nil)
        } catch {
            return snapshot(message: "Applications could not be indexed.")
        }
    }

    func search(query: String) -> [LaunchableApplication] {
        SearchScorer.rank(applications: applications, query: query)
    }

    func searchAliases(query: String) -> [LaunchableApplication] {
        let aliasedApplications = applications.filter {
            $0.preference.alias?.isEmpty == false
        }
        guard !query.launcherNormalized.isEmpty else {
            return aliasedApplications.sorted {
                let aliasComparison = ($0.preference.alias ?? "")
                    .localizedStandardCompare($1.preference.alias ?? "")
                if aliasComparison != .orderedSame {
                    return aliasComparison == .orderedAscending
                }
                return $0.primaryName.localizedStandardCompare($1.primaryName)
                    == .orderedAscending
            }
        }
        return SearchScorer.rank(
            applications: aliasedApplications,
            query: query,
            limit: aliasedApplications.count
        )
    }

    func application(id: ApplicationIdentity) -> LaunchableApplication? {
        applications.first(where: { $0.id == id })
    }

    func updateAlias(
        identity: ApplicationIdentity,
        alias: String?
    ) async throws -> CatalogSnapshot {
        guard let index = applications.firstIndex(where: { $0.id == identity }) else {
            throw LauncherError.applicationUnavailable("The selected application")
        }
        guard storageAvailable, let aliasPreferenceSaver else {
            throw LauncherError.aliasStorageUnavailable
        }

        var updatedApplication = applications[index]
        updatedApplication.preference.alias = alias
        do {
            try await aliasPreferenceSaver(
                updatedApplication.id,
                updatedApplication.preference
            )
        } catch {
            throw LauncherError.aliasCouldNotBeSaved
        }
        applications[index] = updatedApplication
        return snapshot(message: nil)
    }

    func togglePin(identity: ApplicationIdentity) async -> CatalogSnapshot {
        guard let index = applications.firstIndex(where: { $0.id == identity }) else {
            return snapshot(message: nil)
        }
        let willPin = !applications[index].preference.isPinned
        applications[index].preference.isPinned = willPin
        applications[index].preference.pinnedAt = willPin ? Date() : nil
        await persistPreference(at: index)
        return snapshot(message: nil)
    }

    func recordSuccessfulLaunch(identity: ApplicationIdentity) async -> CatalogSnapshot {
        guard let index = applications.firstIndex(where: { $0.id == identity }) else {
            return snapshot(message: nil)
        }
        applications[index].preference.launchCount += 1
        applications[index].preference.lastLaunchedAt = Date()
        await persistPreference(at: index)
        return snapshot(message: nil)
    }

    func remove(identity: ApplicationIdentity) -> CatalogSnapshot {
        applications.removeAll(where: { $0.id == identity })
        return snapshot(message: nil)
    }

    private func persistPreference(at index: Int) async {
        guard let store, storageAvailable else { return }
        do {
            try await store.savePreference(
                identity: applications[index].id,
                preference: applications[index].preference
            )
        } catch {
            storageAvailable = false
        }
    }

    private func mergeInMemory(
        _ discovered: [DiscoveredApplication]
    ) -> [LaunchableApplication] {
        let existingPreferences = Dictionary(
            uniqueKeysWithValues: applications.map { ($0.id, $0.preference) }
        )
        return discovered.map {
            LaunchableApplication(
                id: $0.id,
                bundleIdentifier: $0.bundleIdentifier,
                canonicalURL: $0.canonicalURL,
                displayName: $0.displayName,
                localizedName: $0.localizedName,
                version: $0.version,
                preference: existingPreferences[$0.id] ?? .empty
            )
        }
    }

    private func snapshot(message: String?) -> CatalogSnapshot {
        CatalogSnapshot(
            applications: applications,
            lastIndexedAt: lastIndexedAt,
            storageAvailable: storageAvailable,
            message: message
        )
    }
}

actor FeatureCommandCatalog {
    private let store: LauncherStore?
    private var states = FeatureCommand.all.map {
        FeatureCommandState(command: $0, preference: .empty)
    }
    private var storageAvailable: Bool

    init(store: LauncherStore?) {
        self.store = store
        storageAvailable = store != nil
    }

    func load() async -> FeatureSnapshot<FeatureCommandState> {
        guard let store else {
            return snapshot(message: "Feature usage history is unavailable.")
        }
        do {
            var loaded: [FeatureCommandState] = []
            for command in FeatureCommand.all {
                loaded.append(
                    FeatureCommandState(
                        command: command,
                        preference: try await store.loadPreference(
                            identity: command.preferenceIdentity
                        )
                    )
                )
            }
            states = loaded
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "Feature usage history could not be loaded.")
        }
    }

    func recordUse(
        of command: FeatureCommand,
        at usedAt: Date = Date()
    ) async -> FeatureSnapshot<FeatureCommandState> {
        guard let index = states.firstIndex(where: { $0.command == command }) else {
            return snapshot(message: nil)
        }
        states[index].preference.launchCount += 1
        states[index].preference.lastLaunchedAt = usedAt

        guard let store, storageAvailable else {
            return snapshot(message: nil)
        }
        do {
            try await store.savePreference(
                identity: command.preferenceIdentity,
                preference: states[index].preference
            )
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "Feature usage history could not be saved.")
        }
    }

    private func snapshot(
        message: String?
    ) -> FeatureSnapshot<FeatureCommandState> {
        FeatureSnapshot(
            values: states,
            storageAvailable: storageAvailable,
            message: message
        )
    }
}
