import CoreGraphics
import XCTest
@testable import Yorozu

@MainActor
final class CommandInputModeSwitchingTests: XCTestCase {
    func testInputSourceResolverUsesPreferredSelectableSource() {
        let candidates = [
            candidate(id: "english.other", ascii: true),
            candidate(id: "english.preferred", ascii: true),
        ]

        XCTAssertEqual(
            CommandInputSourceResolver.sourceID(
                for: .switchToEnglish,
                candidates: candidates,
                preferredSourceID: "english.preferred"
            ),
            "english.preferred"
        )
    }

    func testInputSourceResolverFallsBackDeterministically() {
        let candidates = [
            candidate(id: "jp.z", languages: ["ja"]),
            candidate(id: "jp.a", languages: ["ja-JP"]),
            candidate(id: "disabled", languages: ["ja"], enabled: false),
        ]

        XCTAssertEqual(
            CommandInputSourceResolver.sourceID(
                for: .switchToJapanese,
                candidates: candidates,
                preferredSourceID: nil
            ),
            "jp.a"
        )
    }

    func testInputSourceResolverRejectsUnavailableLanguage() {
        XCTAssertNil(
            CommandInputSourceResolver.sourceID(
                for: .switchToJapanese,
                candidates: [candidate(id: "english", ascii: true)],
                preferredSourceID: nil
            )
        )
    }

    func testInputSourceResolverRejectsCharacterPalette() {
        XCTAssertNil(
            CommandInputSourceResolver.sourceID(
                for: .switchToJapanese,
                candidates: [
                    candidate(
                        id: "com.apple.50onPaletteIM",
                        languages: ["ja"],
                        keyboardSource: false
                    ),
                ],
                preferredSourceID: "com.apple.50onPaletteIM"
            )
        )
    }

