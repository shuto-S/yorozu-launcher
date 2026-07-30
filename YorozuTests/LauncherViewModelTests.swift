import AppKit
import XCTest
@testable import Yorozu

@MainActor
final class LauncherViewModelTests: XCTestCase {
    func testMarkedTextCompositionKeysPassThroughToTheInputMethod() {
        let keyCodes: [UInt16] = [
            36,  // Return
            76,  // Keypad Enter
            126, // Up Arrow
            125, // Down Arrow
            53,  // Escape
            48,  // Tab
        ]

        for keyCode in keyCodes {
            XCTAssertEqual(
                PaletteKeyEventPolicy.action(
                    keyCode: keyCode,
                    modifiers: [],
                    hasMarkedText: true,
                    route: .root,
                    isActionPanelPresented: false
                ),
                .passThrough,
                "Expected keyCode \(keyCode) to reach the input method"
            )
        }
    }

    func testNonComposingPaletteKeysKeepTheirExistingActions() {
        XCTAssertEqual(
            keyAction(keyCode: 36),
            .performPrimaryAction
        )
        XCTAssertEqual(
            keyAction(keyCode: 76),
            .performPrimaryAction
        )
        XCTAssertEqual(keyAction(keyCode: 126), .moveSelection(-1))
        XCTAssertEqual(keyAction(keyCode: 125), .moveSelection(1))
        XCTAssertEqual(keyAction(keyCode: 53), .escape)
        XCTAssertEqual(keyAction(keyCode: 48), .passThrough)
    }

    func testCommandShortcutsRemainAvailableDuringComposition() {
        XCTAssertEqual(
            keyAction(
                keyCode: 40,
                modifiers: .command,
                hasMarkedText: true
            ),
            .handleCommandShortcut
        )
    }

    func testActionPanelUsesTheSameCompositionPolicy() {
        for keyCode: UInt16 in [36, 76, 126, 125, 53, 48] {
            XCTAssertEqual(
                keyAction(
                    keyCode: keyCode,
                    hasMarkedText: true,
                    isActionPanelPresented: true
                ),
                .passThrough
            )
        }

        XCTAssertEqual(
            keyAction(keyCode: 36, isActionPanelPresented: true),
            .performPrimaryAction
        )
        XCTAssertEqual(
            keyAction(keyCode: 125, isActionPanelPresented: true),
            .moveSelection(1)
        )
        XCTAssertEqual(
            keyAction(keyCode: 53, isActionPanelPresented: true),
            .escape
        )
    }

    func testSettingsEscapePassesThroughWhileTextIsComposing() {
        XCTAssertEqual(
            keyAction(
                keyCode: 53,
                hasMarkedText: true,
                route: .settings
            ),
            .passThrough
        )
        XCTAssertEqual(
            keyAction(keyCode: 53, route: .settings),
            .escape
        )
    }

    func testAliasesEditorReturnPassesThroughWhileTextIsComposing() {
        XCTAssertEqual(
            keyAction(
                keyCode: 36,
                hasMarkedText: true,
                route: .aliases
            ),
            .passThrough
        )
        XCTAssertEqual(
            keyAction(keyCode: 36, route: .aliases),
            .performPrimaryAction
        )
    }

    func testAccessibilityDisplayOverridesRecognizeUITestArguments() {
        let enabled = AccessibilityDisplayOverrides(
            arguments: [
                "--ui-testing-reduce-motion",
                "--ui-testing-reduce-transparency",
            ]
        )
        XCTAssertTrue(enabled.reduceMotion)
        XCTAssertTrue(enabled.reduceTransparency)

        let disabled = AccessibilityDisplayOverrides(arguments: [])
        XCTAssertFalse(disabled.reduceMotion)
        XCTAssertFalse(disabled.reduceTransparency)

        XCTAssertEqual(
            PaletteAnimationPolicy.behavior(
                systemReducesMotion: false,
                overrides: enabled
            ),
            .none
        )
        XCTAssertEqual(
            PaletteAnimationPolicy.behavior(
                systemReducesMotion: false,
                overrides: disabled
            ),
            .utilityWindow
        )
    }

