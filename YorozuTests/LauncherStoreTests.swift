import AppKit
import XCTest
@testable import Yorozu

final class LauncherStoreTests: XCTestCase {
    func testPreferencesSurviveApplicationCacheReplacement() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let store = try LauncherStore(
            databaseURL: temporaryDirectory.appendingPathComponent("Yorozu.sqlite")
        )
        let application = DiscoveredApplication(
            id: ApplicationIdentity(rawValue: "bundle:test.example"),
            bundleIdentifier: "test.example",
            canonicalURL: URL(fileURLWithPath: "/Applications/Example.app"),
            displayName: "Example",
            localizedName: nil,
            version: "1.0",
            normalizedSearchText: "example test.example",
            rootPriority: 1
        )

        try await store.replaceApplications([application], indexedAt: Date())
        try await store.savePreference(
            identity: application.id,
            preference: LauncherPreference(
                alias: "sample",
                isPinned: true,
                pinnedAt: Date(timeIntervalSince1970: 100),
                launchCount: 4,
                lastLaunchedAt: Date(timeIntervalSince1970: 200)
            )
        )
        try await store.replaceApplications([], indexedAt: Date())
        try await store.replaceApplications([application], indexedAt: Date())

        let loaded = try await store.loadApplications()
        XCTAssertEqual(loaded.first?.preference.alias, "sample")
        XCTAssertEqual(loaded.first?.preference.isPinned, true)
        XCTAssertEqual(loaded.first?.preference.launchCount, 4)
    }

    func testCatalogShowsCacheThenReplacesItWithDiscoverySnapshot() async throws {
        let fixture = try makeStore()
        let cached = application(
            identity: "bundle:test.cached",
            name: "Cached",
            path: "/Applications/Cached.app"
        )
        let discovered = application(
            identity: "bundle:test.discovered",
            name: "Discovered",
            path: "/Applications/Discovered.app"
        )
        try await fixture.store.replaceApplications([cached], indexedAt: Date())

        let catalog = ApplicationCatalog(
            store: fixture.store,
            discoverer: StoreTestDiscoverer(applications: [discovered])
        )
        let cachedSnapshot = await catalog.loadCachedApplications()
        XCTAssertEqual(cachedSnapshot.applications.map(\.id), [cached.id])

        let refreshedSnapshot = await catalog.reindex()
        let storedApplications = try await fixture.store.loadApplications()
        XCTAssertEqual(refreshedSnapshot.applications.map(\.id), [discovered.id])
        XCTAssertEqual(storedApplications.map(\.id), [discovered.id])
    }

    func testCatalogKeepsInMemorySearchAvailableWithoutDatabase() async {
        let discovered = application(
            identity: "bundle:test.fallback",
            name: "Fallback Editor",
            path: "/Applications/Fallback Editor.app"
        )
        let catalog = ApplicationCatalog(
            store: nil,
            discoverer: StoreTestDiscoverer(applications: [discovered])
        )

        let snapshot = await catalog.reindex()
        let results = await catalog.search(query: "fallback")

        XCTAssertFalse(snapshot.storageAvailable)
        XCTAssertEqual(results.map(\.id), [discovered.id])
    }

    func testAliasSnapshotSearchesAliasApplicationNameAndBundleIdentifier() async throws {
        let fixture = try makeStore()
        let browser = application(
            identity: "bundle:com.example.browser",
            name: "Example Browser",
            path: "/Applications/Example Browser.app"
        )
        let editor = application(
            identity: "bundle:com.example.editor",
            name: "Code Editor",
            path: "/Applications/Code Editor.app"
        )
        try await fixture.store.replaceApplications(
            [browser, editor],
            indexedAt: Date()
        )
        try await fixture.store.savePreference(
            identity: browser.id,
            preference: LauncherPreference(
                alias: "web",
                isPinned: false,
                pinnedAt: nil,
                launchCount: 0,
                lastLaunchedAt: nil
            )
        )
        try await fixture.store.savePreference(
            identity: editor.id,
            preference: LauncherPreference(
                alias: "dev",
                isPinned: false,
                pinnedAt: nil,
                launchCount: 0,
                lastLaunchedAt: nil
            )
        )
        let catalog = ApplicationCatalog(
            store: fixture.store,
            discoverer: StoreTestDiscoverer(applications: [])
        )
        _ = await catalog.loadCachedApplications()

        let aliasMatches = await catalog.searchAliases(query: "web")
        let nameMatches = await catalog.searchAliases(query: "editor")
        let bundleMatches = await catalog.searchAliases(
            query: "com.example.browser"
        )

        XCTAssertEqual(aliasMatches.map(\.id), [browser.id])
        XCTAssertEqual(nameMatches.map(\.id), [editor.id])
        XCTAssertEqual(bundleMatches.map(\.id), [browser.id])
    }

    func testDeletingAliasPreservesPinAndUsagePreferences() async throws {
        let fixture = try makeStore()
        let target = application(
            identity: "bundle:com.example.alias",
            name: "Alias Target",
            path: "/Applications/Alias Target.app"
        )
        try await fixture.store.replaceApplications([target], indexedAt: Date())
        let pinnedAt = Date(timeIntervalSince1970: 100)
        let launchedAt = Date(timeIntervalSince1970: 200)
        try await fixture.store.savePreference(
            identity: target.id,
            preference: LauncherPreference(
                alias: "remove-me",
                isPinned: true,
                pinnedAt: pinnedAt,
                launchCount: 7,
                lastLaunchedAt: launchedAt
            )
        )
        let catalog = ApplicationCatalog(
            store: fixture.store,
            discoverer: StoreTestDiscoverer(applications: [])
        )
        _ = await catalog.loadCachedApplications()

        _ = try await catalog.updateAlias(identity: target.id, alias: nil)

        let preference = try await fixture.store.loadPreference(identity: target.id)
        XCTAssertNil(preference.alias)
        XCTAssertTrue(preference.isPinned)
        XCTAssertEqual(preference.pinnedAt, pinnedAt)
        XCTAssertEqual(preference.launchCount, 7)
        XCTAssertEqual(preference.lastLaunchedAt, launchedAt)
    }

    func testClipboardCaptureDeduplicatesLatestItemAndPreservesPinnedItems() async throws {
        let fixture = try makeStore()
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let updatedDate = Date(timeIntervalSince1970: 2_000)
        let capture = ClipboardCapture(
            id: UUID(),
            kind: .text,
            contentHash: "same-hash",
            textContent: "Copied text",
            filePaths: [],
            imageData: nil,
            imageWidth: nil,
            imageHeight: nil,
            normalizedSearchText: "copied text",
            sourceBundleIdentifier: "com.example.source",
            sourceApplicationName: "Source",
            copiedAt: firstDate
        )

        let first = try await fixture.store.recordClipboardCapture(
            capture,
            retentionDays: 30,
            maximumItems: 2_000
        )
        try await fixture.store.setClipboardPinned(id: first.id, isPinned: true)
        _ = try await fixture.store.recordClipboardCapture(
            ClipboardCapture(
                id: UUID(),
                kind: capture.kind,
                contentHash: capture.contentHash,
                textContent: capture.textContent,
                filePaths: capture.filePaths,
                imageData: capture.imageData,
                imageWidth: capture.imageWidth,
                imageHeight: capture.imageHeight,
                normalizedSearchText: capture.normalizedSearchText,
                sourceBundleIdentifier: capture.sourceBundleIdentifier,
                sourceApplicationName: capture.sourceApplicationName,
                copiedAt: updatedDate
            ),
            retentionDays: 1,
            maximumItems: 1
        )

        let items = try await fixture.store.loadClipboardItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, first.id)
        XCTAssertEqual(items.first?.copiedAt, updatedDate)
        XCTAssertEqual(items.first?.isPinned, true)
    }

    func testClipboardUsageMovesItemFirstWithoutChangingCopyDate() async throws {
        let fixture = try makeStore()
        let olderCopyDate = Date(timeIntervalSince1970: 1_000)
        let newerCopyDate = Date(timeIntervalSince1970: 2_000)
        let usedAt = Date(timeIntervalSince1970: 3_000)

        let older = try await fixture.store.recordClipboardCapture(
            ClipboardCapture(
                id: UUID(),
                kind: .text,
                contentHash: "older",
                textContent: "Older",
                filePaths: [],
                imageData: nil,
                imageWidth: nil,
                imageHeight: nil,
                normalizedSearchText: "older",
                sourceBundleIdentifier: nil,
                sourceApplicationName: nil,
                copiedAt: olderCopyDate
            ),
            retentionDays: 30,
            maximumItems: 2_000
        )
        _ = try await fixture.store.recordClipboardCapture(
            ClipboardCapture(
                id: UUID(),
                kind: .text,
                contentHash: "newer",
                textContent: "Newer",
                filePaths: [],
                imageData: nil,
                imageWidth: nil,
                imageHeight: nil,
                normalizedSearchText: "newer",
                sourceBundleIdentifier: nil,
                sourceApplicationName: nil,
                copiedAt: newerCopyDate
            ),
            retentionDays: 30,
            maximumItems: 2_000
        )

        try await fixture.store.recordClipboardUse(id: older.id, usedAt: usedAt)

        let items = try await fixture.store.loadClipboardItems()
        XCTAssertEqual(items.first?.id, older.id)
        XCTAssertEqual(items.first?.copiedAt, olderCopyDate)
        XCTAssertEqual(items.first?.lastUsedAt, usedAt)
    }

    func testClipboardImageRoundTrip() async throws {
        let fixture = try makeStore()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let capture = ClipboardCapture(
            id: UUID(),
            kind: .image,
            contentHash: "image-hash",
            textContent: nil,
            filePaths: [],
            imageData: imageData,
            imageWidth: 832,
            imageHeight: 592,
            normalizedSearchText: "image",
            sourceBundleIdentifier: "com.example.source",
            sourceApplicationName: "Source",
            copiedAt: Date(timeIntervalSince1970: 1_000)
        )

        _ = try await fixture.store.recordClipboardCapture(
            capture,
            retentionDays: 30,
            maximumItems: 2_000
        )

        let items = try await fixture.store.loadClipboardItems()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .image)
        XCTAssertNil(item.imageData)
        XCTAssertEqual(item.imageByteCount, imageData.count)
        XCTAssertEqual(item.imageWidth, 832)
        XCTAssertEqual(item.imageHeight, 592)
        let loadedImageData = try await fixture.store.loadClipboardImageData(id: item.id)
        XCTAssertEqual(loadedImageData, imageData)
    }

    func testClipboardImageDecoderDownsamplesLargeImages() async throws {
        let width = 2_400
        let height = 1_600
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let sourceImage = try XCTUnwrap(context.makeImage())
        let imageData = try XCTUnwrap(
            NSBitmapImageRep(cgImage: sourceImage).representation(
                using: .png,
                properties: [:]
            )
        )

        let preview = await ClipboardImageDecoder().decode(imageData)

        XCTAssertEqual(preview?.width, 1_200)
        XCTAssertEqual(preview?.height, 800)
    }

    func testClipboardDatabaseMaintenanceCanBeAmortizedThenApplied() async throws {
        let fixture = try makeStore()
        let now = Date()

        for offset in 0..<2 {
            _ = try await fixture.store.recordClipboardCapture(
                ClipboardCapture(
                    id: UUID(),
                    kind: .text,
                    contentHash: "hash-\(offset)",
                    textContent: "Text \(offset)",
                    filePaths: [],
                    imageData: nil,
                    imageWidth: nil,
                    imageHeight: nil,
                    normalizedSearchText: "text \(offset)",
                    sourceBundleIdentifier: nil,
                    sourceApplicationName: nil,
                    copiedAt: now.addingTimeInterval(TimeInterval(offset))
                ),
                retentionDays: 30,
                maximumItems: 1,
                performsFullMaintenance: false
            )
        }

        let unprunedItems = try await fixture.store.loadClipboardItems()
        XCTAssertEqual(unprunedItems.count, 2)

        _ = try await fixture.store.recordClipboardCapture(
            ClipboardCapture(
                id: UUID(),
                kind: .text,
                contentHash: "hash-maintenance",
                textContent: "Text maintenance",
                filePaths: [],
                imageData: nil,
                imageWidth: nil,
                imageHeight: nil,
                normalizedSearchText: "text maintenance",
                sourceBundleIdentifier: nil,
                sourceApplicationName: nil,
                copiedAt: now.addingTimeInterval(2)
            ),
            retentionDays: 30,
            maximumItems: 1,
            performsFullMaintenance: true
        )

        let retainedItems = try await fixture.store.loadClipboardItems()
        XCTAssertEqual(retainedItems.count, 1)
        XCTAssertEqual(retainedItems.first?.contentHash, "hash-maintenance")
    }

    func testURLPreviewPolicyAcceptsPublicWebURLs() throws {
        XCTAssertEqual(
            URLPreviewPolicy.previewableURL(from: "https://www.apple.com/mac/")?.host(),
            "www.apple.com"
        )
        XCTAssertEqual(
            URLPreviewPolicy.previewableURL(from: " http://example.com/path ")?.scheme,
            "http"
        )
    }

    func testURLPreviewPolicyRejectsPrivateAndCredentialedURLs() {
        let rejectedValues = [
            "https://localhost/settings",
            "https://router.local/",
            "http://127.0.0.1/",
            "http://10.0.0.1/",
            "http://172.16.1.1/",
            "http://192.168.1.1/",
            "http://[::1]/",
            "https://user:password@example.com/",
            "file:///tmp/example.html",
        ]

        for value in rejectedValues {
            XCTAssertNil(
                URLPreviewPolicy.previewableURL(from: value),
                "Expected \(value) to be rejected"
            )
        }
    }

    func testURLPreviewCacheRoundTripAndExpiry() async throws {
        let fixture = try makeStore()
        let fetchedAt = Date(timeIntervalSince1970: 10_000)
        let entry = URLPreviewCacheEntry(
            url: "https://example.com/",
            metadataData: Data([0x01, 0x02, 0x03]),
            fetchedAt: fetchedAt
        )

        try await fixture.store.saveURLPreview(entry)

        let cached = try await fixture.store.loadURLPreview(
            url: entry.url,
            newerThan: fetchedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(cached, entry)

        let expired = try await fixture.store.loadURLPreview(
            url: entry.url,
            newerThan: fetchedAt.addingTimeInterval(1)
        )
        XCTAssertNil(expired)
    }

    func testSnippetRoundTripAndUsage() async throws {
        let fixture = try makeStore()
        let snippet = try Snippet.validated(
            name: "Email",
            keyword: ";mail",
            content: "hello@example.com",
            now: Date(timeIntervalSince1970: 1_000)
        )

        try await fixture.store.saveSnippet(snippet)
        try await fixture.store.recordSnippetUse(
            id: snippet.id,
            usedAt: Date(timeIntervalSince1970: 2_000)
        )

        let loaded = try await fixture.store.loadSnippets()
        XCTAssertEqual(loaded.first?.name, "Email")
        XCTAssertEqual(loaded.first?.keyword, ";mail")
        XCTAssertEqual(loaded.first?.useCount, 1)
        XCTAssertEqual(loaded.first?.lastUsedAt, Date(timeIntervalSince1970: 2_000))
    }

    func testSnippetValidationRejectsInvalidAndDuplicateKeywords() async throws {
        XCTAssertThrowsError(
            try Snippet.validated(name: "", keyword: "", content: "Value")
        )
        XCTAssertThrowsError(
            try Snippet.validated(name: "Name", keyword: "🔥", content: "Value")
        )

        let fixture = try makeStore()
        let catalog = SnippetCatalog(store: fixture.store)
        _ = await catalog.load()
        let first = try Snippet.validated(
            name: "First",
            keyword: ";mail",
            content: "First value"
        )
        let second = try Snippet.validated(
            name: "Second",
            keyword: ";MAIL",
            content: "Second value"
        )
        _ = try await catalog.save(first)

        do {
            _ = try await catalog.save(second)
            XCTFail("Expected a duplicate keyword error")
        } catch {
            XCTAssertEqual(error as? SnippetValidationError, .duplicateKeyword)
        }
    }

    func testClipboardSearchP95StaysUnderThirtyMillisecondsWithTwoThousandItems() async {
        let now = Date()
        let items = (0..<2_000).map { index in
            ClipboardItem(
                id: UUID(),
                kind: .text,
                contentHash: "hash-\(index)",
                textContent: "Clipboard item \(index)",
                filePaths: [],
                imageData: nil,
                imageByteCount: nil,
                imageWidth: nil,
                imageHeight: nil,
                normalizedSearchText: "clipboard item \(index)",
                sourceBundleIdentifier: "com.example.source",
                sourceApplicationName: "Source",
                isPinned: false,
                pinnedAt: nil,
                copiedAt: now.addingTimeInterval(-Double(index)),
                updatedAt: now
            )
        }
        let catalog = ClipboardCatalog(store: nil, initialItems: items)
        for _ in 0..<10 {
            _ = await catalog.search(query: "item 199")
        }

        var durations: [TimeInterval] = []
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = await catalog.search(query: "item 199")
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }

        let p95 = durations.sorted()[94]
        print("YOROZU_PERF clipboard_search_p95_ms=\(p95 * 1_000)")
        XCTAssertLessThan(p95, 0.030, "p95 was \(p95 * 1_000)ms")
    }

    func testSnippetSearchP95StaysUnderThirtyMillisecondsWithTwoThousandItems() async throws {
        let now = Date()
        let snippets = try (0..<2_000).map { index in
            try Snippet.validated(
                name: "Snippet \(index)",
                keyword: ";snippet\(index)",
                content: "Reusable snippet content \(index)",
                now: now.addingTimeInterval(-Double(index))
            )
        }
        let catalog = SnippetCatalog(store: nil, initialSnippets: snippets)
        for _ in 0..<10 {
            _ = await catalog.search(query: "content 199")
        }

        var durations: [TimeInterval] = []
        durations.reserveCapacity(100)
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = await catalog.search(query: "content 199")
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }

        let p95 = durations.sorted()[94]
        print("YOROZU_PERF snippet_search_p95_ms=\(p95 * 1_000)")
        XCTAssertLessThan(p95, 0.030, "p95 was \(p95 * 1_000)ms")
    }

    func testClipboardCaptureProcessorHandlesMaximumTextOffThePasteboardBoundary() async throws {
        let text = String(repeating: "a", count: 1_048_576)
        let processor = ClipboardCaptureProcessor()
        let processedCapture = await processor.process(
            RawClipboardSnapshot(
                content: .string(text),
                sourceBundleIdentifier: "com.example.source",
                sourceApplicationName: "Source",
                copiedAt: Date()
            )
        )
        let capture = try XCTUnwrap(processedCapture)

        XCTAssertEqual(capture.kind, .text)
        XCTAssertEqual(capture.textContent?.utf8.count, 1_048_576)
        XCTAssertFalse(capture.contentHash.isEmpty)
    }

    func testClipboardRecordKeepsImageLazyWithDatabaseAndAvailableInMemoryFallback() async throws {
        let capture = ClipboardCapture(
            id: UUID(),
            kind: .image,
            contentHash: "image-hash",
            textContent: nil,
            filePaths: [],
            imageData: Data([0x01, 0x02, 0x03]),
            imageWidth: 1,
            imageHeight: 1,
            normalizedSearchText: "image",
            sourceBundleIdentifier: nil,
            sourceApplicationName: nil,
            copiedAt: Date()
        )

        let fixture = try makeStore()
        let persistedCatalog = ClipboardCatalog(store: fixture.store)
        _ = await persistedCatalog.load()
        let persisted = await persistedCatalog.record(
            capture,
            retentionDays: 30,
            maximumItems: 2_000
        )
        XCTAssertNil(persisted.values.first?.imageData)
        let persistedImageData = await persistedCatalog.imageData(id: capture.id)
        XCTAssertEqual(
            persistedImageData,
            capture.imageData
        )

        let sessionCatalog = ClipboardCatalog(store: nil)
        let session = await sessionCatalog.record(
            capture,
            retentionDays: 30,
            maximumItems: 2_000
        )
        XCTAssertEqual(session.values.first?.imageData, capture.imageData)
    }

    private func makeStore() throws -> (store: LauncherStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return (
            try LauncherStore(
                databaseURL: directory.appendingPathComponent("Yorozu.sqlite")
            ),
            directory
        )
    }

    private func application(
        identity: String,
        name: String,
        path: String
    ) -> DiscoveredApplication {
        DiscoveredApplication(
            id: ApplicationIdentity(rawValue: identity),
            bundleIdentifier: String(identity.dropFirst("bundle:".count)),
            canonicalURL: URL(fileURLWithPath: path),
            displayName: name,
            localizedName: nil,
            version: "1.0",
            normalizedSearchText: name.launcherNormalized,
            rootPriority: 1
        )
    }
}

private struct StoreTestDiscoverer: ApplicationDiscovering {
    let applications: [DiscoveredApplication]

    func discoverApplications() async throws -> [DiscoveredApplication] {
        applications
    }
}