    func testInputSourceSwitcherSelectsAndVerifiesTarget() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"]
        )
        let switcher = SystemCommandInputSourceSwitcher(system: system)

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(report.result, .switched(sourceID: "japanese"))
        XCTAssertEqual(report.sourceIDBefore, "english")
        XCTAssertEqual(report.sourceIDAfter, "japanese")
        XCTAssertEqual(system.selectedSourceIDs, ["japanese"])
    }

    func testInputSourceSwitcherReportsUnavailableWithoutSelecting() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [candidate(id: "english", ascii: true)]
        )
        let switcher = SystemCommandInputSourceSwitcher(system: system)

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(
            report.result,
            .sourceUnavailable(.switchToJapanese)
        )
        XCTAssertTrue(system.selectedSourceIDs.isEmpty)
    }

    func testInputSourceSwitcherReportsSelectionFailure() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"],
            selectSucceeds: false
        )
        let switcher = SystemCommandInputSourceSwitcher(system: system)

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(report.result, .selectionFailed)
        XCTAssertEqual(report.sourceIDAfter, "english")
    }

    func testInputSourceSwitcherReportsAlreadySelected() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "japanese",
            candidates: [candidate(id: "japanese", languages: ["ja"])],
            preferred: [.switchToJapanese: "japanese"]
        )
        let switcher = SystemCommandInputSourceSwitcher(system: system)

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(
            report.result,
            .alreadySelected(sourceID: "japanese")
        )
        XCTAssertTrue(system.selectedSourceIDs.isEmpty)
    }

    func testInputSourceSwitcherTimesOutWhenSelectionIsNotObservable() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"],
            updatesCurrentSourceOnSelect: false
        )
        let switcher = SystemCommandInputSourceSwitcher(system: system)

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(report.result, .verificationTimedOut)
        XCTAssertEqual(report.sourceIDAfter, "english")
        XCTAssertEqual(system.selectedSourceIDs, ["japanese"])
    }

    func testInputSourceSwitcherStopsVerificationWhenCancelled() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"],
            updatesCurrentSourceOnSelect: false
        )
        let switcher = SystemCommandInputSourceSwitcher(system: system)
        let task = Task {
            await switcher.switchInputMode(.switchToJapanese)
        }

        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        let report = await task.value

        XCTAssertEqual(report.result, .cancelled)
    }

    func testBackgroundMonitorActivityRemainsResponsiveWhenAppIsInactive() {
        let options =
            SystemCommandInputModeBackgroundActivityManager.activityOptions

        XCTAssertEqual(
            options,
            [
                .userInitiatedAllowingIdleSystemSleep,
                .automaticTerminationDisabled,
            ]
        )
        XCTAssertTrue(options.contains(.userInitiatedAllowingIdleSystemSleep))
        XCTAssertTrue(options.contains(.automaticTerminationDisabled))
        XCTAssertFalse(options.contains(.idleSystemSleepDisabled))
    }

    func testLeftAndRightCommandSinglesProduceTheirModeActions() {
        var state = CommandInputModeStateMachine()

        XCTAssertNil(
            state.handleFlagsChanged(
                keyCode: 55,
                flags: .maskCommand
            )
        )
        XCTAssertEqual(
            state.handleFlagsChanged(keyCode: 55, flags: []),
            .switchToEnglish
        )

        XCTAssertNil(
            state.handleFlagsChanged(
                keyCode: 54,
                flags: .maskCommand
            )
        )
        XCTAssertEqual(
            state.handleFlagsChanged(keyCode: 54, flags: []),
            .switchToJapanese
        )
    }

    func testRegularKeyboardInputCancelsCommandCandidate() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        state.handleKeyboardActivity()

        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testOtherModifierCancelsCommandCandidate() {
        var state = CommandInputModeStateMachine()
        let flags = CGEventFlags(
            rawValue: CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskShift.rawValue
        )

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        _ = state.handleFlagsChanged(keyCode: 56, flags: flags)

        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testSecondCommandCancelsBothCommandCandidates() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        _ = state.handleFlagsChanged(
            keyCode: 54,
            flags: .maskCommand
        )
        _ = state.handleFlagsChanged(
            keyCode: 54,
            flags: .maskCommand
        )

        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testMouseAndScrollActivityCancelCommandCandidate() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        state.handleMouseActivity()
        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))

        _ = state.handleFlagsChanged(
            keyCode: 54,
            flags: .maskCommand
        )
        state.handleMouseActivity()
        XCTAssertNil(state.handleFlagsChanged(keyCode: 54, flags: []))
    }

    func testResetPreventsStaleCommandAction() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        state.reset()

        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testInitialSynchronizationConsumesAlreadyHeldCommandReleases() {
        var state = CommandInputModeStateMachine()
        state.synchronizePressedCommands([.left, .right])

        XCTAssertNil(
            state.handleFlagsChanged(
                keyCode: 55,
                flags: .maskCommand
            )
        )
        XCTAssertNil(state.handleFlagsChanged(keyCode: 54, flags: []))
        XCTAssertTrue(state.pressedCommands.isEmpty)
        XCTAssertNil(state.candidate)

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        XCTAssertEqual(
            state.handleFlagsChanged(keyCode: 55, flags: []),
            .switchToEnglish
        )
    }

    func testTrackedReleaseWinsWhileOtherCommandKeepsAggregateFlagSet() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        _ = state.handleFlagsChanged(
            keyCode: 54,
            flags: .maskCommand
        )

        XCTAssertNil(
            state.handleFlagsChanged(
                keyCode: 55,
                flags: .maskCommand
            )
        )
        XCTAssertNil(state.handleFlagsChanged(keyCode: 54, flags: []))
        XCTAssertTrue(state.pressedCommands.isEmpty)
    }

    func testCommandPressWhileSynchronizedOtherCommandIsHeldIsNotATap() {
        var state = CommandInputModeStateMachine()
        state.synchronizePressedCommands([.right])

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )

        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: .maskCommand))
        XCTAssertNil(state.handleFlagsChanged(keyCode: 54, flags: []))
    }

    func testAnyOtherModifierActivityCancelsCommandCandidate() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        _ = state.handleFlagsChanged(
            keyCode: 57,
            flags: .maskCommand
        )

        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testExtraReleaseAfterCompletedTapDoesNotProduceAnotherAction() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: .maskCommand
        )
        XCTAssertEqual(
            state.handleFlagsChanged(keyCode: 55, flags: []),
            .switchToEnglish
        )
        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testMalformedPressWithoutCommandFlagDoesNotProduceAction() {
        var state = CommandInputModeStateMachine()

        _ = state.handleFlagsChanged(
            keyCode: 55,
            flags: []
        )

        XCTAssertNil(state.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testCodeSigningClassificationDistinguishesStableAndAdHocBuilds() {
        XCTAssertEqual(
            SystemCommandInputModeCodeSigningStatusProvider
                .classifySigningInformation(
                    teamIdentifier: "TEAMID",
                    certificateCount: 0,
                    hasIdentifier: true
                ),
            .stable
        )
        XCTAssertEqual(
            SystemCommandInputModeCodeSigningStatusProvider
                .classifySigningInformation(
                    teamIdentifier: nil,
                    certificateCount: 1,
                    hasIdentifier: true
                ),
            .stable
        )
        XCTAssertEqual(
            SystemCommandInputModeCodeSigningStatusProvider
                .classifySigningInformation(
                    teamIdentifier: nil,
                    certificateCount: 0,
                    hasIdentifier: true
                ),
            .adHoc
        )
        XCTAssertEqual(
            SystemCommandInputModeCodeSigningStatusProvider
                .classifySigningInformation(
                    teamIdentifier: nil,
                    certificateCount: 0,
                    hasIdentifier: false
                ),
            .unknown
        )
    }

    func testControllerStartsOffWithoutRequestingPermissionsOrMonitoring() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider()
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions
        )

        controller.start()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.runtimeStatus, .off)
        XCTAssertEqual(monitor.startCount, 0)
        XCTAssertEqual(permissions.inputMonitoringRequestCount, 0)
    }

    func testControllerKeepsEnabledStateUntilPermissionsAreGranted() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider()
        let backgroundActivity = TestCommandInputModeBackgroundActivityManager()
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            backgroundActivityManager: backgroundActivity
        )
        controller.start()

        controller.isEnabled = true

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        XCTAssertEqual(monitor.startCount, 0)
        XCTAssertFalse(backgroundActivity.isActive)
        XCTAssertTrue(defaults.bool(forKey: "inputModeSwitching.isEnabled"))

        permissions.isInputMonitoringGranted = true
        controller.refreshAuthorization()

        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(backgroundActivity.isActive)

        controller.refreshAuthorization()
        XCTAssertEqual(backgroundActivity.beginCount, 1)
    }

    func testControllerRequiresListenPermissionEvenWhenOtherGrantsExist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true,
            isInputMonitoringGranted: false,
            isEventPostingGranted: true
        )
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions
        )

        controller.isEnabled = true
        controller.start()

        XCTAssertTrue(controller.isAccessibilityGranted)
        XCTAssertFalse(controller.isInputMonitoringGranted)
        XCTAssertTrue(controller.isEventPostingGranted)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        XCTAssertEqual(monitor.startCount, 0)
    }

    func testControllerStopsImmediatelyWhenDisabledOrStopped() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isInputMonitoringGranted: true
        )
        let backgroundActivity = TestCommandInputModeBackgroundActivityManager()
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            backgroundActivityManager: backgroundActivity
        )
        controller.isEnabled = true
        controller.start()
        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertTrue(backgroundActivity.isActive)

        controller.isEnabled = false
        XCTAssertEqual(controller.runtimeStatus, .off)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(backgroundActivity.isActive)

        controller.stop()
        XCTAssertGreaterThanOrEqual(monitor.stopCount, 1)
        XCTAssertGreaterThanOrEqual(backgroundActivity.endCount, 1)
    }

    func testControllerRecoversAnInvalidatedMonitorWhileBackgrounded() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isInputMonitoringGranted: true
        )
        let backgroundActivity = TestCommandInputModeBackgroundActivityManager()
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            backgroundActivityManager: backgroundActivity
        )

        controller.isEnabled = true
        controller.start()
        monitor.simulateInvalidation()
        controller.recoverMonitoringIfNeeded()

        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 2)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(backgroundActivity.isActive)
    }

    func testAuthorizationRefreshWhileInactiveKeepsMonitorAndActivityRunning() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isInputMonitoringGranted: true
        )
        let backgroundActivity = TestCommandInputModeBackgroundActivityManager()
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            backgroundActivityManager: backgroundActivity
        )

        controller.isEnabled = true
        controller.start()
        controller.refreshAuthorization()

        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(backgroundActivity.beginCount, 1)
        XCTAssertTrue(backgroundActivity.isActive)
    }

    func testControllerReportsUnavailableWhenAuthorizedMonitorCannotStart() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor(startResult: false)
        let permissions = TestCommandInputModePermissionProvider(
            isInputMonitoringGranted: true
        )
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions
        )

        controller.start()
        controller.isEnabled = true

        XCTAssertEqual(controller.runtimeStatus, .unavailable)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertFalse(monitor.isRunning)
    }

    func testDisabledControllerDoesNotCreateLiveMonitoringOrRequestAccess() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = CommandInputModeController.disabled(defaults: defaults)

        controller.start()
        controller.isEnabled = true
        controller.requestInputMonitoringAccess()

        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        XCTAssertTrue(controller.isEnabled)
    }

    func testControllerPublishesMonitorAndSwitchingDiagnostics() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isInputMonitoringGranted: true
        )
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            codeSigningStatusProvider: TestCommandInputModeCodeSigningProvider(
                status: .adHoc
            )
        )

        controller.start()
        controller.isEnabled = true
        let detectedAt = Date()
        monitor.simulateCommandDetection(at: detectedAt)
        controller.testSwitch(.switchToJapanese)

        XCTAssertEqual(controller.monitorStatus, .running)
        XCTAssertEqual(controller.codeSigningStatus, .adHoc)
        XCTAssertEqual(controller.lastCommandEventAt, detectedAt)
        XCTAssertEqual(controller.lastAction, .switchToJapanese)
        XCTAssertNotNil(controller.lastActionAt)
        XCTAssertEqual(
            controller.lastSwitchReport?.result,
            .switched(sourceID: "japanese")
        )
        XCTAssertEqual(monitor.testSwitchCount, 1)

        controller.isEnabled = false
        XCTAssertEqual(controller.monitorStatus, .stopped)
    }

    private func candidate(
        id: String,
        languages: [String] = [],
        ascii: Bool = false,
        enabled: Bool = true,
        selectCapable: Bool = true,
        keyboardSource: Bool = true
    ) -> CommandInputSourceCandidate {
        CommandInputSourceCandidate(
            id: id,
            languages: languages,
            isASCIICapable: ascii,
            isEnabled: enabled,
            isSelectCapable: selectCapable,
            isKeyboardSource: keyboardSource
        )
    }
}