    func testPalettePresentationPerformanceReportUsesNearestRankPercentiles() {
        let report = PalettePresentationPerformanceReport(
            samples: Array(1...100).map(Double.init)
        )

        XCTAssertEqual(report.sampleCount, 100)
        XCTAssertEqual(report.p50Milliseconds, 50)
        XCTAssertEqual(report.p95Milliseconds, 95)
        XCTAssertEqual(report.maximumMilliseconds, 100)
    }

    func testFeatureRouteFirstUsableListPerformanceWithTwoThousandItems() async throws {
        let now = Date()
        let clipboardItems = (0..<2_000).map { index in
            ClipboardItem(
                id: UUID(),
                kind: .text,
                contentHash: "route-hash-\(index)",
                textContent: "Clipboard route item \(index)",
                filePaths: [],
                imageData: nil,
                imageByteCount: nil,
                imageWidth: nil,
                imageHeight: nil,
                normalizedSearchText: "clipboard route item \(index)",
                sourceBundleIdentifier: "com.example.source",
                sourceApplicationName: "Source",
                isPinned: false,
                pinnedAt: nil,
                copiedAt: now.addingTimeInterval(-Double(index)),
                updatedAt: now
            )
        }
        let snippets = try (0..<2_000).map { index in
            try Snippet.validated(
                name: "Route Snippet \(index)",
                keyword: ";route\(index)",
                content: "Route snippet content \(index)",
                now: now.addingTimeInterval(-Double(index))
            )
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = LauncherViewModel(
            catalog: ApplicationCatalog(
                store: nil,
                discoverer: StubApplicationDiscoverer(applications: [])
            ),
            featureCatalog: FeatureCommandCatalog(store: nil),
            clipboardCatalog: ClipboardCatalog(
                store: nil,
                initialItems: clipboardItems
            ),
            snippetCatalog: SnippetCatalog(
                store: nil,
                initialSnippets: snippets
            ),
            clipboardPreferences: ClipboardPreferences(defaults: defaults),
            urlPreviewService: URLPreviewService(store: nil),
            launcher: StubApplicationLauncher(shouldFail: false)
        )
        viewModel.start()
        try await waitUntil {
            viewModel.clipboardItems.count == 2_000
                && viewModel.snippets.count == 2_000
        }

        var clipboardDurations: [TimeInterval] = []
        var snippetDurations: [TimeInterval] = []
        for _ in 0..<50 {
            let clipboardStart = ProcessInfo.processInfo.systemUptime
            viewModel.prepareForPresentation(route: .clipboard, origin: .direct)
            while viewModel.results.first?.kind != .clipboard {
                await Task.yield()
            }
            clipboardDurations.append(
                ProcessInfo.processInfo.systemUptime - clipboardStart
            )

            let snippetStart = ProcessInfo.processInfo.systemUptime
            viewModel.prepareForPresentation(route: .snippets, origin: .direct)
            while viewModel.results.first?.kind != .snippet {
                await Task.yield()
            }
            snippetDurations.append(
                ProcessInfo.processInfo.systemUptime - snippetStart
            )
        }

        let clipboardP95 = clipboardDurations.sorted()[47]
        let snippetP95 = snippetDurations.sorted()[47]
        viewModel.prepareForPresentation(route: .clipboard, origin: .direct)
        var selectionDurations: [TimeInterval] = []
        selectionDurations.reserveCapacity(100)
        for index in 0..<100 {
            let selectionStart = ProcessInfo.processInfo.systemUptime
            viewModel.moveSelection(by: index.isMultiple(of: 2) ? 1 : -1)
            selectionDurations.append(
                ProcessInfo.processInfo.systemUptime - selectionStart
            )
        }
        let selectionP95 = selectionDurations.sorted()[94]
        print("YOROZU_PERF clipboard_route_p95_ms=\(clipboardP95 * 1_000)")
        print("YOROZU_PERF snippet_route_p95_ms=\(snippetP95 * 1_000)")
        print("YOROZU_PERF selection_p95_ms=\(selectionP95 * 1_000)")
        XCTAssertLessThan(clipboardP95, 0.050)
        XCTAssertLessThan(snippetP95, 0.050)
        XCTAssertLessThan(selectionP95, 0.016)
    }

    func testStaleImageDecodeCannotOverwriteTheCurrentSelection() async throws {
        let now = Date()
        let first = ClipboardItem(
            id: UUID(),
            kind: .image,
            contentHash: "first-image",
            textContent: nil,
            filePaths: [],
            imageData: Data([1]),
            imageByteCount: 1,
            imageWidth: 1,
            imageHeight: 1,
            normalizedSearchText: "first image",
            sourceBundleIdentifier: nil,
            sourceApplicationName: nil,
            isPinned: false,
            pinnedAt: nil,
            copiedAt: now,
            updatedAt: now
        )
        let second = ClipboardItem(
            id: UUID(),
            kind: .image,
            contentHash: "second-image",
            textContent: nil,
            filePaths: [],
            imageData: Data([2]),
            imageByteCount: 1,
            imageWidth: 2,
            imageHeight: 1,
            normalizedSearchText: "second image",
            sourceBundleIdentifier: nil,
            sourceApplicationName: nil,
            isPinned: false,
            pinnedAt: nil,
            copiedAt: now.addingTimeInterval(-1),
            updatedAt: now
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = LauncherViewModel(
            catalog: ApplicationCatalog(
                store: nil,
                discoverer: StubApplicationDiscoverer(applications: [])
            ),
            featureCatalog: FeatureCommandCatalog(store: nil),
            clipboardCatalog: ClipboardCatalog(
                store: nil,
                initialItems: [first, second]
            ),
            snippetCatalog: SnippetCatalog(store: nil),
            clipboardPreferences: ClipboardPreferences(defaults: defaults),
            urlPreviewService: URLPreviewService(store: nil),
            launcher: StubApplicationLauncher(shouldFail: false),
            clipboardImageDecoder: DelayedClipboardImageDecoder()
        )
        viewModel.start()
        try await waitUntil { viewModel.clipboardItems.count == 2 }
        viewModel.prepareForPresentation(route: .clipboard, origin: .direct)
        viewModel.selectedID = CommandResultID(
            rawValue: "clipboard:\(second.id.uuidString)"
        )

        try await waitUntil {
            viewModel.selectedClipboardImage?.width == 2
        }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(viewModel.selectedClipboardImage?.width, 2)
        XCTAssertEqual(viewModel.selectedClipboardItem?.id, second.id)
    }

    func testFeatureRouteTransitionPublishesCachedTargetResultsImmediately() async throws {
        let now = Date()
        let clipboardItem = ClipboardItem(
            id: UUID(),
            kind: .text,
            contentHash: "clipboard",
            textContent: "Clipboard value",
            filePaths: [],
            imageData: nil,
            imageByteCount: nil,
            imageWidth: nil,
            imageHeight: nil,
            normalizedSearchText: "clipboard value",
            sourceBundleIdentifier: nil,
            sourceApplicationName: nil,
            isPinned: false,
            pinnedAt: nil,
            copiedAt: now,
            updatedAt: now
        )
        let snippet = try Snippet.validated(
            name: "Greeting",
            keyword: ";hello",
            content: "Hello",
            now: now
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = LauncherViewModel(
            catalog: ApplicationCatalog(
                store: nil,
                discoverer: StubApplicationDiscoverer(applications: [])
            ),
            featureCatalog: FeatureCommandCatalog(store: nil),
            clipboardCatalog: ClipboardCatalog(
                store: nil,
                initialItems: [clipboardItem]
            ),
            snippetCatalog: SnippetCatalog(
                store: nil,
                initialSnippets: [snippet]
            ),
            clipboardPreferences: ClipboardPreferences(defaults: defaults),
            urlPreviewService: URLPreviewService(store: nil),
            launcher: StubApplicationLauncher(shouldFail: false)
        )
        viewModel.start()
        try await waitUntil {
            viewModel.clipboardItems.count == 1
                && viewModel.snippets.count == 1
        }

        viewModel.prepareForPresentation(route: .clipboard, origin: .direct)
        XCTAssertEqual(viewModel.route, .clipboard)
        XCTAssertEqual(viewModel.results.map(\.kind), [.clipboard])
        let clipboardSelection = viewModel.selectedID

        viewModel.prepareForPresentation(route: .snippets, origin: .direct)
        XCTAssertEqual(viewModel.route, .snippets)
        XCTAssertEqual(viewModel.results.map(\.kind), [.snippet])

        viewModel.prepareForPresentation(route: .clipboard, origin: .direct)
        XCTAssertEqual(viewModel.results.map(\.kind), [.clipboard])
        XCTAssertEqual(viewModel.selectedID, clipboardSelection)
    }

    func testClipboardSnapshotDiffPreservesSelectionAndLatestQueryWins() async throws {
        let now = Date()
        func item(_ title: String, offset: TimeInterval) -> ClipboardItem {
            ClipboardItem(
                id: UUID(),
                kind: .text,
                contentHash: title,
                textContent: title,
                filePaths: [],
                imageData: nil,
                imageByteCount: nil,
                imageWidth: nil,
                imageHeight: nil,
                normalizedSearchText: title.launcherNormalized,
                sourceBundleIdentifier: nil,
                sourceApplicationName: nil,
                isPinned: false,
                pinnedAt: nil,
                copiedAt: now.addingTimeInterval(offset),
                updatedAt: now
            )
        }
        let first = item("First value", offset: -1)
        let selected = item("Selected value", offset: -2)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = LauncherViewModel(
            catalog: ApplicationCatalog(
                store: nil,
                discoverer: StubApplicationDiscoverer(applications: [])
            ),
            featureCatalog: FeatureCommandCatalog(store: nil),
            clipboardCatalog: ClipboardCatalog(
                store: nil,
                initialItems: [first, selected]
            ),
            snippetCatalog: SnippetCatalog(store: nil),
            clipboardPreferences: ClipboardPreferences(defaults: defaults),
            urlPreviewService: URLPreviewService(store: nil),
            launcher: StubApplicationLauncher(shouldFail: false)
        )
        viewModel.start()
        try await waitUntil { viewModel.clipboardItems.count == 2 }
        viewModel.prepareForPresentation(route: .clipboard, origin: .direct)
        viewModel.selectedID = CommandResultID(rawValue: "clipboard:\(selected.id.uuidString)")

        let newest = item("Newest value", offset: 1)
        viewModel.handleClipboardSnapshot(
            FeatureSnapshot(
                values: [newest, first, selected],
                storageAvailable: true,
                message: nil
            )
        )
        XCTAssertEqual(
            viewModel.selectedClipboardItem?.id,
            selected.id,
            "An incremental clipboard update must not reset the current selection"
        )

        viewModel.query = "selected"
        viewModel.query = "no matching value"
        try await waitUntil { viewModel.results.isEmpty }
        XCTAssertEqual(viewModel.query, "no matching value")
    }

    func testSuccessfulLaunchIncrementsUsage() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        fixture.viewModel.query = "Fixture"

        try await waitUntil {
            fixture.viewModel.results.count == 1
        }
        fixture.viewModel.openSelectedApplication()

        try await waitUntil {
            fixture.launcher.launchAttempts == 1
        }
        try await waitUntil {
            let applications = try await fixture.store.loadApplications()
            return applications.first?.preference.launchCount == 1
        }
    }

    func testFailedLaunchDoesNotIncrementUsage() async throws {
        let fixture = try makeFixture(launcherShouldFail: true)
        fixture.viewModel.start()
        fixture.viewModel.query = "Fixture"

        try await waitUntil {
            fixture.viewModel.results.count == 1
        }
        fixture.viewModel.openSelectedApplication()

        try await waitUntil {
            fixture.viewModel.errorMessage != nil
        }
        let applications = try await fixture.store.loadApplications()
        XCTAssertEqual(applications.first?.preference.launchCount, 0)
    }

    func testActionPanelFiltersAndKeepsAValidSelection() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        fixture.viewModel.query = "Fixture"

        try await waitUntil {
            fixture.viewModel.results.count == 1
        }

        fixture.viewModel.showActionMenu()
        XCTAssertTrue(fixture.viewModel.isActionPanelPresented)
        XCTAssertEqual(fixture.viewModel.selectedActionID, .open)

        fixture.viewModel.actionQuery = "Alias"
        XCTAssertEqual(fixture.viewModel.filteredActionItems.map(\.id), [.editAlias])
        XCTAssertEqual(fixture.viewModel.selectedActionID, .editAlias)

        fixture.viewModel.escape()
        XCTAssertFalse(fixture.viewModel.isActionPanelPresented)
        XCTAssertEqual(fixture.viewModel.actionQuery, "")
    }

    func testFooterActionsExposeMouseEquivalentForKeyboardCommands() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        fixture.viewModel.query = "Fixture"

        try await waitUntil {
            fixture.viewModel.results.count == 1
        }

        XCTAssertEqual(
            fixture.viewModel.footerActions.map(\.id),
            [.primary, .actions]
        )
        XCTAssertTrue(fixture.viewModel.isFooterActionEnabled(.actions))

        fixture.viewModel.performFooterAction(.actions)

        XCTAssertTrue(fixture.viewModel.isActionPanelPresented)
    }

