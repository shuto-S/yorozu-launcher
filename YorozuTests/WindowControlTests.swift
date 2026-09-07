import AppKit
import CoreGraphics
import XCTest
@testable import Yorozu

@MainActor
final class WindowControlTests: XCTestCase {
    func testClickFreeMoveStartsOnMotionAndFinishesOnModifierRelease() async throws {
        let accessor = TestWindowAccessor(target: testTarget())
        let finished = expectation(description: "Click-free move completed")
        let worker = WindowControlEventTapWorker(
            configuration: .init(moveChord: [.control], resizeChord: [.control, .command]),
            windowAccessor: accessor,
            screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { if $0 == .listening { finished.fulfill() } }
        )
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try pointerEvent(
            .flagsChanged, at: CGPoint(x: 200, y: 200), flags: .maskControl
        )))
        XCTAssertEqual(accessor.targetCount, 0, "Pressing a shortcut alone must not raise a window")
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try pointerEvent(
            .mouseMoved, at: CGPoint(x: 240, y: 230), flags: .maskControl
        )))
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try pointerEvent(
            .flagsChanged, at: CGPoint(x: 240, y: 230), flags: []
        )))
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(accessor.targetCount, 1)
        XCTAssertEqual(accessor.movedPositions.last, CGPoint(x: 140, y: 130))
        XCTAssertTrue(accessor.resizedSizes.isEmpty)
    }

    func testWindowControlObservesMotionAtSessionEventTap() {
        XCTAssertEqual(
            WindowControlEventTapConfiguration.location,
            .cgSessionEventTap
        )
        XCTAssertEqual(WindowControlEventTapConfiguration.placement, .tailAppendEventTap)
    }

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
        XCTAssertEqual(
            WindowControlSnapGeometry.appKitFrame(
                from: CGRect(x: 0, y: -900, width: 1440, height: 900),
                primaryScreenMaxY: 900
            ),
            CGRect(x: 0, y: 900, width: 1440, height: 900)
        )
        XCTAssertEqual(
            WindowControlSnapGeometry.appKitFrame(
                from: CGRect(x: 0, y: 900, width: 1024, height: 768),
                primaryScreenMaxY: 900
            ),
            CGRect(x: 0, y: -768, width: 1024, height: 768)
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

    func testPointerCoordinatorAcquiresAndMovesWindowFromGestureStart() {
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

    func testPointerProcessorPreservesAnchorAndFlushesResizeOnKeyRelease() async {
        let accessor = TestWindowAccessor(target: testTarget())
        let finished = expectation(description: "Resize gesture finished")
        let processor = WindowControlPointerProcessor(
            windowAccessor: accessor,
            screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { activity in
                if activity == .listening {
                    finished.fulfill()
                }
            }
        )

        processor.begin(
            WindowControlPointerSample(
                operation: .resize,
                location: CGPoint(x: 20, y: 30)
            )
        )
        processor.submit(
            WindowControlPointerSample(
                operation: .resize,
                location: CGPoint(x: 70, y: 80)
            )
        )
        processor.finish(
            applyPendingUpdate: true,
            commitSnap: false
        )

        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(accessor.targetCount, 1)
        XCTAssertEqual(
            accessor.resizedSizes,
            [CGSize(width: 450, height: 350)]
        )
    }

    func testPointerProcessorCancelDropsPendingResize() async {
        let accessor = TestWindowAccessor(target: testTarget())
        let finished = expectation(description: "Resize gesture cancelled")
        let processor = WindowControlPointerProcessor(
            windowAccessor: accessor,
            screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { activity in
                if activity == .listening {
                    finished.fulfill()
                }
            }
        )

        processor.begin(
            WindowControlPointerSample(
                operation: .resize,
                location: CGPoint(x: 20, y: 30)
            )
        )
        processor.submit(
            WindowControlPointerSample(
                operation: .resize,
                location: CGPoint(x: 70, y: 80)
            )
        )
        processor.reset()

        await fulfillment(of: [finished], timeout: 1)
        XCTAssertTrue(accessor.resizedSizes.isEmpty)
    }

    func testRapidGestureCompletionsKeepTheirOwnTargetsAndFinalSamples() async {
        let accessor = TestWindowAccessor(target: testTarget())
        let drained = expectation(description: "All gesture completions drained")
        let processor = WindowControlPointerProcessor(
            windowAccessor: accessor,
            screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { if $0 == .monitorRecovered { drained.fulfill() } }
        )
        for index in 0..<100 {
            let operation: WindowControlOperation = index.isMultiple(of: 2) ? .move : .resize
            let start = CGPoint(x: 200 + index, y: 200)
            processor.begin(.init(operation: operation, location: start))
            processor.submit(.init(operation: operation, location: CGPoint(x: start.x + 20, y: 230)))
            processor.finish(applyPendingUpdate: true, commitSnap: false)
        }
        processor.report(.monitorRecovered)
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(accessor.targetCount, 100)
        XCTAssertEqual(accessor.movedPositions.count, 50)
        XCTAssertEqual(accessor.resizedSizes.count, 50)
        XCTAssertTrue(accessor.movedPositions.allSatisfy { $0 == CGPoint(x: 120, y: 130) })
        XCTAssertTrue(accessor.resizedSizes.allSatisfy { $0 == CGSize(width: 420, height: 330) })
        XCTAssertTrue(accessor.setFrames.isEmpty)
    }

    func testResetCancelsKeyReleaseCompletionQueuedBehindAXLookup() async {
        for operation in WindowControlOperation.allCases {
            let accessor = TestWindowAccessor(target: testTarget())
            let lookupStarted = expectation(description: "AX lookup started for \(operation)")
            let resetCompleted = expectation(description: "Queued \(operation) cancelled")
            let lookupGate = DispatchSemaphore(value: 0)
            accessor.targetLookupStarted = { lookupStarted.fulfill() }
            accessor.targetLookupGate = lookupGate
            let processor = WindowControlPointerProcessor(
                windowAccessor: accessor,
                screenProvider: TestWindowControlScreenProvider(screen: WindowControlScreen(
                    frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                    visibleFrame: CGRect(x: 0, y: 25, width: 1_000, height: 750)
                )),
                previewHandler: { _ in },
                activityHandler: { activity in
                    if activity == .listening { resetCompleted.fulfill() }
                }
            )
            processor.begin(.init(operation: operation, location: CGPoint(x: 200, y: 200)))
            await fulfillment(of: [lookupStarted], timeout: 1)

            // A slow target app can still be replying when key release queues the
            // last resize/snap and the user immediately disables the feature.
            processor.submit(.init(operation: operation, location: CGPoint(x: 0, y: 300)))
            processor.finish(applyPendingUpdate: true, commitSnap: operation == .move)
            processor.reset()
            lookupGate.signal()

            await fulfillment(of: [resetCompleted], timeout: 1)
            XCTAssertEqual(accessor.targetCount, 1)
            XCTAssertTrue(accessor.movedPositions.isEmpty)
            XCTAssertTrue(accessor.resizedSizes.isEmpty)
            XCTAssertTrue(accessor.setFrames.isEmpty)
        }
    }

    func testDisabledTapCancelsPendingDragAndPassesSubsequentInputThrough() async throws {
        for disabledType in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let accessor = TestWindowAccessor(target: testTarget())
            let lookupStarted = expectation(description: "AX lookup started before tap disable")
            let cancelled = expectation(description: "Disabled tap cancelled pending drag")
            let lookupGate = DispatchSemaphore(value: 0)
            accessor.targetLookupStarted = { lookupStarted.fulfill() }
            accessor.targetLookupGate = lookupGate
            let worker = WindowControlEventTapWorker(
                configuration: .init(moveChord: [.option], resizeChord: [.option, .shift]),
                windowAccessor: accessor,
                screenProvider: EmptyWindowControlScreenProvider(),
                previewHandler: { _ in },
                activityHandler: { if $0 == .listening { cancelled.fulfill() } }
            )
            let event = try pointerEvent(
                .mouseMoved, at: CGPoint(x: 200, y: 200), flags: .maskAlternate
            )
            XCTAssertFalse(worker.handle(type: .mouseMoved, event: event))
            await fulfillment(of: [lookupStarted], timeout: 1)
            XCTAssertFalse(worker.handle(type: .mouseMoved, event: try pointerEvent(
                .mouseMoved, at: CGPoint(x: 400, y: 400), flags: .maskAlternate
            )))

            XCTAssertFalse(worker.handle(type: disabledType, event: event))
            for type in [CGEventType.leftMouseUp, .leftMouseDown, .leftMouseDragged,
                         .mouseMoved, .rightMouseDown, .keyDown, .flagsChanged, .scrollWheel] {
                XCTAssertFalse(worker.handle(type: type, event: event))
            }
            lookupGate.signal()

            await fulfillment(of: [cancelled], timeout: 1)
            XCTAssertTrue(accessor.movedPositions.isEmpty)
            XCTAssertTrue(accessor.resizedSizes.isEmpty)
            XCTAssertTrue(accessor.setFrames.isEmpty)
        }
    }

    func testRepeatedModifierEventsDoNotReplaceGestureAnchor() async throws {
        let accessor = TestWindowAccessor(target: testTarget())
        let finished = expectation(description: "Original gesture completed")
        let worker = WindowControlEventTapWorker(
            configuration: .init(moveChord: [.control], resizeChord: [.control, .command]),
            windowAccessor: accessor, screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { if $0 == .listening { finished.fulfill() } }
        )
        for (type, point, flags): (CGEventType, CGPoint, CGEventFlags) in [
            (.mouseMoved, CGPoint(x: 200, y: 200), .maskControl),
            (.flagsChanged, CGPoint(x: 230, y: 220), .maskControl),
            (.mouseMoved, CGPoint(x: 240, y: 230), .maskControl),
            (.flagsChanged, CGPoint(x: 240, y: 230), [])
        ] {
            XCTAssertFalse(worker.handle(type: type, event: try pointerEvent(type, at: point, flags: flags)))
        }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(accessor.targetCount, 1)
        XCTAssertEqual(accessor.movedPositions.last, CGPoint(x: 140, y: 130))
    }

    func testChangingBindingsCancelsGestureUntilModifiersAreReleased() async throws {
        let accessor = TestWindowAccessor(target: testTarget())
        let acquired = expectation(description: "Original window acquired")
        let cancelled = expectation(description: "Binding change cancelled gesture")
        let worker = WindowControlEventTapWorker(
            configuration: .init(moveChord: [.option], resizeChord: [.option, .shift]),
            windowAccessor: accessor,
            screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { activity in
                if activity == .tracking(.move) { acquired.fulfill() }
                if activity == .listening { cancelled.fulfill() }
            }
        )
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try pointerEvent(
            .mouseMoved, at: CGPoint(x: 200, y: 200), flags: .maskAlternate
        )))
        await fulfillment(of: [acquired], timeout: 1)

        worker.update(configuration: .init(moveChord: [.command], resizeChord: [.command, .shift]))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try pointerEvent(
            .mouseMoved, at: CGPoint(x: 0, y: 200), flags: .maskAlternate
        )))
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertTrue(accessor.movedPositions.isEmpty)
        XCTAssertTrue(accessor.resizedSizes.isEmpty)
        XCTAssertTrue(accessor.setFrames.isEmpty)
    }

    func testClickFreeResizeAndMoveFlushLastMotionOnKeyRelease() async throws {
        for operation in WindowControlOperation.allCases {
            let accessor = TestWindowAccessor(target: testTarget())
            let finished = expectation(description: "Click-free gesture completed")
            let worker = WindowControlEventTapWorker(
                configuration: .init(moveChord: [.control], resizeChord: [.control, .command]),
                windowAccessor: accessor, screenProvider: EmptyWindowControlScreenProvider(),
                previewHandler: { _ in },
                activityHandler: { if $0 == .listening { finished.fulfill() } }
            )
            let flags: CGEventFlags = operation == .move ? .maskControl : [.maskControl, .maskCommand]
            for (type, point, modifiers): (CGEventType, CGPoint, CGEventFlags) in [
                (.flagsChanged, CGPoint(x: 200, y: 200), flags),
                (.mouseMoved, CGPoint(x: 240, y: 230), flags),
                // Key-release coordinates must not add unobserved motion.
                (.flagsChanged, CGPoint(x: 900, y: 800), [])
            ] {
                XCTAssertFalse(worker.handle(type: type, event: try pointerEvent(type, at: point, flags: modifiers)))
            }
            await fulfillment(of: [finished], timeout: 1)
            XCTAssertEqual(accessor.targetCount, 1)
            if operation == .move {
                XCTAssertEqual(accessor.movedPositions.last, CGPoint(x: 140, y: 130))
                XCTAssertTrue(accessor.resizedSizes.isEmpty)
            } else {
                XCTAssertEqual(accessor.resizedSizes.last, CGSize(width: 440, height: 330))
                XCTAssertTrue(accessor.movedPositions.isEmpty)
            }
        }
    }

    func testWindowControlEventMaskObservesMotionAndShortcutCancellation() {
        let mask = WindowControlEventTapConfiguration.eventMask
        for type in [CGEventType.mouseMoved, .flagsChanged, .keyDown, .scrollWheel,
                     .leftMouseDown, .rightMouseDown, .otherMouseDown,
                     .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            XCTAssertNotEqual(mask & (CGEventMask(1) << type.rawValue), 0)
        }
        for type in [CGEventType.keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp] {
            XCTAssertEqual(mask & (CGEventMask(1) << type.rawValue), 0)
        }
    }

    func testUnmodifiedMotionAndUnrelatedShortcutsDoNotAcquireWindow() throws {
        let accessor = TestWindowAccessor(target: testTarget())
        let worker = WindowControlEventTapWorker(
            configuration: .init(moveChord: [.control], resizeChord: [.control, .command]),
            windowAccessor: accessor, screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in }, activityHandler: { _ in }
        )
        for flags: CGEventFlags in [[], .maskAlternate, [.maskControl, .maskShift], .maskCommand] {
            XCTAssertFalse(worker.handle(type: .mouseMoved, event: try pointerEvent(
                .mouseMoved, at: CGPoint(x: 240, y: 230), flags: flags
            )))
        }
        XCTAssertEqual(accessor.targetCount, 0)
    }

    func testMissedModifierReleaseStopsAtLastMotionWithoutSnapping() async throws {
        let accessor = TestWindowAccessor(target: testTarget())
        let finished = expectation(description: "Missed release completed safely")
        let worker = WindowControlEventTapWorker(
            configuration: .init(moveChord: [.control], resizeChord: [.control, .command]),
            windowAccessor: accessor, screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { if $0 == .listening { finished.fulfill() } }
        )
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try pointerEvent(
            .mouseMoved, at: CGPoint(x: 200, y: 200), flags: .maskControl
        )))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try pointerEvent(
            .mouseMoved, at: CGPoint(x: 0, y: 230), flags: []
        )))
        await fulfillment(of: [finished], timeout: 1)
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            XCTAssertFalse(worker.handle(type: type, event: try pointerEvent(type, at: .zero, flags: [])))
        }
        XCTAssertEqual(accessor.targetCount, 1)
        XCTAssertTrue(accessor.movedPositions.isEmpty)
        XCTAssertTrue(accessor.resizedSizes.isEmpty)
        XCTAssertTrue(accessor.setFrames.isEmpty)
    }

    private func pointerEvent(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = type
        event.location = point
        event.flags = flags
        return event
    }

    func testPointerCoordinatorPreviewsSnapAndCommitsOnlyOnFinish() {
        let accessor = TestWindowAccessor(target: testTarget())
        let previews = TestWindowControlPreviewRecorder()
        let screen = WindowControlScreen(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 776)
        )
        let coordinator = WindowControlPointerCoordinator(
            windowAccessor: accessor,
            screenProvider: TestWindowControlScreenProvider(screen: screen),
            previewHandler: previews.record
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

        XCTAssertTrue(accessor.setFrames.isEmpty)
        XCTAssertEqual(
            previews.values.compactMap { $0 },
            [
                WindowControlSnapDestination(
                    zone: .leftHalf,
                    frame: CGRect(x: 0, y: 24, width: 500, height: 776)
                ),
            ]
        )
        XCTAssertEqual(coordinator.finish(commitSnap: true), .listening)
        XCTAssertEqual(
            accessor.setFrames,
            [CGRect(x: 0, y: 24, width: 500, height: 776)]
        )
        XCTAssertNil(previews.values.last ?? nil)
    }

    func testPointerCoordinatorCancelsSnapBeforeFinish() {
        let accessor = TestWindowAccessor(target: testTarget())
        let previews = TestWindowControlPreviewRecorder()
        let screen = WindowControlScreen(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 776)
        )
        let coordinator = WindowControlPointerCoordinator(
            windowAccessor: accessor,
            screenProvider: TestWindowControlScreenProvider(screen: screen),
            previewHandler: previews.record
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

        XCTAssertEqual(coordinator.finish(commitSnap: false), .listening)
        XCTAssertTrue(accessor.setFrames.isEmpty)
        XCTAssertNil(previews.values.last ?? nil)
    }

    func testPointerCoordinatorHidesPreviewAfterLeavingSnapZone() {
        let accessor = TestWindowAccessor(target: testTarget())
        let previews = TestWindowControlPreviewRecorder()
        let screen = WindowControlScreen(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 776)
        )
        let coordinator = WindowControlPointerCoordinator(
            windowAccessor: accessor,
            screenProvider: TestWindowControlScreenProvider(screen: screen),
            previewHandler: previews.record
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
                location: CGPoint(x: 100, y: 320)
            )
        )

        XCTAssertNil(previews.values.last ?? nil)
        XCTAssertEqual(coordinator.finish(commitSnap: true), .listening)
        XCTAssertTrue(accessor.setFrames.isEmpty)
    }

    func testModifierSessionArmsWithoutAXAndCommitsOnlyOnFullRelease() {
        let configuration = WindowControlConfiguration(moveChord: [.control], resizeChord: [.control, .command])
        for operation in WindowControlOperation.allCases {
            var session = WindowControlModifierSession()
            let flags: CGEventFlags = operation == .move ? .maskControl : [.maskControl, .maskCommand]
            XCTAssertEqual(session.handle(type: .flagsChanged, flags: flags, location: .zero, configuration: configuration), .init())
            let began = session.handle(type: .mouseMoved, flags: flags, location: CGPoint(x: 10, y: 20), configuration: configuration)
            XCTAssertEqual(began.begin, .init(operation: operation, location: .zero))
            XCTAssertEqual(began.update, .init(operation: operation, location: CGPoint(x: 10, y: 20)))
            let ended = session.handle(type: .flagsChanged, flags: [], location: .zero, configuration: configuration)
            XCTAssertEqual(ended.completion?.shouldCommitSnap, operation == .move)
            XCTAssertNil(session.operation)
            XCTAssertEqual(session.handle(type: .mouseMoved, flags: [], location: .zero, configuration: configuration), .init())
        }
    }

    func testModifierSessionRebasesWhenSwitchingBetweenMoveAndResize() {
        let configuration = WindowControlConfiguration(moveChord: [.control], resizeChord: [.control, .command])
        var session = WindowControlModifierSession()
        _ = session.handle(type: .mouseMoved, flags: .maskControl, location: .zero, configuration: configuration)
        let switchPoint = CGPoint(x: 30, y: 40)
        let changed = session.handle(type: .flagsChanged, flags: [.maskControl, .maskCommand], location: switchPoint, configuration: configuration)
        XCTAssertEqual(changed.completion?.shouldCommitSnap, false)
        XCTAssertNil(changed.begin, "Do not acquire or resize until the pointer moves")
        let resize = session.handle(type: .mouseMoved, flags: [.maskControl, .maskCommand], location: CGPoint(x: 40, y: 50), configuration: configuration)
        XCTAssertEqual(resize.begin, .init(operation: .resize, location: switchPoint))
        let releasedCommand = session.handle(type: .flagsChanged, flags: .maskControl, location: CGPoint(x: 40, y: 50), configuration: configuration)
        XCTAssertEqual(releasedCommand.completion?.shouldCommitSnap, false)
        let move = session.handle(type: .mouseMoved, flags: .maskControl, location: CGPoint(x: 50, y: 60), configuration: configuration)
        XCTAssertEqual(move.begin, .init(operation: .move, location: CGPoint(x: 40, y: 50)))
    }

    func testHeldModifierContinuesAcrossSeparatePointerMovements() {
        let configuration = WindowControlConfiguration(moveChord: [.control], resizeChord: [.control, .command])
        var session = WindowControlModifierSession()
        _ = session.handle(type: .mouseMoved, flags: .maskControl, location: .zero, configuration: configuration)
        for x in 1...100 {
            let point = CGPoint(x: x, y: 20)
            let transition = session.handle(type: .mouseMoved, flags: .maskControl, location: point, configuration: configuration)
            XCTAssertNil(transition.begin, "Lifting and placing a finger must not retarget the gesture")
            XCTAssertEqual(transition.update, .init(operation: .move, location: point))
            XCTAssertNil(transition.completion)
        }
    }

    func testClicksDragsScrollAndShortcutsCancelUntilAllModifiersAreReleased() {
        let configuration = WindowControlConfiguration(moveChord: [.control], resizeChord: [.control, .command])
        for type in [CGEventType.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown,
                     .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            var session = WindowControlModifierSession()
            _ = session.handle(type: .mouseMoved, flags: .maskControl, location: .zero, configuration: configuration)
            XCTAssertTrue(session.handle(type: type, flags: .maskControl, location: .zero, configuration: configuration).shouldCancel)
            XCTAssertEqual(session.handle(type: .mouseMoved, flags: .maskControl, location: .zero, configuration: configuration), .init())
            XCTAssertEqual(session.handle(type: .flagsChanged, flags: [], location: .zero, configuration: configuration), .init())
            XCTAssertNotNil(session.handle(type: .mouseMoved, flags: .maskControl, location: .zero, configuration: configuration).begin)
        }
    }

    func testExtraModifiersAndMissingReleaseNeverCommitSnap() {
        let configuration = WindowControlConfiguration(moveChord: [.control], resizeChord: [.control, .command])
        for (type, flags): (CGEventType, CGEventFlags) in [
            (.flagsChanged, [.maskControl, .maskShift]), (.mouseMoved, []),
            (.mouseMoved, [.maskControl, .maskCommand])
        ] {
            var session = WindowControlModifierSession()
            _ = session.handle(type: .mouseMoved, flags: .maskControl, location: .zero, configuration: configuration)
            let transition = session.handle(type: type, flags: flags, location: .zero, configuration: configuration)
            XCTAssertEqual(transition.completion?.shouldCommitSnap, false)
        }
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

    func testFailedGestureDoesNotRetargetAnotherWindowAndKeepsFailureOnFinish() {
        let accessor = TestWindowAccessor(target: nil)
        let coordinator = WindowControlPointerCoordinator(windowAccessor: accessor)
        let initial = WindowControlPointerSample(operation: .move, location: .zero)
        let later = WindowControlPointerSample(operation: .move, location: CGPoint(x: 800, y: 600))
        XCTAssertEqual(coordinator.process(initial), .targetUnavailable)
        accessor.targetValue = testTarget()
        XCTAssertEqual(coordinator.process(later), .targetUnavailable)
        XCTAssertEqual(accessor.targetCount, 1)
        XCTAssertTrue(accessor.movedPositions.isEmpty)
        XCTAssertEqual(coordinator.finish(commitSnap: true), .targetUnavailable)

        XCTAssertEqual(coordinator.process(initial), .tracking(.move))
        accessor.acceptsUpdates = false
        XCTAssertEqual(coordinator.process(later), .updateRejected(.move))
        accessor.acceptsUpdates = true
        XCTAssertEqual(coordinator.process(later), .updateRejected(.move))
        XCTAssertEqual(accessor.targetCount, 2)
        XCTAssertEqual(coordinator.finish(commitSnap: true), .updateRejected(.move))
        XCTAssertTrue(accessor.setFrames.isEmpty)

        XCTAssertEqual(coordinator.process(initial), .tracking(.move))
        XCTAssertEqual(accessor.targetCount, 3)
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
        XCTAssertEqual(controller.moveChord, [.control])
        XCTAssertEqual(controller.resizeChord, [.control, .command])
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
        XCTAssertEqual(controller.resizeChord, [.control, .command])
        XCTAssertEqual(
            controller.validationMessage,
            "This key combination is already used by Move Window."
        )
    }

    func testExplicitlyClearedBindingsStayUnsetAfterRestart() {
        let suiteName = "window-control-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = WindowControlController(
            defaults: defaults, monitor: TestWindowControlMonitor(),
            permissionProvider: TestWindowControlPermissionProvider()
        )
        XCTAssertTrue(controller.setChord(nil, for: .move))
        XCTAssertTrue(controller.setChord(nil, for: .resize))
        let restored = WindowControlController(
            defaults: defaults, monitor: TestWindowControlMonitor(),
            permissionProvider: TestWindowControlPermissionProvider()
        )
        XCTAssertNil(restored.moveChord)
        XCTAssertNil(restored.resizeChord)
        XCTAssertFalse(restored.isConfigurationValid)
    }

    func testMalformedStoredChordDoesNotSilentlyEnableDefaultBinding() {
        let suiteName = "window-control-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("invalid", forKey: "windowControl.moveChord")
        let controller = WindowControlController(
            defaults: defaults, monitor: TestWindowControlMonitor(),
            permissionProvider: TestWindowControlPermissionProvider()
        )
        XCTAssertNil(controller.moveChord)
        XCTAssertFalse(controller.isConfigurationValid)
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
        controller.setChord(nil, for: .resize)
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

    func testHealthyWindowMonitorIsNotRestartedByHealthCheck() async {
        let (controller, monitor, _) = makeRunningController()
        defer { controller.stop() }

        await controller.recoverMonitoringIfNeeded()

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.recoverCount, 0)
        XCTAssertEqual(controller.runtimeStatus, .active)
    }

    func testDisabledWindowTapRecoversWithoutActivatingYorozu() async {
        let (controller, monitor, _) = makeRunningController()
        defer { controller.stop() }
        monitor.interrupt()

        await controller.recoverMonitoringIfNeeded()

        XCTAssertEqual(monitor.recoverCount, 1)
        XCTAssertEqual(monitor.recreateRequests, [false])
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(controller.lastActivity, .monitorRecovered)
    }

    func testFailedWindowRecoveryRemainsUnavailableAndCanRetry() async {
        let (controller, monitor, _) = makeRunningController()
        defer { controller.stop() }
        monitor.interrupt()
        monitor.recoverySucceeds = false

        await controller.recoverMonitoringIfNeeded()
        XCTAssertEqual(controller.runtimeStatus, .unavailable)
        XCTAssertFalse(monitor.isRunning)

        monitor.recoverySucceeds = true
        await controller.recoverMonitoringIfNeeded()
        XCTAssertEqual(monitor.recoverCount, 2)
        XCTAssertEqual(controller.runtimeStatus, .active)
    }

    func testRevokedWindowPermissionStopsMonitorBeforeRecovery() async {
        let (controller, monitor, permissions) = makeRunningController()
        defer { controller.stop() }
        permissions.isAccessibilityGranted = false

        await controller.recoverMonitoringIfNeeded()

        XCTAssertEqual(monitor.recoverCount, 0)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
    }

    func testSystemSettingsPausesSynchronouslyAndBlocksRecoveryUntilSafeToResume() async {
        let notifications = NotificationCenter()
        let backgroundActivity = TestWindowControlBackgroundActivityManager()
        let (controller, monitor, permissions) = makeRunningController(
            notifications: notifications, backgroundActivity: backgroundActivity
        )
        defer { controller.stop() }
        XCTAssertTrue(backgroundActivity.isActive)

        permissions.isSystemSettingsActive = true
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // The notification must remove the tap before yielding to another task.
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(backgroundActivity.isActive)
        XCTAssertEqual(controller.runtimeStatus, .pausedForSystemSettings)
        await controller.recoverMonitoringIfNeeded()
        await controller.recoverMonitoringIfNeeded(recreate: true)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.recoverCount, 0)

        permissions.isAccessibilityGranted = false
        permissions.isSystemSettingsActive = false
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await controller.recoverMonitoringIfNeeded()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(backgroundActivity.isActive)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        XCTAssertEqual(monitor.recoverCount, 0)

        permissions.isAccessibilityGranted = true
        await controller.recoverMonitoringIfNeeded()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(backgroundActivity.isActive)
        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.recoverCount, 1)
    }

    func testLeavingSystemSettingsResumesWithExistingPermission() async {
        let notifications = NotificationCenter()
        let (controller, monitor, permissions) = makeRunningController(notifications: notifications)
        defer { controller.stop() }

        permissions.isSystemSettingsActive = true
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await Task.yield()
        XCTAssertFalse(monitor.isRunning)

        permissions.isSystemSettingsActive = false
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.startCount, 2)
    }

    func testWindowHealthCheckRemainsAvailableWhilePausedInSystemSettings() async {
        let monitor = TestWindowControlMonitor()
        let permissions = TestWindowControlPermissionProvider(isAccessibilityGranted: true)
        permissions.isSystemSettingsActive = true
        let controller = WindowControlController(
            defaults: UserDefaults(suiteName: "window-control-\(UUID().uuidString)")!,
            monitor: monitor,
            permissionProvider: permissions,
            monitoringHealthInterval: .milliseconds(20)
        )
        controller.setChord([.option], for: .move)
        controller.setChord([.option, .shift], for: .resize)
        controller.isEnabled = true
        controller.start()
        defer { controller.stop() }
        XCTAssertEqual(controller.runtimeStatus, .pausedForSystemSettings)
        XCTAssertEqual(monitor.startCount, 0)

        let recovered = expectation(description: "Paused health task detects Settings exit")
        monitor.recoveryStarted = { recovered.fulfill() }
        permissions.isSystemSettingsActive = false
        await fulfillment(of: [recovered], timeout: 1)

        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .active)
        XCTAssertEqual(monitor.recoverCount, 1)
    }

    func testSystemSettingsEnteringDuringRecoveryCannotRestartWindowControl() async {
        let (controller, monitor, permissions) = makeRunningController()
        defer { controller.stop() }
        monitor.interrupt()
        monitor.holdsRecovery = true
        let started = expectation(description: "Window recovery reached await")
        monitor.recoveryStarted = { started.fulfill() }
        let recovery = Task { await controller.recoverMonitoringIfNeeded() }
        await fulfillment(of: [started], timeout: 1)

        // Exercise the post-await check even before a workspace notification arrives.
        permissions.isSystemSettingsActive = true
        monitor.completeRecovery()
        await recovery.value

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .pausedForSystemSettings)
        await controller.recoverMonitoringIfNeeded()
        XCTAssertEqual(monitor.recoverCount, 1)
    }

    func testChangingWindowBindingRechecksRevokedPermission() {
        let (controller, monitor, permissions) = makeRunningController()
        defer { controller.stop() }
        permissions.isAccessibilityGranted = false

        controller.setChord([.control], for: .move)

        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(controller.isAccessibilityGranted)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)
        XCTAssertEqual(monitor.startCount, 1)
    }

    func testPermissionRegrantRecoversWithoutForegroundAndRestoresBackgroundActivity() async {
        let defaults = UserDefaults(suiteName: "window-control-\(UUID().uuidString)")!
        let monitor = TestWindowControlMonitor()
        let permissions = TestWindowControlPermissionProvider(isAccessibilityGranted: true)
        let backgroundActivity = TestWindowControlBackgroundActivityManager()
        let controller = WindowControlController(
            defaults: defaults, monitor: monitor, permissionProvider: permissions,
            backgroundActivityManager: backgroundActivity,
            monitoringHealthInterval: .milliseconds(20)
        )
        controller.setChord([.option], for: .move)
        controller.setChord([.option, .shift], for: .resize)
        controller.isEnabled = true
        controller.start()
        defer { controller.stop() }

        permissions.isAccessibilityGranted = false
        await controller.recoverMonitoringIfNeeded()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(backgroundActivity.isActive)
        XCTAssertEqual(controller.runtimeStatus, .permissionRequired)

        permissions.isAccessibilityGranted = true
        let recovered = expectation(description: "Existing health task detects re-grant")
        monitor.recoveryStarted = { recovered.fulfill() }
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertEqual(monitor.recoverCount, 1)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(backgroundActivity.isActive)
        XCTAssertEqual(controller.runtimeStatus, .active)
    }

    func testDisablingWindowControlDuringRecoveryCannotRestartIt() async {
        let (controller, monitor, _) = makeRunningController()
        defer { controller.stop() }
        monitor.interrupt()
        monitor.holdsRecovery = true
        let started = expectation(description: "Recovery reached await")
        monitor.recoveryStarted = { started.fulfill() }
        let recovery = Task { await controller.recoverMonitoringIfNeeded() }
        await fulfillment(of: [started], timeout: 1)

        controller.isEnabled = false
        monitor.completeRecovery()
        await recovery.value

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .off)
    }

    func testWindowWakeAndSessionRecoveryObserversAreRemovedOnStop() async {
        let notifications = NotificationCenter()
        let (controller, monitor, permissions) = makeRunningController(notifications: notifications)
        let recovered = expectation(description: "Wake and session recovered")
        recovered.expectedFulfillmentCount = 2
        monitor.recoveryStarted = { recovered.fulfill() }

        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertEqual(monitor.recreateRequests, [true, true])

        controller.stop()
        permissions.isSystemSettingsActive = true
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(monitor.recoverCount, 2)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .off)
    }

    private func makeRunningController(
        notifications: NotificationCenter? = nil,
        backgroundActivity: TestWindowControlBackgroundActivityManager? = nil
    ) -> (
        WindowControlController, TestWindowControlMonitor, TestWindowControlPermissionProvider
    ) {
        let defaults = UserDefaults(suiteName: "window-control-\(UUID().uuidString)")!
        let monitor = TestWindowControlMonitor()
        let permissions = TestWindowControlPermissionProvider(isAccessibilityGranted: true)
        let controller = WindowControlController(
            defaults: defaults,
            monitor: monitor,
            permissionProvider: permissions,
            backgroundActivityManager: backgroundActivity ?? TestWindowControlBackgroundActivityManager(),
            workspaceNotificationCenter: notifications
        )
        controller.setChord([.option], for: .move)
        controller.setChord([.option, .shift], for: .resize)
        controller.isEnabled = true
        controller.start()
        return (controller, monitor, permissions)
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
    private(set) var recoverCount = 0
    private(set) var recreateRequests: [Bool] = []
    var recoverySucceeds = true
    var holdsRecovery = false
    var recoveryStarted: (() -> Void)?
    private var pendingRecovery: CheckedContinuation<Void, Never>?
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

    func interrupt() { isRunning = false }

    func recover(configuration: WindowControlConfiguration, recreate: Bool) async -> Bool {
        recoverCount += 1
        recreateRequests.append(recreate)
        if holdsRecovery {
            await withCheckedContinuation { continuation in
                pendingRecovery = continuation
                recoveryStarted?()
            }
        } else {
            recoveryStarted?()
        }
        isRunning = recoverySucceeds
        return recoverySucceeds
    }

    func completeRecovery() {
        pendingRecovery?.resume()
        pendingRecovery = nil
    }
}

private final class TestWindowAccessor: WindowAccessing, @unchecked Sendable {
    var targetValue: WindowControlTarget?
    var acceptsUpdates = true
    var targetLookupStarted: (@Sendable () -> Void)?
    var targetLookupGate: DispatchSemaphore?
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
        targetLookupStarted?()
        if let targetLookupGate { _ = targetLookupGate.wait(timeout: .now() + 2) }
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

private final class TestWindowControlPreviewRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [WindowControlSnapDestination?] = []

    var values: [WindowControlSnapDestination?] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func record(_ destination: WindowControlSnapDestination?) {
        lock.lock()
        storedValues.append(destination)
        lock.unlock()
    }
}

@MainActor
private final class TestWindowControlPermissionProvider:
    CommandInputModePermissionProviding {
    var isAccessibilityGranted: Bool
    var isSystemSettingsActive = false

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