private final class TestCommandInputSourceSystem:
    CommandInputSourceSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var currentID: String?
    private let availableCandidates: [CommandInputSourceCandidate]
    private let preferred: [CommandInputModeAction: String]
    private let selectSucceeds: Bool
    private let updatesCurrentSourceOnSelect: Bool
    private var selectedIDs: [String] = []

    init(
        currentSourceID: String?,
        candidates: [CommandInputSourceCandidate],
        preferred: [CommandInputModeAction: String] = [:],
        selectSucceeds: Bool = true,
        updatesCurrentSourceOnSelect: Bool = true
    ) {
        currentID = currentSourceID
        availableCandidates = candidates
        self.preferred = preferred
        self.selectSucceeds = selectSucceeds
        self.updatesCurrentSourceOnSelect = updatesCurrentSourceOnSelect
    }

    var selectedSourceIDs: [String] {
        lock.withLock { selectedIDs }
    }

    func currentSourceID() -> String? {
        lock.withLock { currentID }
    }

    func candidates() -> [CommandInputSourceCandidate] {
        availableCandidates
    }

    func preferredSourceID(for action: CommandInputModeAction) -> String? {
        preferred[action]
    }

    func selectSource(id: String) -> Bool {
        lock.withLock {
            selectedIDs.append(id)
            if selectSucceeds, updatesCurrentSourceOnSelect {
                currentID = id
            }
            return selectSucceeds
        }
    }
}

