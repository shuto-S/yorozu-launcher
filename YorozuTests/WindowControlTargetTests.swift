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

    func testLookupDoesNotReturnWindowWhoseRoleReplyExceededDeadline() {
        var timeRemaining = true
        let resolver = WindowControlWindowResolver<Int>(
            isWindow: { _ in timeRemaining = false; return true },
            relatedElement: { _, _ in XCTFail("Late role reply must end lookup"); return nil },
            isEqual: { $0 == $1 }
        )
        XCTAssertNil(resolver.resolve(1, canContinue: { timeRemaining }))
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

}

@MainActor
final class WindowControlEventPipelineTests: XCTestCase {
    private let moveFlags: CGEventFlags = .maskAlternate
    private let resizeFlags: CGEventFlags = [.maskAlternate, .maskShift]

    func testMoveAndResizeAreRoutedSeparatelyAndFlushMotionOnKeyRelease() async throws {
        for operation in [WindowControlOperation.move, .resize] {
            let accessor = EventPipelineWindowAccessor()
            let finished = expectation(description: "Gesture completed")
            let worker = makeWorker(accessor: accessor) { activity in
                if activity == .listening { finished.fulfill() }
            }
            let flags = operation == .move ? moveFlags : resizeFlags
            XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 200, y: 200, flags: flags)))
            XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 260, y: 240, flags: flags)))
            XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 260, y: 240, flags: [])))
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

    func testChangingMoveChordToResizeFlushesThenRebasesWithoutSnapping() async throws {
        let accessor = EventPipelineWindowAccessor()
        let resized = expectation(description: "Resize applied after move")
        accessor.didResize = { resized.fulfill() }
        let worker = makeWorker(accessor: accessor) { _ in }
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 200, y: 200, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 230, y: 220, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 230, y: 220, flags: resizeFlags)))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 260, y: 240, flags: resizeFlags)))
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 260, y: 240, flags: [])))
        await fulfillment(of: [resized], timeout: 2)
        XCTAssertEqual(accessor.targetCount, 2)
        XCTAssertEqual(accessor.positions.last, CGPoint(x: 130, y: 120))
        XCTAssertEqual(accessor.sizes.last, CGSize(width: 430, height: 320))
        XCTAssertTrue(accessor.frames.isEmpty)
    }

    func testSnapPreviewDoesNotResizeUntilAllModifiersAreReleased() async throws {
        let accessor = EventPipelineWindowAccessor()
        let previewed = expectation(description: "Snap preview")
        let finished = expectation(description: "Snap completed")
        let worker = makeWorker(accessor: accessor, preview: { destination in
            if destination != nil { previewed.fulfill() }
        }) { activity in
            if activity == .listening { finished.fulfill() }
        }
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 200, y: 200, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 2, y: 250, flags: moveFlags)))
        await fulfillment(of: [previewed], timeout: 2)
        XCTAssertTrue(accessor.frames.isEmpty)
        XCTAssertTrue(accessor.sizes.isEmpty)
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 2, y: 250, flags: [])))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(accessor.frames, [CGRect(x: 0, y: 25, width: 720, height: 835)])
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 500, y: 400, flags: [])))
        XCTAssertEqual(accessor.targetCount, 1)
    }

    func testClickDuringMoveCancelsPreviewAndDoesNotRetargetUntilRelease() async throws {
        let accessor = EventPipelineWindowAccessor()
        let acquired = expectation(description: "Target acquired")
        let cancelled = expectation(description: "Click cancelled gesture")
        let worker = makeWorker(accessor: accessor) { activity in
            if activity == .tracking(.move) { acquired.fulfill() }
            if activity == .listening { cancelled.fulfill() }
        }
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 200, y: 200, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 210, y: 200, flags: moveFlags)))
        await fulfillment(of: [acquired], timeout: 2)
        XCTAssertFalse(worker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200, y: 200, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 2, y: 250, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, x: 2, y: 250, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .flagsChanged, event: try event(.flagsChanged, x: 2, y: 250, flags: [])))
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(accessor.targetCount, 1)
        XCTAssertTrue(accessor.positions.allSatisfy { $0 == CGPoint(x: 110, y: 100) })
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
            XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 200, y: 200, flags: flags)))
            XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 210, y: 200, flags: flags)))
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
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 200, y: 200, flags: moveFlags)))
        XCTAssertFalse(worker.handle(type: .mouseMoved, event: try event(.mouseMoved, x: 2, y: 250, flags: moveFlags)))
        await fulfillment(of: [started], timeout: 2)
        worker.stop()
        accessor.moveGate.signal()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(previewCount, 0)
        XCTAssertEqual(accessor.writeCount, 1, "An AX call already in flight cannot be undone; no further writes may follow.")
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
        preview: @escaping @MainActor @Sendable (WindowControlSnapDestination?) -> Void = { _ in },
        activity: @escaping @MainActor @Sendable (WindowControlActivity) -> Void
    ) -> WindowControlEventTapWorker {
        // Exercise the production event callback and AX queue without posting
        // global events, accessing user windows, or requiring TCC in unit tests.
        WindowControlEventTapWorker(
            configuration: WindowControlConfiguration(moveChord: [.option], resizeChord: [.option, .shift]),
            windowAccessor: accessor,
            screenProvider: EventPipelineScreenProvider(),
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
    var didResize: (@Sendable () -> Void)?
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
    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool {
        sizes.append(size)
        didResize?()
        return true
    }
    func setFrame(_ target: WindowControlTarget, to frame: CGRect) -> Bool { frames.append(frame); return true }
}
