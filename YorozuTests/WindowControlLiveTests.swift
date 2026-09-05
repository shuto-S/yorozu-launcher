import AppKit
import ApplicationServices
import Darwin
import XCTest
@testable import Yorozu

@MainActor
final class WindowControlLiveTests: XCTestCase {
    // These tests use real cross-process AX without injecting pointer events.
    // They do not unlock the Mac; a locked session may block AX reads.
    func testMoveResizeAndSnapWriteToIndependentFixture() async throws {
        try await withFixture { fixture in
            try await verifyWrites(to: fixture)
        }
    }

    func testTargetsVisibleFixtureThroughContentAndTitleBar() async throws {
        try await withFixture { fixture in
            let application = AXUIElementCreateApplication(fixture.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            guard let window = try await waitForWindow(in: application, fixture: fixture),
                  let original = frame(of: window) else {
                throw XCTSkip("The GUI session did not expose the fixture window.")
            }
            // Only hide this isolated host's palette; it floats above the fixture
            // and would otherwise legitimately block the content hit-test points.
            NSApp.windows.forEach { $0.orderOut(nil) }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            // Bring only our fixture forward so desktop widgets and the user's
            // normal windows do not make the opt-in hit test nondeterministic.
            _ = NSRunningApplication(processIdentifier: fixture.processIdentifier)?.activate()
            let accessor = SystemWindowAccessor()
            let points = [
                CGPoint(x: original.midX, y: original.minY + 12),
                CGPoint(x: original.minX + 80, y: original.maxY - 50),
                CGPoint(x: original.midX, y: original.midY),
            ]
            let visibilityDeadline = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < visibilityDeadline,
                  points.contains(where: { topmostOwner(at: $0) != fixture.processIdentifier }) {
                try await Task.sleep(for: .milliseconds(25))
            }
            for (index, point) in points.enumerated() {
                guard topmostOwner(at: point) == fixture.processIdentifier else {
                    throw XCTSkip("Another window covers fixture point \(index); no external window will be changed.")
                }
                for operation in [WindowControlOperation.move, .resize] {
                    let target = try XCTUnwrap(
                        accessor.target(at: point, operation: operation),
                        "Visible fixture point \(index) must support \(operation)."
                    )
                    XCTAssertEqual(target.processIdentifier, fixture.processIdentifier)
                    XCTAssertTrue(target.supportsResizing)
                    XCTAssertTrue(matches(
                        CGRect(origin: target.initialPosition, size: target.initialSize), original
                    ))
                }
            }
        }
    }

    func testPointerCoordinatorMovesResizesAndCommitsSnapOnMouseUp() async throws {
        try await withFixture { fixture in
            let application = AXUIElementCreateApplication(fixture.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            guard let window = try await waitForWindow(in: application, fixture: fixture),
                  let original = frame(of: window) else {
                throw XCTSkip("The GUI session did not expose the fixture window.")
            }
            AXUIElementSetMessagingTimeout(window, 0.15)
            NSApp.windows.forEach { $0.orderOut(nil) }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = NSRunningApplication(processIdentifier: fixture.processIdentifier)?.activate()

            // Keep all geometry close to the fixture instead of moving windows
            // to the user's actual display edges. Target lookup remains real AX.
            let snapBounds = original.insetBy(dx: 10, dy: 10)
            let screen = WindowControlScreen(frame: snapBounds, visibleFrame: snapBounds)
            let coordinator = WindowControlPointerCoordinator(
                windowAccessor: LiveFixtureWindowAccessor(processIdentifier: fixture.processIdentifier),
                screenProvider: LiveFixtureScreenProvider(screen: screen)
            )
            defer { coordinator.reset() }

            let moveStart = CGPoint(x: original.midX, y: original.midY)
            try await requireVisibleFixture(fixture, at: moveStart)
            XCTAssertEqual(coordinator.process(.init(operation: .move, location: moveStart)), .tracking(.move))
            let moveEnd = CGPoint(x: moveStart.x + 24, y: moveStart.y + 18)
            XCTAssertEqual(coordinator.process(.init(operation: .move, location: moveEnd)), .tracking(.move))
            let moved = original.offsetBy(dx: 24, dy: 18)
            try await assertFrame(of: window, equals: moved)
            XCTAssertEqual(coordinator.finish(commitSnap: false), .listening)

            let resizeStart = CGPoint(x: moved.midX, y: moved.midY)
            try await requireVisibleFixture(fixture, at: resizeStart)
            XCTAssertEqual(coordinator.process(.init(operation: .resize, location: resizeStart)), .tracking(.resize))
            let resizeEnd = CGPoint(x: resizeStart.x - 40, y: resizeStart.y - 30)
            XCTAssertEqual(coordinator.process(.init(operation: .resize, location: resizeEnd)), .tracking(.resize))
            let resized = CGRect(
                origin: moved.origin,
                size: CGSize(width: original.width - 40, height: original.height - 30)
            )
            try await assertFrame(of: window, equals: resized)
            XCTAssertEqual(coordinator.finish(commitSnap: false), .listening)

            let snapStart = CGPoint(x: resized.minX + 40, y: resized.midY)
            try await requireVisibleFixture(fixture, at: snapStart)
            XCTAssertEqual(coordinator.process(.init(operation: .move, location: snapStart)), .tracking(.move))
            let edge = CGPoint(x: snapBounds.minX + 2, y: snapBounds.midY)
            XCTAssertEqual(coordinator.process(.init(operation: .move, location: edge)), .tracking(.move))
            let previewFrame = resized.offsetBy(dx: edge.x - snapStart.x, dy: edge.y - snapStart.y)
            try await assertFrame(of: window, equals: previewFrame)
            let destination = try XCTUnwrap(WindowControlSnapGeometry.destination(at: edge, on: screen))
            XCTAssertEqual(destination.zone, .leftHalf)
            XCTAssertFalse(matches(try XCTUnwrap(frame(of: window)), destination.frame))

            // finish is the production coordinator entry point used by mouse-up.
            // Before it, the real fixture retained its pre-snap size.
            XCTAssertEqual(coordinator.finish(commitSnap: true), .listening)
            try await assertFrame(of: window, equals: destination.frame)
        }
    }

    private func requireVisibleFixture(_ fixture: Process, at point: CGPoint) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline, fixture.isRunning,
              topmostOwner(at: point) != fixture.processIdentifier {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard fixture.isRunning, topmostOwner(at: point) == fixture.processIdentifier else {
            throw XCTSkip("Another window covers the fixture; no external window will be changed.")
        }
    }


    private func withFixture(_ verify: (Process) async throws -> Void) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["YOROZU_LIVE_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("Live AX verification is opt-in.")
        }
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else {
            XCTFail("Live AX verification requires the isolated --ui-testing host.")
            return
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("This test host does not have existing Accessibility permission.")
        }
        guard let executablePath = environment["YOROZU_WINDOW_FIXTURE_EXECUTABLE"],
              URL(fileURLWithPath: executablePath).lastPathComponent == "WindowControlFixture",
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            XCTFail("Provide the separately built WindowControlFixture executable.")
            return
        }

        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: executablePath)
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        do {
            try fixture.run()
        } catch {
            XCTFail("The isolated fixture process could not start.")
            return
        }

