import AppKit
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

    func testInputSourceResolverMatchesEffectiveModeWithoutRequiringOneID() {
        let candidates = [
            candidate(id: "english.custom", ascii: true),
            candidate(id: "japanese.custom", languages: ["ja-JP"]),
            candidate(
                id: "character.palette",
                languages: ["ja"],
                keyboardSource: false
            ),
        ]

        XCTAssertTrue(
            CommandInputSourceResolver.sourceID(
                "english.custom",
                matches: .switchToEnglish,
                candidates: candidates
            )
        )
        XCTAssertTrue(
            CommandInputSourceResolver.sourceID(
                "japanese.custom",
                matches: .switchToJapanese,
                candidates: candidates
            )
        )
        XCTAssertFalse(
            CommandInputSourceResolver.sourceID(
                "english.custom",
                matches: .switchToJapanese,
                candidates: candidates
            )
        )
        XCTAssertFalse(
            CommandInputSourceResolver.sourceID(
                "character.palette",
                matches: .switchToJapanese,
                candidates: candidates
            )
        )
    }

    func testInputModeActionsUseNativeJISEisuAndKanaKeyCodes() {
        XCTAssertEqual(CommandInputModeAction.switchToEnglish.inputModeKeyCode, 102)
        XCTAssertEqual(CommandInputModeAction.switchToJapanese.inputModeKeyCode, 104)
    }

    func testCancelledInputSourceSwitchNeverPostsAKey() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ]
        )
        let poster = TestCommandInputModeEventPoster()
        let switcher = SystemCommandInputSourceSwitcher(system: system, eventPoster: poster)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await switcher.switchInputMode(.switchToJapanese)
        }
        let report = await task.value
        XCTAssertEqual(report.result, .cancelled)
        XCTAssertTrue(poster.postedActions.isEmpty)
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
        let poster = TestCommandInputModeEventPoster { _ in
            system.simulateSelection(id: "japanese")
        }
        let switcher = SystemCommandInputSourceSwitcher(
            system: system,
            eventPoster: poster
        )

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(report.result, .switched(sourceID: "japanese"))
        XCTAssertEqual(report.sourceIDBefore, "english")
        XCTAssertEqual(report.sourceIDAfter, "japanese")
        XCTAssertEqual(poster.postedActions, [.switchToJapanese])
    }

    func testInputSourceSwitcherMarshalsDetachedCallsToMainThread() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"]
        )
        let poster = TestCommandInputModeEventPoster { _ in
            system.simulateSelection(id: "japanese")
        }
        let switcher = SystemCommandInputSourceSwitcher(
            system: system,
            eventPoster: poster
        )

        let report = await Task.detached {
            await switcher.switchInputMode(.switchToJapanese)
        }.value

        XCTAssertEqual(report.result, .switched(sourceID: "japanese"))
        XCTAssertTrue(system.allCallsWereOnMainThread)
        XCTAssertTrue(poster.allCallsWereOnMainThread)
    }

    func testInputSourceSwitcherReportsUnavailableWithoutSelecting() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [candidate(id: "english", ascii: true)]
        )
        let poster = TestCommandInputModeEventPoster()
        let switcher = SystemCommandInputSourceSwitcher(
            system: system,
            eventPoster: poster
        )

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(
            report.result,
            .sourceUnavailable(.switchToJapanese)
        )
        XCTAssertTrue(poster.postedActions.isEmpty)
    }

    func testInputSourceSwitcherReportsSelectionFailure() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"]
        )
        let poster = TestCommandInputModeEventPoster(postSucceeds: false)
        let switcher = SystemCommandInputSourceSwitcher(
            system: system,
            eventPoster: poster
        )

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(report.result, .selectionFailed)
        XCTAssertEqual(report.sourceIDAfter, "english")
        XCTAssertEqual(poster.postedActions, [.switchToJapanese])
    }

    func testInputSourceSwitcherReportsAlreadySelected() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "japanese",
            candidates: [candidate(id: "japanese", languages: ["ja"])],
            preferred: [.switchToJapanese: "japanese"]
        )
        let poster = TestCommandInputModeEventPoster()
        let switcher = SystemCommandInputSourceSwitcher(
            system: system,
            eventPoster: poster
        )

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(
            report.result,
            .alreadySelected(sourceID: "japanese")
        )
        XCTAssertTrue(poster.postedActions.isEmpty)
    }

    func testInputSourceSwitcherTimesOutWhenSelectionIsNotObservable() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"]
        )
        let poster = TestCommandInputModeEventPoster()
        let switcher = SystemCommandInputSourceSwitcher(
            system: system,
            eventPoster: poster
        )

        let report = await switcher.switchInputMode(.switchToJapanese)

        XCTAssertEqual(report.result, .verificationTimedOut)
        XCTAssertEqual(report.sourceIDAfter, "english")
        XCTAssertEqual(poster.postedActions, [.switchToJapanese])
    }

    func testInputSourceSwitcherStopsVerificationWhenCancelled() async {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ],
            preferred: [.switchToJapanese: "japanese"]
        )
        let switcher = SystemCommandInputSourceSwitcher(
            system: system,
            eventPoster: TestCommandInputModeEventPoster()
        )
        let task = Task {
            await switcher.switchInputMode(.switchToJapanese)
        }

        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        let report = await task.value

        XCTAssertEqual(report.result, .cancelled)
    }

    func testInputSourceStatusProviderTracksSelectionNotifications() {
        let system = TestCommandInputSourceSystem(
            currentSourceID: "english",
            candidates: [
                candidate(id: "english", ascii: true),
                candidate(id: "japanese", languages: ["ja"]),
            ]
        )
        let provider = SystemCommandInputSourceStatusProvider(system: system)
        var observedSourceIDs: [String?] = []
        provider.currentSourceDidChange = {
            observedSourceIDs.append(provider.currentSourceID)
        }

        provider.start()
        system.simulateSelection(id: "japanese")
        NotificationCenter.default.post(
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        XCTAssertEqual(provider.currentSourceID, "japanese")
        XCTAssertEqual(observedSourceIDs, ["english", "japanese"])

        provider.stop()
        system.simulateSelection(id: "english")
        NotificationCenter.default.post(
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
        XCTAssertEqual(provider.currentSourceID, "japanese")
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
        XCTAssertEqual(permissions.accessibilityRequestCount, 0)
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

        permissions.isAccessibilityGranted = true
        permissions.isEventPostingGranted = true
        controller.refreshAuthorization()

        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(backgroundActivity.isActive)

        controller.refreshAuthorization()
        XCTAssertEqual(backgroundActivity.beginCount, 1)
    }

    func testControllerDoesNotRequireSeparateInputMonitoringPermission() {
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
        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 1)
    }

    func testControllerStopsImmediatelyWhenDisabledOrStopped() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true,
            isEventPostingGranted: true
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

    func testControllerRecoversAnInvalidatedMonitorWhileBackgrounded() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true,
            isEventPostingGranted: true
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
        await controller.recoverMonitoringIfNeeded()

        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.recoverRequests, [false])
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(backgroundActivity.isActive)
    }

    func testControllerRecreatesMonitorAfterWorkspaceWake() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true,
            isEventPostingGranted: true
        )
        let notificationCenter = NotificationCenter()
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            workspaceNotificationCenter: notificationCenter
        )

        controller.isEnabled = true
        controller.start()
        notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        for _ in 0 ..< 20 where monitor.recoverRequests.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(monitor.recoverRequests, [true])
        XCTAssertEqual(controller.runtimeStatus, .active)
    }

    func testControllerTracksCurrentInputSourceChangesIndependentlyOfLastSwitch() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true,
            isEventPostingGranted: true
        )
        let sourceStatus = TestCommandInputSourceStatusProvider(
            currentSourceID: "english"
        )
        let controller = CommandInputModeController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            inputSourceStatusProvider: sourceStatus
        )

        controller.isEnabled = true
        controller.start()
        controller.testSwitch(.switchToJapanese)
        sourceStatus.simulateChange(to: "japanese")
        sourceStatus.simulateChange(to: "english")

        XCTAssertEqual(controller.currentInputSourceID, "english")
        XCTAssertEqual(
            controller.lastSwitchReport?.result,
            .switched(sourceID: "japanese")
        )
    }

    func testAuthorizationRefreshWhileInactiveKeepsMonitorAndActivityRunning() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true,
            isEventPostingGranted: true
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
            isAccessibilityGranted: true,
            isEventPostingGranted: true
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
        controller.requestAccessibilityAccess()

        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        XCTAssertTrue(controller.isEnabled)
    }

    func testControllerPublishesMonitorAndSwitchingDiagnostics() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true,
            isEventPostingGranted: true
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

    func testHealthCheckStopsRevokedAccessWithoutForegroundRefresh() async {
        for invalidateMonitor in [false, true] {
            let monitor = TestCommandInputModeMonitor()
            let permissions = TestCommandInputModePermissionProvider(
                isAccessibilityGranted: true, isEventPostingGranted: true
            )
            let activity = TestCommandInputModeBackgroundActivityManager()
            let controller = CommandInputModeController(
                defaults: UserDefaults(suiteName: UUID().uuidString)!,
                monitor: monitor, permissionProvider: permissions,
                backgroundActivityManager: activity
            )
            controller.isEnabled = true
            controller.start()
            defer { controller.stop() }

            permissions.isAccessibilityGranted = false
            permissions.isEventPostingGranted = false
            if invalidateMonitor { monitor.simulateInvalidation() }
            await controller.recoverMonitoringIfNeeded()

            XCTAssertFalse(controller.isAccessibilityGranted)
            XCTAssertFalse(monitor.isRunning)
            XCTAssertFalse(activity.isActive)
            XCTAssertTrue(monitor.recoverRequests.isEmpty)
            XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        }
    }

    func testSystemSettingsActivationPausesBeforeRevocationAndRequiresFreshAccessToResume() async {
        let workspace = NotificationCenter()
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true, isEventPostingGranted: true
        )
        let activity = TestCommandInputModeBackgroundActivityManager()
        let controller = CommandInputModeController(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            monitor: monitor, permissionProvider: permissions,
            backgroundActivityManager: activity, workspaceNotificationCenter: workspace
        )
        controller.isEnabled = true
        controller.start()
        defer { controller.stop() }

        permissions.isSystemSettingsActive = true
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Suspension must happen in the notification, before another main-loop turn.
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(activity.isActive)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.runtimeStatus, .pausedForSystemSettings)
        for recreate in [false, true] {
            await controller.recoverMonitoringIfNeeded(recreate: recreate)
        }
        controller.testSwitch(.switchToJapanese)
        XCTAssertTrue(monitor.recoverRequests.isEmpty)
        XCTAssertEqual(monitor.testSwitchCount, 0)

        permissions.isAccessibilityGranted = false
        permissions.isEventPostingGranted = false
        permissions.isSystemSettingsActive = false
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await controller.recoverMonitoringIfNeeded()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)

        permissions.isAccessibilityGranted = true
        permissions.isEventPostingGranted = true
        await controller.recoverMonitoringIfNeeded()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(controller.runtimeStatus, .active)
    }

    func testStartupAndEnableDoNotInstallMonitorWhileSystemSettingsIsActive() {
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true, isEventPostingGranted: true
        )
        permissions.isSystemSettingsActive = true
        let controller = CommandInputModeController(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            monitor: monitor, permissionProvider: permissions
        )
        controller.start()
        controller.isEnabled = true
        defer { controller.stop() }
        XCTAssertEqual(monitor.startCount, 0)
        XCTAssertEqual(controller.runtimeStatus, .pausedForSystemSettings)
    }

    func testRecoveryCannotReactivateAfterPermissionOrSystemSettingsChangesDuringAwait() async {
        for opensSettings in [false, true] {
            let monitor = TestCommandInputModeMonitor()
            let permissions = TestCommandInputModePermissionProvider(
                isAccessibilityGranted: true, isEventPostingGranted: true
            )
            let controller = CommandInputModeController(
                defaults: UserDefaults(suiteName: UUID().uuidString)!,
                monitor: monitor, permissionProvider: permissions
            )
            controller.isEnabled = true
            controller.start()
            defer { controller.stop() }
            monitor.simulateInvalidation()
            monitor.duringRecovery = {
                await Task.yield()
                if opensSettings {
                    permissions.isSystemSettingsActive = true
                } else {
                    permissions.isEventPostingGranted = false
                }
            }
            await controller.recoverMonitoringIfNeeded()
            XCTAssertFalse(monitor.isRunning)
            XCTAssertEqual(controller.runtimeStatus, opensSettings ? .pausedForSystemSettings : .permissionRequired)
        }
    }

    func testHealthCheckDetectsRegrantWithoutForegroundingApplication() async {
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider()
        let controller = CommandInputModeController(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            monitor: monitor, permissionProvider: permissions,
            monitoringHealthInterval: .milliseconds(20)
        )
        controller.isEnabled = true
        controller.start()
        defer { controller.stop() }
        XCTAssertFalse(monitor.isRunning)

        let recovered = expectation(description: "Periodic check observes permission re-grant")
        monitor.duringRecovery = { recovered.fulfill() }
        permissions.isAccessibilityGranted = true
        permissions.isEventPostingGranted = true
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .active)
    }

    func testTapDisabledNotificationsStopWorkerAndCancelSubsequentSwitches() async throws {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let switcher = RecordingCommandInputSourceSwitcher()
            let worker = CommandInputModeEventTapWorker(
                inputSourceSwitcher: switcher, diagnosticsHandler: { _ in }
            )
            let event = try XCTUnwrap(CGEvent(source: nil))
            worker.handle(type: type, event: event)
            worker.switchForTesting(.switchToJapanese)
            await Task.yield()
            XCTAssertFalse(worker.isRunning)
            XCTAssertEqual(worker.diagnostics.status, .stopped)
            let switches = await switcher.switchCount
            XCTAssertEqual(switches, 0)
        }
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
    private var callsWereOnMainThread = true

    init(
        currentSourceID: String?,
        candidates: [CommandInputSourceCandidate],
        preferred: [CommandInputModeAction: String] = [:]
    ) {
        currentID = currentSourceID
        availableCandidates = candidates
        self.preferred = preferred
    }

    var allCallsWereOnMainThread: Bool {
        lock.withLock { callsWereOnMainThread }
    }

    func currentSourceID() -> String? {
        recordSystemCall()
        return lock.withLock { currentID }
    }

    func candidates() -> [CommandInputSourceCandidate] {
        recordSystemCall()
        return availableCandidates
    }

    func preferredSourceID(for action: CommandInputModeAction) -> String? {
        recordSystemCall()
        return preferred[action]
    }

    func simulateSelection(id: String) {
        recordSystemCall()
        lock.withLock {
            currentID = id
        }
    }

    private func recordSystemCall() {
        guard !Thread.isMainThread else { return }
        lock.withLock {
            callsWereOnMainThread = false
        }
    }
}

