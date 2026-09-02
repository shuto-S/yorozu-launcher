import CoreGraphics
import XCTest
@testable import Yorozu

@MainActor
final class WindowControlTests: XCTestCase {
    func testModifierChordNormalizesSupportedFlagsAndRequiresExactMatch() {
        let configuration = WindowControlConfiguration(
            moveChord: [.control],
            resizeChord: [.control, .option]
        )

        XCTAssertEqual(
            configuration.operation(for: .maskControl),
            .move
        )
        XCTAssertEqual(
            configuration.operation(
                for: [.maskControl, .maskAlternate]
            ),
            .resize
        )
        XCTAssertNil(
            configuration.operation(
                for: [.maskControl, .maskShift]
            )
        )
        XCTAssertEqual(
            WindowControlModifierChord(
                eventFlags: [.maskControl, .maskAlphaShift]
            ),
            [.control]
        )
    }

    func testConfigurationRejectsMissingAndDuplicateChords() {
        XCTAssertFalse(
            WindowControlConfiguration(
                moveChord: nil,
                resizeChord: [.option]
            ).isValid
        )
        XCTAssertFalse(
            WindowControlConfiguration(
                moveChord: [.option],
                resizeChord: [.option]
            ).isValid
        )
        XCTAssertTrue(
            WindowControlConfiguration(
                moveChord: [.control],
                resizeChord: [.control, .option]
            ).isValid
        )
    }

    func testMoveAndBottomRightResizeGeometry() {
        XCTAssertEqual(
            WindowControlGeometry.movedPosition(
                initialPosition: CGPoint(x: 100, y: 80),
                startPointer: CGPoint(x: 200, y: 220),
                currentPointer: CGPoint(x: 240, y: 190)
            ),
            CGPoint(x: 140, y: 50)
        )

        XCTAssertEqual(
            WindowControlGeometry.resizedSize(
                initialSize: CGSize(width: 500, height: 300),
                startPointer: CGPoint(x: 200, y: 220),
                currentPointer: CGPoint(x: 260, y: 250)
            ),
            CGSize(width: 560, height: 330)
        )
        XCTAssertEqual(
            WindowControlGeometry.resizedSize(
                initialSize: CGSize(width: 200, height: 150),
                startPointer: CGPoint(x: 200, y: 220),
                currentPointer: CGPoint(x: -500, y: -500)
            ),
            WindowControlGeometry.minimumSize
        )
    }

    func testSnapGeometryUsesVisibleFrameAndDoesNotSnapAtBottom() throws {
        let screen = WindowControlScreen(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 835)
        )