        do {
            try await verify(fixture)
        } catch {
            await stop(fixture)
            throw error
        }
        await stop(fixture)
    }

    private func topmostOwner(at point: CGPoint) -> pid_t? {
        guard let records = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for record in records {
            guard let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point),
                  (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else { continue }
            return (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        return nil
    }

    private func verifyWrites(to fixture: Process) async throws {
        let application = AXUIElementCreateApplication(fixture.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let window = try await waitForWindow(in: application, fixture: fixture) else {
            throw XCTSkip("The GUI session did not expose readable fixture window geometry (for example, while locked). No AX writes were attempted.")
        }
        AXUIElementSetMessagingTimeout(window, 0.15)
        var owner: pid_t = 0
        XCTAssertEqual(AXUIElementGetPid(window, &owner), .success)
        guard owner == fixture.processIdentifier, fixture.isRunning else {
            XCTFail("The AX target must belong to this test's fixture process.")
            return
        }

        let original = try XCTUnwrap(frame(of: window), "The fixture frame must be readable.")
        let target = WindowControlTarget(
            element: window,
            processIdentifier: owner,
            initialPosition: original.origin,
            initialSize: original.size,
            supportsResizing: true
        )
        let accessor = SystemWindowAccessor()

        let moved = original.offsetBy(dx: 24, dy: 18)
        XCTAssertTrue(accessor.move(target, to: moved.origin))
        try await assertFrame(of: window, equals: moved)

        let resized = CGRect(
            origin: moved.origin,
            size: CGSize(width: original.width - 40, height: original.height - 30)
        )
        XCTAssertTrue(accessor.resize(target, to: resized.size))
        try await assertFrame(of: window, equals: resized)

        // Exercise the same resize/move/resize implementation that applies snap
        // bounds, using a small fixture-only frame to avoid display-edge policy.
        let snapped = CGRect(
            x: original.minX + 10,
            y: original.minY + 10,
            width: original.width - 20,
            height: original.height - 20
        )
        XCTAssertTrue(accessor.setFrame(target, to: snapped))
        try await assertFrame(of: window, equals: snapped)
    }

    private func waitForWindow(
        in application: AXUIElement,
        fixture: Process
    ) async throws -> AXUIElement? {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, fixture.isRunning {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application, kAXWindowsAttribute as CFString, &value
            ) == .success, let windows = value as? [AXUIElement], windows.count == 1,
               frame(of: windows[0]) != nil {
                return windows[0]
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func assertFrame(
        of window: AXUIElement,
        equals expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if let actual = frame(of: window), matches(actual, expected) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The fixture did not adopt the requested AX frame.", file: file, line: line)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeValue
        ) == .success,
        let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
        let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func matches(_ actual: CGRect, _ expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) <= 1
            && abs(actual.minY - expected.minY) <= 1
            && abs(actual.width - expected.width) <= 1
            && abs(actual.height - expected.height) <= 1
    }

    private func stop(_ fixture: Process) async {
        guard fixture.isRunning else { return }
        fixture.terminate()
        for _ in 0..<40 {
            if !fixture.isRunning { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Only this child process is eligible for forced cleanup.
        if fixture.isRunning { _ = kill(fixture.processIdentifier, SIGKILL) }
        for _ in 0..<20 {
            if !fixture.isRunning { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(fixture.isRunning, "The isolated fixture must stop after verification.")
    }
}

// A user can cover the fixture between the visibility check and AX hit testing.
// Never allow that race to turn this opt-in test into a write to a user's window.
private final class LiveFixtureWindowAccessor: WindowAccessing, @unchecked Sendable {
    private let system = SystemWindowAccessor()
    private let processIdentifier: pid_t

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    func target(at point: CGPoint, operation: WindowControlOperation) -> WindowControlTarget? {
        guard let target = system.target(at: point, operation: operation),
              target.processIdentifier == processIdentifier else { return nil }
        return target
    }

    func raiseAndActivate(_ target: WindowControlTarget) {
        guard target.processIdentifier == processIdentifier else { return }
        system.raiseAndActivate(target)
    }

    func raiseAndActivate(_ target: WindowControlTarget, isCancelled: @escaping @Sendable () -> Bool) {
        guard target.processIdentifier == processIdentifier else { return }
        system.raiseAndActivate(target, isCancelled: isCancelled)
    }

    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool {
        target.processIdentifier == processIdentifier && system.move(target, to: position)
    }

    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool {
        target.processIdentifier == processIdentifier && system.resize(target, to: size)
    }

    func setFrame(_ target: WindowControlTarget, to frame: CGRect) -> Bool {
        target.processIdentifier == processIdentifier && system.setFrame(target, to: frame)
    }

    func setFrame(_ target: WindowControlTarget, to frame: CGRect, isCancelled: @escaping @Sendable () -> Bool) -> Bool {
        target.processIdentifier == processIdentifier
            && system.setFrame(target, to: frame, isCancelled: isCancelled)
    }
}

private final class LiveFixtureScreenProvider: WindowControlScreenProviding, Sendable {
    let screen: WindowControlScreen

    init(screen: WindowControlScreen) { self.screen = screen }

    func screen(containing point: CGPoint) -> WindowControlScreen? {
        screen.frame.contains(point) ? screen : nil
    }
}
