import ApplicationServices
import AppKit
import XCTest
@testable import Yorozu

final class WindowControlTargetTests: XCTestCase {
    func testResolvesWindowThroughTopLevelSheetInsteadOfReturningSheet() {
        let resolver = WindowControlWindowResolver<Int>(
            isWindow: { $0 == 3 },
            relatedElement: { element, attribute in
                switch (element, attribute) {
                case (1, kAXTopLevelUIElementAttribute): 2
                case (2, kAXParentAttribute): 3
                default: nil
                }
            },
            isEqual: { $0 == $1 }
        )
        XCTAssertEqual(resolver.resolve(1), 3)
    }

    func testInvalidWindowRelationStillFallsBackToParent() {
        let resolver = WindowControlWindowResolver<Int>(
            isWindow: { $0 == 4 },
            relatedElement: { element, attribute in
                switch (element, attribute) {
                case (1, kAXWindowAttribute): 2
                case (2, kAXWindowAttribute): 2
                case (1, kAXParentAttribute): 3
                case (3, kAXParentAttribute): 4
                default: nil
                }
            },
            isEqual: { $0 == $1 }
        )
        XCTAssertEqual(resolver.resolve(1), 4)
    }

    func testCyclicAndOversizedAccessibilityTreesAreBounded() {
        var reads = 0
        let cycle = WindowControlWindowResolver<Int>(
            isWindow: { _ in false },
            relatedElement: { element, _ in
                reads += 1
                return element == 1 ? 2 : 1
            },
            isEqual: { $0 == $1 }
        )
        XCTAssertNil(cycle.resolve(1))
        XCTAssertEqual(reads, 6)

        reads = 0
        let chain = WindowControlWindowResolver<Int>(
            isWindow: { _ in false },
            relatedElement: { element, attribute in
                reads += 1
                return attribute == kAXParentAttribute ? element + 1 : nil
            },
            isEqual: { $0 == $1 }
        )
        XCTAssertNil(chain.resolve(1))
        XCTAssertEqual(reads, 96)
    }

    func testWindowBoundsMatchAllowsRoundingButNotAnotherOverlappingWindow() {
        let record = WindowControlWindowRecord(
            processIdentifier: 123,
            frame: CGRect(x: -100, y: 40, width: 600, height: 400)
        )
        XCTAssertTrue(record.matches(frame: record.frame))
        XCTAssertTrue(record.matches(frame: CGRect(x: -99.5, y: 40, width: 600.5, height: 400)))
        XCTAssertFalse(record.matches(frame: CGRect(x: -90, y: 40, width: 600, height: 400)))
        XCTAssertFalse(record.matches(frame: CGRect(x: -100, y: 40, width: 500, height: 300)))
    }

    func testWindowBoundsMatchAllowsMacOS26StandardWindowInsets() {
        let axFrame = CGRect(x: 40, y: 948, width: 640, height: 452)
        let record = WindowControlWindowRecord(
            processIdentifier: 123,
            frame: CGRect(x: 43, y: 950, width: 634, height: 448)
        )
        XCTAssertTrue(record.matches(frame: axFrame))
        XCTAssertFalse(record.matches(frame: axFrame.offsetBy(dx: 8, dy: 0)))
        XCTAssertFalse(record.matches(frame: axFrame.insetBy(dx: -3, dy: -3)))
        // Tolerance cannot make an uncertain AXWindows fallback choose arbitrarily.
        XCTAssertNil(record.uniquelyMatchingWindow(
            in: [axFrame, axFrame.offsetBy(dx: 1, dy: 0)],
            canContinue: { true }, frame: { $0 }
        ))
    }

    func testDirectHitTestAcceptsWindowServerLagWithoutLooseningFallback() {
        let record = WindowControlWindowRecord(
            processIdentifier: 123, frame: CGRect(x: 1_401, y: 271, width: 638, height: 450)
        )
        let moved = CGRect(x: 1_424, y: 288, width: 640, height: 452)
        XCTAssertTrue(record.acceptsHitTest(frame: moved, at: CGPoint(x: moved.midX, y: moved.midY)))
        XCTAssertFalse(record.matches(frame: moved))
        XCTAssertFalse(record.acceptsHitTest(frame: moved, at: CGPoint(x: 1_405, y: 280)))
        XCTAssertFalse(record.acceptsHitTest(frame: .zero, at: CGPoint(x: moved.midX, y: moved.midY)))
        XCTAssertFalse(record.acceptsHitTest(frame: moved, at: CGPoint(x: CGFloat.nan, y: 400)))
    }