@MainActor
private final class TestCommandInputModeMonitor: CommandInputModeMonitoring {
    private(set) var isRunning = false
    private(set) var status: CommandInputModeMonitorStatus = .stopped
    var lastCommandEventAt: Date?
    private(set) var lastAction: CommandInputModeAction?
    private(set) var lastActionAt: Date?
    private(set) var lastSwitchReport: CommandInputModeSwitchReport?
    var diagnosticsDidChange: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var testSwitchCount = 0
    private let startResult: Bool

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    func start() -> Bool {
        startCount += 1
        isRunning = startResult
        status = startResult ? .running : .creationFailed
        diagnosticsDidChange?()
        return startResult
    }

    func stop() {
        stopCount += 1
        isRunning = false
        status = .stopped
        diagnosticsDidChange?()
    }

    func switchForTesting(_ action: CommandInputModeAction) {
        testSwitchCount += 1
        lastAction = action
        lastActionAt = Date()
        lastSwitchReport = CommandInputModeSwitchReport(
            action: action,
            result: .switched(sourceID: "japanese"),
            sourceIDBefore: "english",
            sourceIDAfter: "japanese",
            completedAt: Date()
        )
        diagnosticsDidChange?()
    }

    func simulateCommandDetection(at date: Date) {
        lastCommandEventAt = date
        diagnosticsDidChange?()
    }

