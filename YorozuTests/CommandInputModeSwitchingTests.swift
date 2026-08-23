import CoreGraphics
import XCTest
@testable import Yorozu

@MainActor
final class CommandInputModeSwitchingTests: XCTestCase {
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
        controller.refreshAuthorization()

        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(backgroundActivity.isActive)

        controller.refreshAuthorization()
        XCTAssertEqual(backgroundActivity.beginCount, 1)
    }

    func testControllerStopsImmediatelyWhenDisabledOrStopped() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true
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
            isAccessibilityGranted: true
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

    func testControllerReportsUnavailableWhenAuthorizedMonitorCannotStart() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor(startResult: false)
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true
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

    func testControllerPublishesMonitorAndPostingDiagnostics() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestCommandInputModeMonitor()
        let permissions = TestCommandInputModePermissionProvider(
            isAccessibilityGranted: true
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
        XCTAssertEqual(controller.lastPostCreatedEvents, true)
        XCTAssertEqual(monitor.testPostCount, 1)

        controller.isEnabled = false
        XCTAssertEqual(controller.monitorStatus, .stopped)
    }
}

@MainActor
private final class TestCommandInputModeMonitor: CommandInputModeMonitoring {
    private(set) var isRunning = false
    private(set) var status: CommandInputModeMonitorStatus = .stopped
    var lastCommandEventAt: Date?
    private(set) var lastAction: CommandInputModeAction?
    private(set) var lastActionAt: Date?
    private(set) var lastPostCreatedEvents: Bool?
    var diagnosticsDidChange: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var testPostCount = 0
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

    func postForTesting(_ action: CommandInputModeAction) -> Bool {
        testPostCount += 1
        lastAction = action
        lastActionAt = Date()
        lastPostCreatedEvents = true
        diagnosticsDidChange?()
        return true
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
    private(set) var accessibilityRequestCount = 0

    init(
        isAccessibilityGranted: Bool = false
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
    }

    func requestAccessibilityAccess() {
        accessibilityRequestCount += 1
    }

    func openAccessibilitySettings() {}
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