    func testExpiredLookupDoesNotVisitAccessibilityTree() {
        let resolver = WindowControlWindowResolver<Int>(
            isWindow: { _ in XCTFail("Expired lookup must not read AX roles"); return true },
            relatedElement: { _, _ in XCTFail("Expired lookup must not read AX relations"); return nil },
            isEqual: { $0 == $1 }
        )
        XCTAssertNil(resolver.resolve(1, canContinue: { false }))
    }

    func testLookupDoesNotReturnWindowWhoseRoleReplyExceededDeadline() {
        var timeRemaining = true
        let resolver = WindowControlWindowResolver<Int>(
            isWindow: { _ in timeRemaining = false; return true },
            relatedElement: { _, _ in XCTFail("Late role reply must end lookup"); return nil },
            isEqual: { $0 == $1 }
        )
        XCTAssertNil(resolver.resolve(1, canContinue: { timeRemaining }))
    }

    func testSlowRelationsStopBeforeReadingTheEntireTree() {
        var now: TimeInterval = 0
        var relationReads = 0
        let budget = WindowControlAXLookupBudget(now: { now })
        let resolver = WindowControlWindowResolver<Int>(
            isWindow: { _ in false },
            relatedElement: { element, _ in
                relationReads += 1
                now += 0.6
                return element + 1
            },
            isEqual: { $0 == $1 }
        )
        XCTAssertNil(resolver.resolve(1, canContinue: { budget.requestTimeout != nil }))
        XCTAssertEqual(relationReads, 2)
    }

    func testIndividualAXTimeoutShrinksWithTheOverallDeadlineAndNeverBecomesZero() throws {
        var now: TimeInterval = 50
        let budget = WindowControlAXLookupBudget(now: { now })
        XCTAssertEqual(try XCTUnwrap(budget.requestTimeout), 0.2, accuracy: 0.0001)
        now = 50.95
        XCTAssertEqual(try XCTUnwrap(budget.requestTimeout), 0.05, accuracy: 0.0001)
        now = 50.9999
        XCTAssertNil(budget.requestTimeout)
        now = 51
        XCTAssertNil(budget.requestTimeout)
        now = 52
        XCTAssertNil(budget.requestTimeout)
    }

    func testFallbackRequiresOneUniqueWindowAndACompleteScan() {
        let frame = CGRect(x: 10, y: 20, width: 600, height: 400)
        let record = WindowControlWindowRecord(processIdentifier: 123, frame: frame)
        XCTAssertEqual(record.uniquelyMatchingWindow(
            in: [1, 2, 3], canContinue: { true },
            frame: { $0 == 2 ? frame : frame.offsetBy(dx: 20, dy: 0) }
        ), 2)
        XCTAssertNil(record.uniquelyMatchingWindow(
            in: [1, 2], canContinue: { true }, frame: { _ in frame }
        ))

        var canContinue = true
        var reads = 0
        XCTAssertNil(record.uniquelyMatchingWindow(
            in: [1, 2],
            canContinue: { canContinue },
            frame: { _ in
                reads += 1
                canContinue = false
                return frame
            }
        ))
        XCTAssertEqual(reads, 1)

        XCTAssertNil(record.uniquelyMatchingWindow(
            in: [1, 2], canContinue: { true }, frame: { $0 == 1 ? frame : nil }
        ))
    }