    func simulateInvalidation() {
        isRunning = false
        status = .temporarilyDisabled
        diagnosticsDidChange?()
    }
}

@MainActor
private final class TestCommandInputModePermissionProvider: CommandInputModePermissionProviding {
    var isAccessibilityGranted: Bool
    var isInputMonitoringGranted: Bool
    var isEventPostingGranted: Bool
    private(set) var inputMonitoringRequestCount = 0

    var authorizationSnapshot: CommandInputModeAuthorizationSnapshot {
        CommandInputModeAuthorizationSnapshot(
            accessibilityGranted: isAccessibilityGranted,
            listenEventGranted: isInputMonitoringGranted,
            postEventGranted: isEventPostingGranted
        )
    }

    init(
        isAccessibilityGranted: Bool = false,
        isInputMonitoringGranted: Bool = false,
        isEventPostingGranted: Bool = false
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.isInputMonitoringGranted = isInputMonitoringGranted
        self.isEventPostingGranted = isEventPostingGranted
    }

    func requestInputMonitoringAccess() {
        inputMonitoringRequestCount += 1
    }

    func requestAccessibilityAccess() {}
    func openAccessibilitySettings() {}
    func openInputMonitoringSettings() {}
    func revealCurrentBuild() {}
}

@MainActor
private final class TestCommandInputModeCodeSigningProvider:
    CommandInputModeCodeSigningStatusProviding {
    let status: CommandInputModeCodeSigningStatus

    init(status: CommandInputModeCodeSigningStatus) {
        self.status = status
    }
}

@MainActor
private final class TestCommandInputModeBackgroundActivityManager:
    CommandInputModeBackgroundActivityManaging {
    private(set) var isActive = false
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func begin() {
        guard !isActive else { return }
        beginCount += 1
        isActive = true
    }

    func end() {
        guard isActive else { return }
        endCount += 1
        isActive = false
    }
}