        XCTAssertEqual(
            try XCTUnwrap(
                WindowControlSnapGeometry.destination(
                    at: CGPoint(x: 720, y: 5),
                    on: screen
                )
            ),
            WindowControlSnapDestination(
                zone: .maximize,
                frame: screen.visibleFrame
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                WindowControlSnapGeometry.destination(
                    at: CGPoint(x: 5, y: 450),
                    on: screen
                )
            ),
            WindowControlSnapDestination(
                zone: .leftHalf,
                frame: CGRect(x: 0, y: 25, width: 720, height: 835)
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                WindowControlSnapGeometry.destination(
                    at: CGPoint(x: 1435, y: 450),
                    on: screen
                )
            ),
            WindowControlSnapDestination(
                zone: .rightHalf,
                frame: CGRect(x: 720, y: 25, width: 720, height: 835)
            )
        )
        XCTAssertNil(
            WindowControlSnapGeometry.destination(
                at: CGPoint(x: 720, y: 895),
                on: screen
            )
        )
        XCTAssertEqual(
            WindowControlSnapGeometry.destination(
                at: CGPoint(x: 5, y: 5),
                on: screen
            )?.zone,
            .maximize
        )
    }

    func testScreenFrameConversionSupportsDisplaysAboveAndBelowPrimary() {
        XCTAssertEqual(
            WindowControlSnapGeometry.accessibilityFrame(
                from: CGRect(x: 0, y: 900, width: 1440, height: 900),
                primaryScreenMaxY: 900
            ),
            CGRect(x: 0, y: -900, width: 1440, height: 900)
        )
        XCTAssertEqual(
            WindowControlSnapGeometry.accessibilityFrame(
                from: CGRect(x: 0, y: -768, width: 1024, height: 768),
                primaryScreenMaxY: 900
            ),
            CGRect(x: 0, y: 900, width: 1024, height: 768)
        )
    }

    func testGestureTracksPointerUntilReset() throws {
        let target = testTarget()
        var session = WindowControlGestureSession()

        session.begin(
            operation: .move,
            target: target,
            pointer: CGPoint(x: 20, y: 30)
        )
        XCTAssertTrue(session.isTracking)

        let update = try XCTUnwrap(
            session.update(
                operation: .move,
                pointer: CGPoint(x: 35, y: 55)
            )
        )
        guard case let .move(_, position) = update else {
            return XCTFail("Expected a move update")
        }
        XCTAssertEqual(position, CGPoint(x: 115, y: 125))

        XCTAssertNil(
            session.update(
                operation: .resize,
                pointer: CGPoint(x: 40, y: 60)
            )
        )
        session.reset()
        XCTAssertFalse(session.isTracking)
    }

    func testResizeGestureKeepsOriginAndUsesBottomRightDelta() throws {
        var session = WindowControlGestureSession()
        session.begin(
            operation: .resize,
            target: testTarget(),
            pointer: CGPoint(x: 30, y: 40)
        )

        let update = try XCTUnwrap(
            session.update(
                operation: .resize,
                pointer: CGPoint(x: 80, y: 100)
            )
        )
        guard case let .resize(target, size) = update else {
            return XCTFail("Expected a resize update")
        }
        XCTAssertEqual(target.initialPosition, CGPoint(x: 100, y: 100))
        XCTAssertEqual(size, CGSize(width: 450, height: 360))
    }

    func testPointerCoordinatorAcquiresAndMovesWindowWithoutMouseClick() {
        let accessor = TestWindowAccessor(target: testTarget())
        let coordinator = WindowControlPointerCoordinator(
            windowAccessor: accessor
        )

        XCTAssertEqual(
            coordinator.process(
                WindowControlPointerSample(
                    operation: .move,
                    location: CGPoint(x: 20, y: 30)
                )
            ),
            .tracking(.move)
        )
        XCTAssertEqual(accessor.targetCount, 1)
        XCTAssertEqual(accessor.raiseCount, 1)
        XCTAssertTrue(accessor.movedPositions.isEmpty)

        XCTAssertEqual(
            coordinator.process(
                WindowControlPointerSample(
                    operation: .move,
                    location: CGPoint(x: 50, y: 70)
                )
            ),
            .tracking(.move)
        )
        XCTAssertEqual(
            accessor.movedPositions,
            [CGPoint(x: 130, y: 140)]
        )
    }

    func testPointerCoordinatorSnapsOnceAndRestoresFreeMoveSize() {
        let accessor = TestWindowAccessor(target: testTarget())
        let screen = WindowControlScreen(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 776)
        )
        let coordinator = WindowControlPointerCoordinator(
            windowAccessor: accessor,
            screenProvider: TestWindowControlScreenProvider(screen: screen)
        )

        _ = coordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: CGPoint(x: 300, y: 300)
            )
        )
        _ = coordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: CGPoint(x: 5, y: 300)
            )
        )
        _ = coordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: CGPoint(x: 3, y: 320)
            )
        )

        XCTAssertEqual(
            accessor.setFrames,
            [CGRect(x: 0, y: 24, width: 500, height: 776)]
        )

        _ = coordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: CGPoint(x: 100, y: 320)
            )
        )
        XCTAssertEqual(
            accessor.setFrames,
            [
                CGRect(x: 0, y: 24, width: 500, height: 776),
                CGRect(x: -100, y: 120, width: 400, height: 300),
            ]
        )
    }

    func testResizeAndNonResizableMoveDoNotUseSnapFrames() {
        let screen = WindowControlScreen(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 776)
        )
        let screenProvider = TestWindowControlScreenProvider(screen: screen)

        let resizeAccessor = TestWindowAccessor(target: testTarget())
        let resizeCoordinator = WindowControlPointerCoordinator(
            windowAccessor: resizeAccessor,
            screenProvider: screenProvider
        )
        _ = resizeCoordinator.process(
            WindowControlPointerSample(
                operation: .resize,
                location: CGPoint(x: 100, y: 100)
            )
        )
        _ = resizeCoordinator.process(
            WindowControlPointerSample(
                operation: .resize,
                location: CGPoint(x: 5, y: 120)
            )
        )
        XCTAssertTrue(resizeAccessor.setFrames.isEmpty)
        XCTAssertEqual(
            resizeAccessor.resizedSizes,
            [CGSize(width: 305, height: 320)]
        )

        let fixedTarget = WindowControlTarget(
            element: NSObject(),
            processIdentifier: 123,
            initialPosition: CGPoint(x: 100, y: 100),
            initialSize: CGSize(width: 400, height: 300),
            supportsResizing: false
        )
        let moveAccessor = TestWindowAccessor(target: fixedTarget)
        let moveCoordinator = WindowControlPointerCoordinator(
            windowAccessor: moveAccessor,
            screenProvider: screenProvider
        )
        _ = moveCoordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: CGPoint(x: 100, y: 100)
            )
        )
        _ = moveCoordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: CGPoint(x: 5, y: 100)
            )
        )
        XCTAssertTrue(moveAccessor.setFrames.isEmpty)
        XCTAssertEqual(
            moveAccessor.movedPositions,
            [CGPoint(x: 5, y: 100)]
        )
    }

    func testPointerCoordinatorReacquiresWhenOperationChanges() {
        let accessor = TestWindowAccessor(target: testTarget())
        let coordinator = WindowControlPointerCoordinator(
            windowAccessor: accessor
        )

        _ = coordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: CGPoint(x: 20, y: 30)
            )
        )
        XCTAssertEqual(
            coordinator.process(
                WindowControlPointerSample(
                    operation: .resize,
                    location: CGPoint(x: 30, y: 40)
                )
            ),
            .tracking(.resize)
        )
        XCTAssertEqual(accessor.targetCount, 2)
        XCTAssertEqual(accessor.raiseCount, 2)

        _ = coordinator.process(
            WindowControlPointerSample(
                operation: .resize,
                location: CGPoint(x: 80, y: 90)
            )
        )
        XCTAssertEqual(
            accessor.resizedSizes,
            [CGSize(width: 450, height: 350)]
        )
    }

    func testPointerCoordinatorReportsTargetAndUpdateFailures() {
        let missingTarget = TestWindowAccessor(target: nil)
        let missingCoordinator = WindowControlPointerCoordinator(
            windowAccessor: missingTarget
        )
        XCTAssertEqual(
            missingCoordinator.process(
                WindowControlPointerSample(
                    operation: .move,
                    location: .zero
                )
            ),
            .targetUnavailable
        )

        let rejectingAccessor = TestWindowAccessor(target: testTarget())
        rejectingAccessor.acceptsUpdates = false
        let rejectingCoordinator = WindowControlPointerCoordinator(
            windowAccessor: rejectingAccessor
        )
        _ = rejectingCoordinator.process(
            WindowControlPointerSample(
                operation: .move,
                location: .zero
            )
        )
        XCTAssertEqual(
            rejectingCoordinator.process(
                WindowControlPointerSample(
                    operation: .move,
                    location: CGPoint(x: 10, y: 10)
                )
            ),
            .updateRejected(.move)
        )
    }

    func testControllerStartsOffAndPersistsNonConflictingChords() {
        let suiteName = "window-control-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitor = TestWindowControlMonitor()
        let permissions = TestWindowControlPermissionProvider()
        let controller = WindowControlController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions
        )

        controller.start()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.moveChord)
        XCTAssertNil(controller.resizeChord)
        XCTAssertEqual(controller.runtimeStatus, .off)
        XCTAssertEqual(monitor.startCount, 0)

        XCTAssertTrue(controller.setChord([.control], for: .move))
        XCTAssertTrue(
            controller.setChord([.control, .option], for: .resize)
        )
        XCTAssertTrue(controller.isConfigurationValid)

        let restored = WindowControlController(
            defaults: defaults,
            monitor: TestWindowControlMonitor(),
            permissionProvider: permissions
        )
        XCTAssertEqual(restored.moveChord, [.control])
        XCTAssertEqual(restored.resizeChord, [.control, .option])
    }

    func testControllerRejectsDuplicateWithoutReplacingStoredValue() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = WindowControlController(
            defaults: defaults,
            monitor: TestWindowControlMonitor(),
            permissionProvider: TestWindowControlPermissionProvider()
        )

        XCTAssertTrue(controller.setChord([.control], for: .move))
        XCTAssertFalse(controller.setChord([.control], for: .resize))
        XCTAssertNil(controller.resizeChord)
        XCTAssertEqual(
            controller.validationMessage,
            "This key combination is already used by Move Window."
        )
    }

    func testControllerStartsOnlyWhenConfiguredEnabledAndAuthorized() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = TestWindowControlMonitor()
        let permissions = TestWindowControlPermissionProvider()
        let backgroundActivity = TestWindowControlBackgroundActivityManager()
        let controller = WindowControlController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            backgroundActivityManager: backgroundActivity
        )
        controller.start()
        controller.isEnabled = true
        XCTAssertEqual(controller.runtimeStatus, .needsConfiguration)

        controller.setChord([.control], for: .move)
        controller.setChord([.control, .option], for: .resize)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        XCTAssertEqual(monitor.startCount, 0)

        permissions.isAccessibilityGranted = true
        controller.refreshAuthorization()
        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertTrue(backgroundActivity.isActive)

        monitor.report(.targetUnavailable)
        XCTAssertEqual(controller.lastActivity, .targetUnavailable)

        controller.setChord([.shift, .option], for: .resize)
        XCTAssertEqual(monitor.updateCount, 1)

        controller.isEnabled = false
        XCTAssertEqual(controller.runtimeStatus, .off)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(backgroundActivity.isActive)
    }

    func testWindowControlBackgroundActivityDoesNotPreventIdleSleep() {
        let options = SystemWindowControlBackgroundActivityManager.activityOptions
        XCTAssertTrue(options.contains(.userInitiatedAllowingIdleSystemSleep))
        XCTAssertTrue(options.contains(.automaticTerminationDisabled))
        XCTAssertFalse(options.contains(.idleSystemSleepDisabled))
    }

    private func testTarget() -> WindowControlTarget {
        WindowControlTarget(
            element: NSObject(),
            processIdentifier: 123,
            initialPosition: CGPoint(x: 100, y: 100),
            initialSize: CGSize(width: 400, height: 300)
        )
    }
}