    func testOversizedWindowListsAreRejectedBeforeAnyAXWindowRead() {
        let record = WindowControlWindowRecord(
            processIdentifier: 123, frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        XCTAssertNil(record.uniquelyMatchingWindow(
            in: Array(0..<65), canContinue: { true },
            frame: { _ in XCTFail("Oversized lists must not cause AX reads"); return nil }
        ))
    }

    func testInvalidFramesCannotMatchOrPassGeometryValidation() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let record = WindowControlWindowRecord(processIdentifier: 123, frame: frame)
        let invalidFrames = [
            CGRect(x: CGFloat.nan, y: 0, width: 600, height: 400),
            CGRect(x: 0, y: CGFloat.infinity, width: 600, height: 400),
            CGRect(x: 0, y: 0, width: 0, height: 400),
            CGRect(x: 0, y: 0, width: -600, height: 400),
            CGRect(x: 0, y: 0, width: 600, height: CGFloat.nan),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                   width: CGFloat.greatestFiniteMagnitude, height: 400),
        ]
        for invalid in invalidFrames {
            XCTAssertFalse(WindowControlWindowRecord.isValid(frame: invalid))
            XCTAssertFalse(record.matches(frame: invalid))
        }
    }

    func testInvalidGeometryAndCancelledRaiseAreRejectedBeforeAccessingAXTarget() {
        let accessor = SystemWindowAccessor()
        let target = WindowControlTarget(
            element: NSObject(), processIdentifier: 123,
            initialPosition: .zero, initialSize: CGSize(width: 600, height: 400)
        )
        XCTAssertFalse(accessor.move(target, to: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertFalse(accessor.resize(target, to: CGSize(width: -1, height: 400)))
        XCTAssertFalse(accessor.setFrame(target, to: CGRect(
            x: CGFloat.infinity, y: 0, width: 600, height: 400
        )))
        accessor.raiseAndActivate(target, isCancelled: { true })
        XCTAssertNil(accessor.target(at: CGPoint(x: CGFloat.infinity, y: 0), operation: .move))
    }

    func testAXTargetWhosePIDDoesNotMatchIsRejectedWithoutWriting() {
        let accessor = SystemWindowAccessor()
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let target = WindowControlTarget(
            element: element, processIdentifier: 1,
            initialPosition: .zero, initialSize: CGSize(width: 600, height: 400)
        )
        XCTAssertFalse(accessor.move(target, to: CGPoint(x: 20, y: 20)))
        XCTAssertFalse(accessor.resize(target, to: CGSize(width: 500, height: 300)))
    }

    func testFrameWriterUsesResizeMoveResizeOrder() {
        let frame = CGRect(x: 20, y: 30, width: 600, height: 400)
        var writes: [String] = []
        XCTAssertTrue(WindowControlFrameWriter.apply(
            frame: frame,
            isCancelled: { false },
            resize: { size in
                XCTAssertEqual(size, frame.size)
                writes.append("resize")
                return true
            },
            move: { position in
                XCTAssertEqual(position, frame.origin)
                writes.append("move")
                return true
            }
        ))
        XCTAssertEqual(writes, ["resize", "move", "resize"])
    }

    func testFrameWriterCancellationAfterAnAXWriteStopsRemainingWrites() {
        for cancelAfter in 1...3 {
            var writeCount = 0
            XCTAssertFalse(WindowControlFrameWriter.apply(
                frame: CGRect(x: 20, y: 30, width: 600, height: 400),
                isCancelled: { writeCount >= cancelAfter },
                resize: { _ in writeCount += 1; return true },
                move: { _ in writeCount += 1; return true }
            ))
            XCTAssertEqual(writeCount, cancelAfter)
        }
    }

    func testFrameWriterFailureStopsRemainingWrites() {
        for failAt in 1...3 {
            var writeCount = 0
            XCTAssertFalse(WindowControlFrameWriter.apply(
                frame: CGRect(x: 20, y: 30, width: 600, height: 400),
                isCancelled: { false },
                resize: { _ in writeCount += 1; return writeCount != failAt },
                move: { _ in writeCount += 1; return writeCount != failAt }
            ))
            XCTAssertEqual(writeCount, failAt)
        }
    }

    func testFrameWriterRejectsInvalidGeometryAndInitialCancellationBeforeAnyWrite() {
        for (frame, isCancelled) in [
            (CGRect(x: CGFloat.nan, y: 0, width: 600, height: 400), false),
            (CGRect(x: 0, y: 0, width: 0, height: 400), false),
            (CGRect(x: 0, y: 0, width: 600, height: 400), true),
        ] {
            var writeCount = 0
            XCTAssertFalse(WindowControlFrameWriter.apply(
                frame: frame,
                isCancelled: { isCancelled },
                resize: { _ in writeCount += 1; return true },
                move: { _ in writeCount += 1; return true }
            ))
            XCTAssertEqual(writeCount, 0)
        }
    }
}

@MainActor
final class WindowControlEventPipelineTests: XCTestCase {
    private let moveFlags: CGEventFlags = .maskAlternate
    private let resizeFlags: CGEventFlags = [.maskAlternate, .maskShift]

    func testMoveAndResizeAreRoutedSeparatelyAndFlushMouseUpPosition() async throws {
        for operation in [WindowControlOperation.move, .resize] {
            let accessor = EventPipelineWindowAccessor()
            let finished = expectation(description: "Gesture completed")
            let worker = makeWorker(accessor: accessor) { activity in
                if activity == .listening { finished.fulfill() }
            }
            let flags = operation == .move ? moveFlags : resizeFlags
            XCTAssertTrue(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: flags)))
            XCTAssertTrue(worker.handle(type: .leftMouseDragged, event: try event(.leftMouseDragged, x: 220, y: 210, flags: flags)))
            XCTAssertTrue(worker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, x: 260, y: 240, flags: flags)))
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(accessor.targetCount, 1)
            if operation == .move {
                XCTAssertEqual(accessor.positions.last, CGPoint(x: 160, y: 140))
                XCTAssertTrue(accessor.sizes.isEmpty)
            } else {
                XCTAssertEqual(accessor.sizes.last, CGSize(width: 460, height: 340))
                XCTAssertTrue(accessor.positions.isEmpty)
            }
            XCTAssertTrue(accessor.frames.isEmpty)
        }
    }

    func testUnmodifiedClicksKeysAndModifierOnlyMotionPassThrough() throws {
        let accessor = EventPipelineWindowAccessor()
        let worker = makeWorker(accessor: accessor) { _ in }
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown] {
            XCTAssertFalse(worker.handle(type: type, event: try event(type, x: 200, y: 200, flags: [])))
        }
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 200, y: 200, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 250, y: 220, flags: moveFlags)))
        XCTAssertEqual(accessor.targetCount, 0)
    }

    func testChangingMoveChordToResizeCancelsInsteadOfSwitchingOperations() async throws {
        let accessor = EventPipelineWindowAccessor()
        let finished = expectation(description: "Gesture cancelled")
        let worker = makeWorker(accessor: accessor) { activity in
            if activity == .listening { finished.fulfill() }
        }
        XCTAssertTrue(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 200, y: 200, flags: resizeFlags)))
        XCTAssertTrue(worker.handle(type: .leftMouseDragged, event: try event(.leftMouseDragged, x: 300, y: 260, flags: resizeFlags)))
        XCTAssertTrue(worker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, x: 300, y: 260, flags: resizeFlags)))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(accessor.positions.isEmpty)
        XCTAssertTrue(accessor.sizes.isEmpty)
        XCTAssertTrue(accessor.frames.isEmpty)
        XCTAssertFalse(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: [])))
    }

    func testSnapPreviewDoesNotResizeUntilMouseUp() async throws {
        let accessor = EventPipelineWindowAccessor()
        let previewed = expectation(description: "Snap preview")
        let finished = expectation(description: "Snap completed")
        let worker = makeWorker(accessor: accessor, preview: { destination in
            if destination != nil { previewed.fulfill() }
        }) { activity in
            if activity == .listening { finished.fulfill() }
        }
        XCTAssertTrue(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: moveFlags)))
        XCTAssertTrue(worker.handle(type: .leftMouseDragged, event: try event(.leftMouseDragged, x: 2, y: 250, flags: moveFlags)))
        await fulfillment(of: [previewed], timeout: 2)
        XCTAssertTrue(accessor.frames.isEmpty)
        XCTAssertTrue(accessor.sizes.isEmpty)
        XCTAssertTrue(worker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, x: 2, y: 250, flags: moveFlags)))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(accessor.frames, [CGRect(x: 0, y: 25, width: 720, height: 835)])
    }

    func testRemappedMotionPreviewsSnapAndOnlyMouseUpCommits() async throws {
        let accessor = EventPipelineWindowAccessor()
        let previewed = expectation(description: "Remapped motion previews snap")
        let finished = expectation(description: "Remapped motion snap completed")
        let worker = makeWorker(accessor: accessor, isPrimaryButtonPressed: { true }, preview: { destination in
            if destination != nil { previewed.fulfill() }
        }) { activity in
            if activity == .listening { finished.fulfill() }
        }
        XCTAssertTrue(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: moveFlags)))
        XCTAssertTrue(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 2, y: 250, flags: moveFlags)))
        await fulfillment(of: [previewed], timeout: 2)
        XCTAssertEqual(accessor.positions.last, CGPoint(x: -98, y: 150))
        XCTAssertTrue(accessor.frames.isEmpty)
        XCTAssertTrue(accessor.sizes.isEmpty)
        XCTAssertTrue(worker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, x: 2, y: 250, flags: moveFlags)))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(accessor.frames, [CGRect(x: 0, y: 25, width: 720, height: 835)])
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 500, y: 400, flags: moveFlags)))
        XCTAssertEqual(accessor.targetCount, 1)
    }

    func testChangingChordCancelsRemappedMotionWithoutRetargeting() async throws {
        let accessor = EventPipelineWindowAccessor()
        let cancelled = expectation(description: "Remapped motion cancelled")
        let worker = makeWorker(accessor: accessor, isPrimaryButtonPressed: { true }) { activity in
            if activity == .listening { cancelled.fulfill() }
        }
        XCTAssertTrue(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: moveFlags)))
        XCTAssertTrue(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 2, y: 250, flags: resizeFlags)))
        XCTAssertTrue(worker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, x: 2, y: 250, flags: resizeFlags)))
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(accessor.positions.isEmpty)
        XCTAssertTrue(accessor.sizes.isEmpty)
        XCTAssertTrue(accessor.frames.isEmpty)
    }

    func testStopDuringSlowTargetLookupDoesNotRaiseOrUpdateWindow() async throws {
        for flags in [moveFlags, resizeFlags] {
            let started = expectation(description: "AX lookup started")
            let stopped = expectation(description: "Cancelled work drained")
            let accessor = BlockingPipelineWindowAccessor(lookupStarted: { started.fulfill() })
            let worker = makeWorker(accessor: accessor) { activity in
                if activity == .listening { stopped.fulfill() }
            }
            XCTAssertTrue(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: flags)))
            await fulfillment(of: [started], timeout: 2)
            worker.stop()
            accessor.lookupGate.signal()
            await fulfillment(of: [stopped], timeout: 2)
            XCTAssertEqual(accessor.raiseCount, 0, "A cancelled lookup must not activate its old target.")
            XCTAssertEqual(accessor.writeCount, 0)
        }
    }

    func testCancelDuringSlowMoveDoesNotPublishLateSnapPreview() async throws {
        let started = expectation(description: "AX move started")
        let stopped = expectation(description: "Cancelled work drained")
        let accessor = BlockingPipelineWindowAccessor(moveStarted: { started.fulfill() })
        var previewCount = 0
        let worker = makeWorker(accessor: accessor, preview: { destination in
            if destination != nil { previewCount += 1 }
        }) { activity in
            if activity == .listening { stopped.fulfill() }
        }
        XCTAssertTrue(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: moveFlags)))
        XCTAssertTrue(worker.handle(type: .leftMouseDragged, event: try event(.leftMouseDragged, x: 2, y: 250, flags: moveFlags)))
        await fulfillment(of: [started], timeout: 2)
        worker.stop()
        accessor.moveGate.signal()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(previewCount, 0)
        XCTAssertEqual(accessor.writeCount, 1, "An AX call already in flight cannot be undone; no further writes may follow.")
    }

    func testStraySampleAfterResetDoesNotStartAnotherGesture() async {
        let accessor = EventPipelineWindowAccessor()
        let drained = expectation(description: "Queued work drained")
        let processor = WindowControlPointerProcessor(
            windowAccessor: accessor,
            screenProvider: EmptyWindowControlScreenProvider(),
            previewHandler: { _ in },
            activityHandler: { activity in
                if activity == .monitorRecovered { drained.fulfill() }
            }
        )
        processor.reset()
        processor.submit(.init(operation: .move, location: CGPoint(x: 200, y: 200)))
        processor.report(.monitorRecovered)
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(accessor.targetCount, 0)
        XCTAssertTrue(accessor.positions.isEmpty)
        XCTAssertTrue(accessor.frames.isEmpty)
    }

    private func event(_ type: CGEventType, x: Double, y: Double, flags: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = type
        event.location = CGPoint(x: x, y: y)
        event.flags = flags
        return event
    }

    private func makeWorker(
        accessor: any WindowAccessing,
        isPrimaryButtonPressed: @escaping @Sendable () -> Bool = { false },
        preview: @escaping @MainActor @Sendable (WindowControlSnapDestination?) -> Void = { _ in },
        activity: @escaping @MainActor @Sendable (WindowControlActivity) -> Void
    ) -> WindowControlEventTapWorker {
        // Exercise the production event callback and AX queue without posting
        // global events, accessing user windows, or requiring TCC in unit tests.
        WindowControlEventTapWorker(
            configuration: WindowControlConfiguration(moveChord: [.option], resizeChord: [.option, .shift]),
            windowAccessor: accessor,
            screenProvider: EventPipelineScreenProvider(),
            isPrimaryButtonPressed: isPrimaryButtonPressed,
            previewHandler: preview,
            activityHandler: activity
        )
    }
}

