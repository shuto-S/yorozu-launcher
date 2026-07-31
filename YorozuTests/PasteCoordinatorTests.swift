import Foundation
import XCTest
@testable import Yorozu

@MainActor
final class PasteCoordinatorTests: XCTestCase {
    func testTrustedActiveTargetPostsPasteOnceAndRestoresClipboard() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(fixture.events.postPasteCount, 1)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 1)
        XCTAssertEqual(fixture.suppression.count, 2)
    }

    func testPermissionDeniedCopiesWithoutPostingPaste() async {
        let fixture = makeFixture(isAccessibilityTrusted: false)

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .copiedBecausePermissionDenied)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
        XCTAssertEqual(fixture.target.activateCount, 1)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
    }

    func testMissingTargetCopiesWithoutPostingPaste() async {
        let fixture = makeFixture()

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: nil
        )

        XCTAssertEqual(result, .copiedBecauseTargetUnavailable)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
    }

    func testActivationRequestFailureDoesNotPostPaste() async {
        let fixture = makeFixture()
        fixture.target.activationSucceeds = false

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .copiedBecauseActivationFailed)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
    }

    func testDelayedActivationPostsOnlyAfterTargetBecomesActive() async {
        let fixture = makeFixture()
        fixture.events.onSleep = {
            if fixture.events.sleepCount == 2 {
                fixture.target.isActive = true
            }
        }

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .pasted)
        XCTAssertGreaterThanOrEqual(fixture.events.sleepCount, 3)
        XCTAssertEqual(fixture.events.postPasteCount, 1)
    }

    func testActivationTimeoutCopiesWithoutPostingPaste() async {
        let fixture = makeFixture()

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .copiedBecauseActivationFailed)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
    }

    func testTerminatedTargetStopsActivationWait() async {
        let fixture = makeFixture()
        fixture.events.onSleep = {
            fixture.target.isTerminated = true
        }

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .copiedBecauseTargetUnavailable)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
    }

    func testPasteEventCreationFailureReturnsFailed() async {
        let fixture = makeFixture(postPasteSucceeds: false)
        fixture.target.becomesActiveWhenActivated = true

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fixture.events.postPasteCount, 1)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
    }

    func testSnapshotLimitFailureLeavesClipboardUntouched() async {
        let fixture = makeFixture()
        fixture.pasteboard.snapshotResult = .preservationLimitExceeded

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .failedBecauseClipboardCouldNotBePreserved)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 0)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
    }

    func testWriteFailureReturnsFailedWithoutPostingPaste() async {
        let fixture = makeFixture()
        fixture.pasteboard.replacementResult = .writeFailedAndRestored

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 1)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
    }

    func testUnchangedInjectedClipboardIsRestoredAfterPaste() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true

        _ = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(fixture.pasteboard.restoredSnapshots, fixture.pasteboard.originalSnapshot)
    }

    func testUserClipboardChangePreventsRestoration() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true
        fixture.events.onSleep = {
            if fixture.events.postPasteCount == 1 {
                fixture.pasteboard.simulateExternalWrite()
            }
        }

        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
    }

    func testPasteWritesAndRestoreBothSuppressClipboardMonitor() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true

        _ = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(fixture.suppression.count, 2)
        XCTAssertEqual(fixture.suppression.durations, [.seconds(2), .seconds(2)])
    }

    func testSystemPasteboardRejectsInvalidContentBeforeClearing() throws {
        let pasteboard = NSPasteboard(
            name: .init("com.yorozu.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let accessor = SystemPasteboardAccessor(pasteboard: pasteboard)
        let snapshot = try XCTUnwrap(accessor.snapshot().capturedValue)

        let missingPath = "/private/tmp/yorozu-missing-\(UUID().uuidString)"
        XCTAssertEqual(
            accessor.replace(with: .files([missingPath]), preserving: snapshot),
            .invalidContent
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        XCTAssertEqual(
            accessor.replace(with: .image(Data()), preserving: snapshot),
            .invalidContent
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        XCTAssertEqual(
            accessor.replace(
                with: .image(Data("not an image".utf8)),
                preserving: snapshot
            ),
            .invalidContent
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSystemPasteboardRestoresAfterWriteFailure() throws {
        let pasteboard = NSPasteboard(
            name: .init("com.yorozu.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var writeCount = 0
        let accessor = SystemPasteboardAccessor(
            pasteboard: pasteboard,
            writeObjects: { objects in
                writeCount += 1
                return writeCount == 1 ? false : pasteboard.writeObjects(objects)
            }
        )
        let snapshot = try XCTUnwrap(accessor.snapshot().capturedValue)

        XCTAssertEqual(
            accessor.replace(with: .text("replacement"), preserving: snapshot),
            .writeFailedAndRestored
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSystemPasteboardReportsRestoreFailure() throws {
        let pasteboard = NSPasteboard(
            name: .init("com.yorozu.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let accessor = SystemPasteboardAccessor(
            pasteboard: pasteboard,
            writeObjects: { _ in false }
        )
        let snapshot = try XCTUnwrap(accessor.snapshot().capturedValue)

        XCTAssertEqual(
            accessor.replace(with: .text("replacement"), preserving: snapshot),
            .writeFailedAndRestoreFailed
        )
    }

    func testSystemPasteboardSnapshotLimitDoesNotMutateContents() {
        let pasteboard = NSPasteboard(
            name: .init("com.yorozu.tests.\(UUID().uuidString)")
        )
        let items = (0..<17).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString("item-\(index)", forType: .string)
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
        let changeCount = pasteboard.changeCount
        let accessor = SystemPasteboardAccessor(pasteboard: pasteboard)

        XCTAssertEqual(accessor.snapshot(), .preservationLimitExceeded)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
    }

    func testPasteCoordinatorContainsNoLoggingCalls() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Yorozu/Platform/ClipboardServices.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let coordinatorSource = try XCTUnwrap(
            source.range(of: "@MainActor\nfinal class PasteCoordinator")
        )
        let implementation = source[coordinatorSource.lowerBound...]

        XCTAssertFalse(implementation.contains("Logger("))
        XCTAssertFalse(implementation.contains("logger."))
        XCTAssertFalse(implementation.contains("print("))
    }

    private func makeFixture(
        isAccessibilityTrusted: Bool = true,
        postPasteSucceeds: Bool = true
    ) -> PasteCoordinatorFixture {
        let pasteboard = FakePasteboard()
        let target = FakePasteTarget()
        let events = PasteEventSpy(postPasteSucceeds: postPasteSucceeds)
        let suppression = SuppressionSpy()
        let dependencies = PasteCoordinatorDependencies(
            isAccessibilityTrusted: {
                isAccessibilityTrusted
            },
            postPasteShortcut: {
                events.postPasteCount += 1
                return events.postPasteSucceeds
            },
            sleep: { _ in
                events.sleepCount += 1
                events.onSleep?()
            },
            activationPollInterval: .milliseconds(1),
            activationPollAttempts: 3,
            activationGracePeriod: .milliseconds(1),
            restorationDelay: .milliseconds(1)
        )
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            suppressClipboardMonitor: { duration in
                suppression.durations.append(duration)
            },
            dependencies: dependencies
        )
        return PasteCoordinatorFixture(
            coordinator: coordinator,
            pasteboard: pasteboard,
            target: target,
            events: events,
            suppression: suppression
        )
    }
}

@MainActor
private struct PasteCoordinatorFixture {
    let coordinator: PasteCoordinator
    let pasteboard: FakePasteboard
    let target: FakePasteTarget
    let events: PasteEventSpy
    let suppression: SuppressionSpy
}

@MainActor
private final class FakePasteTarget: PasteTargetApplication {
    var activationSucceeds = true
    var becomesActiveWhenActivated = false
    var isActive = false
    var isTerminated = false
    private(set) var activateCount = 0

    @discardableResult
    func activate() -> Bool {
        activateCount += 1
        if activationSucceeds && becomesActiveWhenActivated {
            isActive = true
        }
        return activationSucceeds
    }
}

@MainActor
private final class FakePasteboard: PasteboardAccessing {
    let originalSnapshot = PasteboardSnapshot(
        items: [
            PasteboardItemSnapshot(
                values: [
                    PasteboardTypeData(
                        type: "public.utf8-plain-text",
                        data: Data("original".utf8)
                    ),
                ]
            ),
        ]
    )

    private(set) var changeCount = 1
    private(set) var restoreCount = 0
    private(set) var replaceCount = 0
    private(set) var restoredSnapshots: PasteboardSnapshot?
    var snapshotResult: PasteboardSnapshotResult?
    var replacementResult: PasteboardReplacementResult?

    func snapshot() -> PasteboardSnapshotResult {
        snapshotResult ?? .captured(originalSnapshot)
    }

    func replace(
        with content: PasteboardContent,
        preserving snapshot: PasteboardSnapshot
    ) -> PasteboardReplacementResult {
        replaceCount += 1
        if let replacementResult {
            return replacementResult
        }
        changeCount += 1
        return .written(changeCount: changeCount)
    }

    @discardableResult
    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        changeCount += 1
        restoreCount += 1
        restoredSnapshots = snapshot
        return true
    }

    func simulateExternalWrite() {
        changeCount += 1
    }
}

@MainActor
private final class PasteEventSpy {
    let postPasteSucceeds: Bool
    var postPasteCount = 0
    var sleepCount = 0
    var onSleep: (() -> Void)?

    init(postPasteSucceeds: Bool) {
        self.postPasteSucceeds = postPasteSucceeds
    }
}

@MainActor
private final class SuppressionSpy {
    var durations: [Duration] = []
    var count: Int {
        durations.count
    }
}

private extension PasteboardSnapshotResult {
    var capturedValue: PasteboardSnapshot? {
        guard case let .captured(snapshot) = self else {
            return nil
        }
        return snapshot
    }
}
