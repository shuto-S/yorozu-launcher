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

    func testGestureConsumesCapturedDragUntilMouseUp() throws {
        let configuration = WindowControlConfiguration(
            moveChord: [.control],
            resizeChord: [.control, .option]
        )
        let target = testTarget()
        var session = WindowControlGestureSession()

        session.begin(
            operation: .move,
            target: target,
            pointer: CGPoint(x: 20, y: 30)
        )
        XCTAssertTrue(session.isCaptured)

        let update = try XCTUnwrap(
            session.drag(
                configuration: configuration,
                flags: .maskControl,
                pointer: CGPoint(x: 35, y: 55)
            )
        )
        guard case let .move(_, position) = update else {
            return XCTFail("Expected a move update")
        }
        XCTAssertEqual(position, CGPoint(x: 115, y: 125))

        session.flagsChanged(configuration: configuration, flags: [])
        let canceledUpdate = try XCTUnwrap(
            session.drag(
                configuration: configuration,
                flags: [],
                pointer: CGPoint(x: 40, y: 60)
            )
        )
        guard case .consumeWithoutUpdate = canceledUpdate else {
            return XCTFail("Expected the canceled gesture to stay consumed")
        }
        XCTAssertTrue(session.end())
        XCTAssertFalse(session.isCaptured)
        XCTAssertFalse(session.end())
    }

    func testResizeGestureKeepsOriginAndUsesBottomRightDelta() throws {
        let configuration = WindowControlConfiguration(
            moveChord: [.control],
            resizeChord: [.control, .option]
        )
        var session = WindowControlGestureSession()
        session.begin(
            operation: .resize,
            target: testTarget(),
            pointer: CGPoint(x: 30, y: 40)
        )

        let update = try XCTUnwrap(
            session.drag(
                configuration: configuration,
                flags: [.maskControl, .maskAlternate],
                pointer: CGPoint(x: 80, y: 100)
            )
        )
        guard case let .resize(target, size) = update else {
            return XCTFail("Expected a resize update")
        }
        XCTAssertEqual(target.initialPosition, CGPoint(x: 100, y: 100))
        XCTAssertEqual(size, CGSize(width: 450, height: 360))
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