    func testShortcutCatalogStartsWithTheLauncherShortcut() {
        XCTAssertEqual(
            AppShortcutCatalog.settings.map(\.id),
            [
                "open-launcher",
                "open-clipboard-history",
                "open-snippets",
                "open-aliases",
            ]
        )
    }

    func testMenuBarSettingsActionUsesThePaletteSettingsHandler() throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        var didOpenSettings = false
        let controller = MenuBarController(
            viewModel: fixture.viewModel,
            openPalette: {},
            openSettings: {
                didOpenSettings = true
            }
        )

        controller.showSettings()

        XCTAssertTrue(didOpenSettings)
        withExtendedLifetime(controller) {}
    }

    func testFeatureOpenedFromRootReturnsToRootOnEscape() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.prepareForPresentation(route: .root, origin: .direct)
        fixture.viewModel.openFeature(.clipboardHistory)

        XCTAssertEqual(fixture.viewModel.route, .clipboard)
        XCTAssertEqual(fixture.viewModel.presentationOrigin, .root)

        fixture.viewModel.escape()
        XCTAssertEqual(fixture.viewModel.route, .root)
        try await waitUntil {
            try await fixture.store.loadPreference(
                identity: FeatureCommand.clipboardHistory.preferenceIdentity
            ).launchCount == 1
        }
    }

    func testDirectFeatureEscapeDismissesPalette() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        var didDismiss = false
        fixture.viewModel.dismissAndRestorePreviousApplication = {
            didDismiss = true
        }
        fixture.viewModel.prepareForPresentation(route: .snippets, origin: .direct)

        fixture.viewModel.escape()

        XCTAssertTrue(didDismiss)
        XCTAssertEqual(fixture.viewModel.route, .snippets)
        try await waitUntil {
            try await fixture.store.loadPreference(
                identity: FeatureCommand.snippets.preferenceIdentity
            ).launchCount == 1
        }
    }

    func testSettingsIsSearchableAndReturnsToRootWhenOpenedFromRoot() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        fixture.viewModel.query = "settings"

        try await waitUntil {
            fixture.viewModel.results.map(\.title) == ["Settings"]
        }

        fixture.viewModel.performPrimaryAction()
        XCTAssertEqual(fixture.viewModel.route, .settings)
        XCTAssertEqual(fixture.viewModel.presentationOrigin, .root)

        fixture.viewModel.escape()
        XCTAssertEqual(fixture.viewModel.route, .root)
    }

    func testDirectSettingsEscapeDismissesPalette() throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        var didDismiss = false
        fixture.viewModel.dismissAndRestorePreviousApplication = {
            didDismiss = true
        }
        fixture.viewModel.prepareForPresentation(route: .settings, origin: .direct)

        fixture.viewModel.escape()

        XCTAssertTrue(didDismiss)
        XCTAssertEqual(fixture.viewModel.route, .settings)
    }

    func testRootResultsMixFeaturesAndApplicationsByLastUse() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        try await fixture.store.savePreference(
            identity: FeatureCommand.snippets.preferenceIdentity,
            preference: LauncherPreference(
                alias: nil,
                isPinned: false,
                pinnedAt: nil,
                launchCount: 2,
                lastLaunchedAt: Date(timeIntervalSince1970: 300)
            )
        )
        try await fixture.store.savePreference(
            identity: ApplicationIdentity(rawValue: "bundle:com.example.fixture"),
            preference: LauncherPreference(
                alias: nil,
                isPinned: false,
                pinnedAt: nil,
                launchCount: 1,
                lastLaunchedAt: Date(timeIntervalSince1970: 200)
            )
        )

        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.results.count == 5
                && fixture.viewModel.installedApplications.count == 1
        }

        XCTAssertEqual(
            fixture.viewModel.results.map(\.title),
            ["Snippets", "Fixture", "Aliases", "Clipboard History", "Settings"]
        )
    }

    func testRootActionPanelOpensAliasesEditorForSelectedApplication() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        fixture.viewModel.query = "Fixture"
        try await waitUntil {
            fixture.viewModel.results.map(\.title) == ["Fixture"]
        }

        fixture.viewModel.showActionMenu()
        fixture.viewModel.performAction(.editAlias)

        XCTAssertEqual(fixture.viewModel.route, .aliases)
        XCTAssertEqual(fixture.viewModel.presentationOrigin, .root)
        XCTAssertEqual(
            fixture.viewModel.aliasEditorMode,
            .editing(ApplicationIdentity(rawValue: "bundle:com.example.fixture"))
        )
        XCTAssertEqual(fixture.viewModel.aliasDraft, "")
    }

    func testAddAliasSelectsExistingApplicationAndSavesIntoRootSearch() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.installedApplications.count == 1
        }

        fixture.viewModel.openFeature(.aliases)
        fixture.viewModel.beginAddAlias()
        XCTAssertEqual(fixture.viewModel.aliasEditorMode, .selectingApplication)
        XCTAssertEqual(
            fixture.viewModel.selectedAliasApplicationID,
            ApplicationIdentity(rawValue: "bundle:com.example.fixture")
        )

        fixture.viewModel.chooseSelectedAliasApplication()
        fixture.viewModel.aliasDraft = "  work browser  "
        fixture.viewModel.saveAlias()

        try await waitUntil {
            fixture.viewModel.aliasEditorMode == nil
                && fixture.viewModel.results.first?.title == "Fixture"
        }
        let savedPreference = try await fixture.store.loadPreference(
            identity: ApplicationIdentity(
                rawValue: "bundle:com.example.fixture"
            )
        )
        XCTAssertEqual(savedPreference.alias, "work browser")

        fixture.viewModel.returnToRoot()
        fixture.viewModel.query = "work browser"
        try await waitUntil {
            fixture.viewModel.results.first?.title == "Fixture"
        }
    }

    func testAddAliasForApplicationWithExistingAliasEntersEditMode() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        let identity = ApplicationIdentity(rawValue: "bundle:com.example.fixture")
        try await fixture.store.savePreference(
            identity: identity,
            preference: LauncherPreference(
                alias: "existing",
                isPinned: false,
                pinnedAt: nil,
                launchCount: 0,
                lastLaunchedAt: nil
            )
        )
        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.installedApplications.first?.preference.alias
                == "existing"
        }

        fixture.viewModel.openFeature(.aliases)
        fixture.viewModel.beginAddAlias()
        fixture.viewModel.chooseSelectedAliasApplication()

        XCTAssertEqual(fixture.viewModel.aliasEditorMode, .editing(identity))
        XCTAssertEqual(fixture.viewModel.aliasDraft, "existing")
    }

    func testAliasValidationRejectsEmptyAndOversizedValues() throws {
        XCTAssertThrowsError(try LauncherViewModel.validatedAlias("   "))
        XCTAssertThrowsError(
            try LauncherViewModel.validatedAlias(String(repeating: "a", count: 65))
        )
        XCTAssertEqual(
            try LauncherViewModel.validatedAlias("  日本語 alias  "),
            "日本語 alias"
        )
    }

    func testAliasSaveFailureKeepsEditorAndDraft() async throws {
        enum SaveFailure: Error {
            case failed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let application = DiscoveredApplication(
            id: ApplicationIdentity(rawValue: "bundle:com.example.fixture"),
            bundleIdentifier: "com.example.fixture",
            canonicalURL: URL(fileURLWithPath: "/Applications/Fixture.app"),
            displayName: "Fixture",
            localizedName: nil,
            version: "1.0",
            normalizedSearchText: "fixture com.example.fixture",
            rootPriority: 1
        )
        let store = try LauncherStore(
            databaseURL: directory.appendingPathComponent("Yorozu.sqlite")
        )
        let catalog = ApplicationCatalog(
            store: store,
            discoverer: StubApplicationDiscoverer(applications: [application]),
            aliasPreferenceSaver: { _, _ in
                throw SaveFailure.failed
            }
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = LauncherViewModel(
            catalog: catalog,
            featureCatalog: FeatureCommandCatalog(store: store),
            clipboardCatalog: ClipboardCatalog(store: store),
            snippetCatalog: SnippetCatalog(store: store),
            clipboardPreferences: ClipboardPreferences(defaults: defaults),
            urlPreviewService: URLPreviewService(store: store),
            launcher: StubApplicationLauncher(shouldFail: false)
        )
        viewModel.start()
        try await waitUntil {
            viewModel.installedApplications.count == 1
        }
        viewModel.openFeature(.aliases)
        viewModel.beginAddAlias()
        viewModel.chooseSelectedAliasApplication()
        viewModel.aliasDraft = "keep me"
        viewModel.saveAlias()

        try await waitUntil {
            viewModel.aliasValidationMessage != nil
        }
        XCTAssertEqual(viewModel.aliasDraft, "keep me")
        XCTAssertEqual(
            viewModel.aliasEditorMode,
            .editing(application.id)
        )
        XCTAssertNil(viewModel.installedApplications.first?.preference.alias)
    }

    func testAliasEscapeCancelsEditingBeforeReturningToRoot() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.installedApplications.count == 1
        }
        fixture.viewModel.openFeature(.aliases)
        fixture.viewModel.beginAddAlias()

        fixture.viewModel.escape()
        XCTAssertNil(fixture.viewModel.aliasEditorMode)
        XCTAssertEqual(fixture.viewModel.route, .aliases)

        fixture.viewModel.escape()
        XCTAssertEqual(fixture.viewModel.route, .root)
    }

    func testDeletingAliasSelectsNeighborAndPreservesOtherPreferences() async throws {
        let first = DiscoveredApplication(
            id: ApplicationIdentity(rawValue: "bundle:com.example.alpha"),
            bundleIdentifier: "com.example.alpha",
            canonicalURL: URL(fileURLWithPath: "/Applications/Alpha.app"),
            displayName: "Alpha",
            localizedName: nil,
            version: "1.0",
            normalizedSearchText: "alpha com.example.alpha",
            rootPriority: 1
        )
        let second = DiscoveredApplication(
            id: ApplicationIdentity(rawValue: "bundle:com.example.beta"),
            bundleIdentifier: "com.example.beta",
            canonicalURL: URL(fileURLWithPath: "/Applications/Beta.app"),
            displayName: "Beta",
            localizedName: nil,
            version: "1.0",
            normalizedSearchText: "beta com.example.beta",
            rootPriority: 1
        )
        let fixture = try makeFixture(
            launcherShouldFail: false,
            applications: [first, second]
        )
        let pinnedAt = Date(timeIntervalSince1970: 100)
        let launchedAt = Date(timeIntervalSince1970: 200)
        try await fixture.store.savePreference(
            identity: first.id,
            preference: LauncherPreference(
                alias: "first",
                isPinned: true,
                pinnedAt: pinnedAt,
                launchCount: 7,
                lastLaunchedAt: launchedAt
            )
        )
        try await fixture.store.savePreference(
            identity: second.id,
            preference: LauncherPreference(
                alias: "second",
                isPinned: false,
                pinnedAt: nil,
                launchCount: 0,
                lastLaunchedAt: nil
            )
        )

        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.installedApplications.count == 2
        }
        fixture.viewModel.openFeature(.aliases)
        try await waitUntil {
            fixture.viewModel.results.count == 2
        }
        fixture.viewModel.selectedID = fixture.viewModel.results.first?.id

        fixture.viewModel.requestAliasDeletion()
        XCTAssertEqual(fixture.viewModel.aliasDeletionCandidate?.id, first.id)
        fixture.viewModel.confirmAliasDeletion()

        try await waitUntil {
            fixture.viewModel.results.count == 1
                && fixture.viewModel.selectedResult?.title == "Beta"
        }
        let preference = try await fixture.store.loadPreference(identity: first.id)
        XCTAssertNil(preference.alias)
        XCTAssertTrue(preference.isPinned)
        XCTAssertEqual(preference.pinnedAt, pinnedAt)
        XCTAssertEqual(preference.launchCount, 7)
        XCTAssertEqual(preference.lastLaunchedAt, launchedAt)
    }

    private func keyAction(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        hasMarkedText: Bool = false,
        route: PaletteRoute = .root,
        isActionPanelPresented: Bool = false
    ) -> PaletteKeyEventAction {
        PaletteKeyEventPolicy.action(
            keyCode: keyCode,
            modifiers: modifiers,
            hasMarkedText: hasMarkedText,
            route: route,
            isActionPanelPresented: isActionPanelPresented
        )
    }

    func testTypingSelectsTheBestMatchInsteadOfKeepingAStaleFuzzySelection() async throws {
        let fixture = try makeFixture(
            launcherShouldFail: false,
            applicationName: "Code"
        )
        fixture.viewModel.start()

        try await waitUntil {
            fixture.viewModel.results.count == 5
                && fixture.viewModel.installedApplications.count == 1
        }
        let clipboardID = try XCTUnwrap(
            fixture.viewModel.results.first(where: { $0.title == "Clipboard History" })?.id
        )
        fixture.viewModel.selectedID = clipboardID

        fixture.viewModel.query = "code"

        try await waitUntil {
            fixture.viewModel.results.first?.title == "Code"
                && fixture.viewModel.results.contains(where: {
                    $0.title == "Clipboard History"
                })
        }
        XCTAssertEqual(fixture.viewModel.selectedResult?.title, "Code")
    }

    func testOpeningFeatureRecordsPersistentUsage() async throws {
        let fixture = try makeFixture(launcherShouldFail: false)
        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.featureCommands.count == FeatureCommand.all.count
        }

        fixture.viewModel.openFeature(.clipboardHistory)

        try await waitUntil {
            try await fixture.store.loadPreference(
                identity: FeatureCommand.clipboardHistory.preferenceIdentity
            ).launchCount == 1
        }
        let preference = try await fixture.store.loadPreference(
            identity: FeatureCommand.clipboardHistory.preferenceIdentity
        )
        XCTAssertNotNil(preference.lastLaunchedAt)
    }

    private func makeFixture(
        launcherShouldFail: Bool,
        applicationName: String = "Fixture",
        applications: [DiscoveredApplication]? = nil
    ) throws -> (
        viewModel: LauncherViewModel,
        launcher: StubApplicationLauncher,
        store: LauncherStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let application = DiscoveredApplication(
            id: ApplicationIdentity(rawValue: "bundle:com.example.fixture"),
            bundleIdentifier: "com.example.fixture",
            canonicalURL: URL(fileURLWithPath: "/Applications/Fixture.app"),
            displayName: applicationName,
            localizedName: nil,
            version: "1.0",
            normalizedSearchText: "fixture com.example.fixture",
            rootPriority: 1
        )
        let store = try LauncherStore(
            databaseURL: directory.appendingPathComponent("Yorozu.sqlite")
        )
        let catalog = ApplicationCatalog(
            store: store,
            discoverer: StubApplicationDiscoverer(
                applications: applications ?? [application]
            )
        )
        let launcher = StubApplicationLauncher(shouldFail: launcherShouldFail)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = LauncherViewModel(
            catalog: catalog,
            featureCatalog: FeatureCommandCatalog(store: store),
            clipboardCatalog: ClipboardCatalog(store: store),
            snippetCatalog: SnippetCatalog(store: store),
            clipboardPreferences: ClipboardPreferences(defaults: defaults),
            urlPreviewService: URLPreviewService(store: store),
            launcher: launcher
        )
        return (viewModel, launcher, store)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @MainActor () async throws -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met within \(timeout) seconds")
    }
}

private struct StubApplicationDiscoverer: ApplicationDiscovering {
    let applications: [DiscoveredApplication]

    func discoverApplications() async throws -> [DiscoveredApplication] {
        applications
    }
}

private actor DelayedClipboardImageDecoder: ClipboardImageDecoding {
    func decode(_ data: Data) async -> CGImage? {
        let width = max(1, Int(data.first ?? 1))
        if width == 1 {
            try? await Task.sleep(for: .milliseconds(80))
        }
        return Self.image(width: width)
    }

    private nonisolated static func image(width: Int) -> CGImage? {
        let bytes = Data(repeating: 0x7F, count: width * 4)
        guard let provider = CGDataProvider(data: bytes as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

@MainActor
private final class StubApplicationLauncher: ApplicationLaunching {
    enum StubError: Error {
        case failed
    }

    let shouldFail: Bool
    private(set) var launchAttempts = 0

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func launch(_ application: LaunchableApplication) async throws {
        launchAttempts += 1
        if shouldFail {
            throw StubError.failed
        }
    }

    func revealInFinder(_ application: LaunchableApplication) {}
}