private final class BlockingPipelineWindowAccessor: WindowAccessing, @unchecked Sendable {
    let lookupGate = DispatchSemaphore(value: 0)
    let moveGate = DispatchSemaphore(value: 0)
    private let lookupStarted: (@Sendable () -> Void)?
    private let moveStarted: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var raises = 0
    private var writes = 0

    init(lookupStarted: (@Sendable () -> Void)? = nil, moveStarted: (@Sendable () -> Void)? = nil) {
        self.lookupStarted = lookupStarted
        self.moveStarted = moveStarted
    }

    var raiseCount: Int { lock.withLock { raises } }
    var writeCount: Int { lock.withLock { writes } }

    func target(at point: CGPoint, operation: WindowControlOperation) -> WindowControlTarget? {
        if let lookupStarted {
            lookupStarted()
            _ = lookupGate.wait(timeout: .now() + 3)
        }
        return WindowControlTarget(element: NSObject(), processIdentifier: 123,
                                   initialPosition: CGPoint(x: 100, y: 100),
                                   initialSize: CGSize(width: 400, height: 300))
    }
    func raiseAndActivate(_ target: WindowControlTarget) { lock.withLock { raises += 1 } }
    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool {
        lock.withLock { writes += 1 }
        if let moveStarted {
            moveStarted()
            _ = moveGate.wait(timeout: .now() + 3)
        }
        return true
    }
    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool {
        lock.withLock { writes += 1 }
        return true
    }
    func setFrame(_ target: WindowControlTarget, to frame: CGRect) -> Bool {
        lock.withLock { writes += 1 }
        return true
    }
}

private final class EventPipelineScreenProvider: WindowControlScreenProviding, @unchecked Sendable {
    func screen(containing point: CGPoint) -> WindowControlScreen? {
        WindowControlScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 835))
    }
}

private final class EventPipelineWindowAccessor: WindowAccessing, @unchecked Sendable {
    private(set) var targetCount = 0
    private(set) var positions: [CGPoint] = []
    private(set) var sizes: [CGSize] = []
    private(set) var frames: [CGRect] = []
    func target(at point: CGPoint, operation: WindowControlOperation) -> WindowControlTarget? {
        targetCount += 1
        return WindowControlTarget(element: NSObject(), processIdentifier: 123,
                                   initialPosition: CGPoint(x: 100, y: 100),
                                   initialSize: CGSize(width: 400, height: 300))
    }
    func raiseAndActivate(_ target: WindowControlTarget) {}
    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool { positions.append(position); return true }
    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool { sizes.append(size); return true }
    func setFrame(_ target: WindowControlTarget, to frame: CGRect) -> Bool { frames.append(frame); return true }
}