@MainActor
private final class TestCommandInputModeEventPoster:
    CommandInputModeEventPosting {
    private(set) var postedActions: [CommandInputModeAction] = []
    private(set) var allCallsWereOnMainThread = true
    private let postSucceeds: Bool
    private let onPost: (CommandInputModeAction) -> Void

    init(
        postSucceeds: Bool = true,
        onPost: @escaping (CommandInputModeAction) -> Void = { _ in }
    ) {
        self.postSucceeds = postSucceeds
        self.onPost = onPost
    }

    func post(_ action: CommandInputModeAction) -> Bool {
        if !Thread.isMainThread {
            allCallsWereOnMainThread = false
        }
        postedActions.append(action)
        guard postSucceeds else { return false }
        onPost(action)
        return true
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
    private(set) var recoverRequests: [Bool] = []
    private let startResult: Bool
    var duringRecovery: (() async -> Void)?

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

    func recover(recreate: Bool) async -> Bool {
        recoverRequests.append(recreate)
        await duringRecovery?()
        isRunning = startResult
        status = startResult ? .running : .creationFailed
        diagnosticsDidChange?()
        return startResult
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
private final class TestCommandInputSourceStatusProvider:
    CommandInputSourceStatusProviding {
    private(set) var currentSourceID: String?
    var currentSourceDidChange: (() -> Void)?

    init(currentSourceID: String?) {
        self.currentSourceID = currentSourceID
    }

    func start() {
        currentSourceDidChange?()
    }

    func stop() {}
    func refresh() {}

    func simulateChange(to sourceID: String?) {
        currentSourceID = sourceID
        currentSourceDidChange?()
    }
}

@MainActor
private final class TestCommandInputModePermissionProvider: CommandInputModePermissionProviding {
    var isSystemSettingsActive = false
    var isAccessibilityGranted: Bool
    var isInputMonitoringGranted: Bool
    var isEventPostingGranted: Bool
    private(set) var accessibilityRequestCount = 0
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

    func requestAccessibilityAccess() {
        accessibilityRequestCount += 1
    }
    func openAccessibilitySettings() {}
    func openInputMonitoringSettings() {}
    func revealCurrentBuild() {}
}

private actor RecordingCommandInputSourceSwitcher: CommandInputSourceSwitching {
    private(set) var switchCount = 0

    func switchInputMode(_ action: CommandInputModeAction) async -> CommandInputModeSwitchReport {
        switchCount += 1
        return CommandInputModeSwitchReport(
            action: action, result: .cancelled, sourceIDBefore: nil,
            sourceIDAfter: nil, completedAt: Date()
        )
    }
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
