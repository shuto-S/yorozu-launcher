import Foundation

actor ClipboardCatalog {
    private let store: LauncherStore?
    private var items: [ClipboardItem] = []
    private var storageAvailable: Bool
    private var latestItemID: UUID?
    private var latestContentHash: String?
    private var writesSinceMaintenance = 0

    init(store: LauncherStore?, initialItems: [ClipboardItem] = []) {
        self.store = store
        items = initialItems.sorted(by: Self.sort)
        storageAvailable = store != nil
        let latest = Self.latestItem(in: items)
        latestItemID = latest?.id
        latestContentHash = latest?.contentHash
    }

    func load() async -> FeatureSnapshot<ClipboardItem> {
        guard let store else {
            return snapshot(message: "Clipboard storage is unavailable.")
        }
        do {
            items = try await store.loadClipboardItems().sorted(by: Self.sort)
            updateLatestItem()
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "Clipboard history could not be loaded.")
        }
    }

    func search(query: String, limit: Int = 50) -> [ClipboardItem] {
        let normalized = query.launcherNormalized
        if normalized.isEmpty {
            return Array(items.prefix(limit))
        }
        return Array(
            items.lazy
                .filter { $0.normalizedSearchText.contains(normalized) }
                .prefix(limit)
        )
    }

    func record(
        _ capture: ClipboardCapture,
        retentionDays: Int,
        maximumItems: Int
    ) async -> FeatureSnapshot<ClipboardItem> {
        guard let store, storageAvailable else {
            merge(capture: capture)
            pruneInMemory(
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                now: capture.copiedAt
            )
            return snapshot(message: "Clipboard history is available only for this session.")
        }
        do {
            writesSinceMaintenance += 1
            let performsFullMaintenance =
                capture.kind == .image || writesSinceMaintenance >= 32
            let persistedItem = try await store.recordClipboardCapture(
                capture,
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                performsFullMaintenance: performsFullMaintenance
            )
            upsert(persistedItem)
            pruneInMemory(
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                now: capture.copiedAt
            )
            if performsFullMaintenance {
                writesSinceMaintenance = 0
            }
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            merge(capture: capture)
            pruneInMemory(
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                now: capture.copiedAt
            )
            return snapshot(message: "Clipboard history could not be saved.")
        }
    }

    func togglePin(id: UUID) async -> FeatureSnapshot<ClipboardItem> {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return snapshot(message: nil)
        }
        let willPin = !items[index].isPinned

        guard let store, storageAvailable else {
            items[index].isPinned = willPin
            items[index].pinnedAt = willPin ? Date() : nil
            items.sort(by: Self.sort)
            return snapshot(message: "Pinned state is available only for this session.")
        }
        do {
            try await store.setClipboardPinned(id: id, isPinned: willPin)
            guard let refreshedIndex = items.firstIndex(where: { $0.id == id }) else {
                return snapshot(message: nil)
            }
            items[refreshedIndex].isPinned = willPin
            items[refreshedIndex].pinnedAt = willPin ? Date() : nil
            items.sort(by: Self.sort)
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "Pinned state could not be saved.")
        }
    }

    func imageData(id: UUID) async -> Data? {
        if let data = items.first(where: { $0.id == id })?.imageData {
            return data
        }
        guard let store, storageAvailable else { return nil }
        do {
            return try await store.loadClipboardImageData(id: id)
        } catch {
            storageAvailable = false
            return nil
        }
    }

    func delete(id: UUID) async -> FeatureSnapshot<ClipboardItem> {
        guard let store, storageAvailable else {
            items.removeAll(where: { $0.id == id })
            if latestItemID == id {
                updateLatestItem()
            }
            return snapshot(message: "The item was removed only for this session.")
        }
        do {
            try await store.deleteClipboardItem(id: id)
            items.removeAll(where: { $0.id == id })
            if latestItemID == id {
                updateLatestItem()
            }
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "The clipboard item could not be deleted.")
        }
    }

    func clear(includePinned: Bool) async -> FeatureSnapshot<ClipboardItem> {
        guard let store, storageAvailable else {
            removeClearedItems(includePinned: includePinned)
            return snapshot(message: "Clipboard history was cleared only for this session.")
        }
        do {
            try await store.clearClipboardHistory(includePinned: includePinned)
            removeClearedItems(includePinned: includePinned)
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "Clipboard history could not be cleared.")
        }
    }

    func prune(
        retentionDays: Int,
        maximumItems: Int,
        now: Date = Date()
    ) async -> FeatureSnapshot<ClipboardItem> {
        guard let store, storageAvailable else {
            pruneInMemory(
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                now: now
            )
            return snapshot(message: nil)
        }
        do {
            try await store.pruneClipboardHistory(
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                now: now
            )
            pruneInMemory(
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                now: now
            )
            return snapshot(message: nil)
        } catch {
            storageAvailable = false
            return snapshot(message: "Clipboard retention settings could not be applied.")
        }
    }

    private nonisolated static func sort(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        if lhs.isPinned, lhs.pinnedAt != rhs.pinnedAt {
            return (lhs.pinnedAt ?? .distantFuture) < (rhs.pinnedAt ?? .distantFuture)
        }
        return lhs.copiedAt > rhs.copiedAt
    }

    private func pruneInMemory(retentionDays: Int, maximumItems: Int, now: Date) {
        let cutoff = now.addingTimeInterval(
            -Double(max(1, retentionDays)) * 86_400
        )
        var retained: [ClipboardItem] = []
        retained.reserveCapacity(min(items.count, max(1, maximumItems) + 16))
        var unpinnedCount = 0
        var retainedImageBytes = 0
        for item in items {
            if item.isPinned {
                retained.append(item)
                continue
            }
            guard item.copiedAt >= cutoff,
                  unpinnedCount < max(1, maximumItems) else {
                continue
            }
            if item.kind == .image {
                let byteCount = item.imageByteCount ?? item.imageData?.count ?? 0
                guard retainedImageBytes + byteCount
                        <= ClipboardStoragePolicy.maximumUnpinnedImageBytes else {
                    continue
                }
                retainedImageBytes += byteCount
            }
            retained.append(item)
            unpinnedCount += 1
        }
        items = retained
        if let latestItemID,
           !items.contains(where: { $0.id == latestItemID }) {
            updateLatestItem()
        }
    }

    private func merge(capture: ClipboardCapture) {
        if latestContentHash == capture.contentHash,
           let latestItemID,
           let index = items.firstIndex(where: { $0.id == latestItemID }) {
            items[index].copiedAt = capture.copiedAt
            items[index].updatedAt = capture.copiedAt
            moveUpdatedItemToSortedPosition(at: index)
            latestContentHash = capture.contentHash
        } else {
            upsert(Self.item(from: capture))
        }
    }

    private func upsert(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
            moveUpdatedItemToSortedPosition(at: index)
        } else {
            let insertionIndex = items.firstIndex(where: {
                Self.sort(item, $0)
            }) ?? items.endIndex
            items.insert(item, at: insertionIndex)
        }
        latestItemID = item.id
        latestContentHash = item.contentHash
    }

    private func removeClearedItems(includePinned: Bool) {
        if includePinned {
            items.removeAll()
        } else {
            items.removeAll(where: { !$0.isPinned })
        }
        updateLatestItem()
    }

    private func moveUpdatedItemToSortedPosition(at index: Int) {
        let item = items.remove(at: index)
        let insertionIndex = items.firstIndex(where: {
            Self.sort(item, $0)
        }) ?? items.endIndex
        items.insert(item, at: insertionIndex)
    }

    private func updateLatestItem() {
        let latest = Self.latestItem(in: items)
        latestItemID = latest?.id
        latestContentHash = latest?.contentHash
    }

    private nonisolated static func latestItem(
        in items: [ClipboardItem]
    ) -> ClipboardItem? {
        items.max(by: { $0.copiedAt < $1.copiedAt })
    }

    private nonisolated static func item(from capture: ClipboardCapture) -> ClipboardItem {
        ClipboardItem(
            id: capture.id,
            kind: capture.kind,
            contentHash: capture.contentHash,
            textContent: capture.textContent,
            filePaths: capture.filePaths,
            imageData: capture.imageData,
            imageByteCount: capture.imageData?.count,
            imageWidth: capture.imageWidth,
            imageHeight: capture.imageHeight,
            normalizedSearchText: capture.normalizedSearchText,
            sourceBundleIdentifier: capture.sourceBundleIdentifier,
            sourceApplicationName: capture.sourceApplicationName,
            isPinned: false,
            pinnedAt: nil,
            copiedAt: capture.copiedAt,
            updatedAt: capture.copiedAt
        )
    }

    private func snapshot(message: String?) -> FeatureSnapshot<ClipboardItem> {
        FeatureSnapshot(
            values: items,
            storageAvailable: storageAvailable,
            message: message
        )
    }
}