@MainActor
private final class TestWindowControlMonitor: WindowControlMonitoring {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var updateCount = 0
    private(set) var stopCount = 0
    private var activityHandler:
        (@MainActor @Sendable (WindowControlActivity) -> Void)?

    func setActivityHandler(
        _ handler: (@MainActor @Sendable (WindowControlActivity) -> Void)?
    ) {
        activityHandler = handler
    }

    func report(_ activity: WindowControlActivity) {
        activityHandler?(activity)
    }

    func start(configuration: WindowControlConfiguration) -> Bool {
        startCount += 1
        isRunning = true
        return true
    }

    func update(configuration: WindowControlConfiguration) {
        updateCount += 1
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

private final class TestWindowAccessor: WindowAccessing, @unchecked Sendable {
    var targetValue: WindowControlTarget?
    var acceptsUpdates = true
    private(set) var targetCount = 0
    private(set) var raiseCount = 0
    private(set) var movedPositions: [CGPoint] = []
    private(set) var resizedSizes: [CGSize] = []
    private(set) var setFrames: [CGRect] = []

    init(target: WindowControlTarget?) {
        targetValue = target
    }

    func target(
        at point: CGPoint,
        operation: WindowControlOperation
    ) -> WindowControlTarget? {
        targetCount += 1
        return targetValue
    }

    func raiseAndActivate(_ target: WindowControlTarget) {
        raiseCount += 1
    }

    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool {
        movedPositions.append(position)
        return acceptsUpdates
    }

    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool {
        resizedSizes.append(size)
        return acceptsUpdates
    }

    func setFrame(_ target: WindowControlTarget, to frame: CGRect) -> Bool {
        setFrames.append(frame)
        return acceptsUpdates
    }
}

private final class TestWindowControlScreenProvider:
    WindowControlScreenProviding, @unchecked Sendable {
    let screen: WindowControlScreen?

    init(screen: WindowControlScreen?) {
        self.screen = screen
    }

    func screen(containing point: CGPoint) -> WindowControlScreen? {
        guard let screen,
              point.x >= screen.frame.minX,
              point.x <= screen.frame.maxX,
              point.y >= screen.frame.minY,
              point.y <= screen.frame.maxY else {
            return nil
        }
        return screen
    }
}

@MainActor
private final class TestWindowControlPermissionProvider:
    CommandInputModePermissionProviding {
    var isAccessibilityGranted: Bool

    init(isAccessibilityGranted: Bool = false) {
        self.isAccessibilityGranted = isAccessibilityGranted
    }

    func requestAccessibilityAccess() {}
    func openAccessibilitySettings() {}
    func revealCurrentBuild() {}
}

@MainActor
private final class TestWindowControlBackgroundActivityManager:
    WindowControlBackgroundActivityManaging {
    private(set) var isActive = false

    func begin() { isActive = true }
    func end() { isActive = false }
}
