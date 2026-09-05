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
        XCTAssertEqual(fixture.events.postedProcessIdentifiers, [fixture.target.processIdentifier])
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
                fixture.target.isFrontmost = true
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

    func testActiveTargetWaitsUntilItIsFrontmostBeforePostingPaste() async {
        let fixture = makeFixture()
        fixture.target.isActive = true
        fixture.events.onSleep = {
            if fixture.events.sleepCount == 2 {
                fixture.target.isFrontmost = true
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

        let copyResult = await fixture.coordinator.copy(.text("replacement"))
        let result = await fixture.coordinator.performPaste(
            .text("private clipboard content"),
            into: fixture.target
        )

        XCTAssertEqual(copyResult, .preservationLimitExceeded)
        XCTAssertEqual(result, .failedBecauseClipboardCouldNotBePreserved)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 0)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
    }

    func testUnavailableSnapshotRejectsCopyAndPasteWithoutChangingClipboard() async {
        let fixture = makeFixture()
        fixture.pasteboard.snapshotResult = .unavailable
        let originalChangeCount = fixture.pasteboard.changeCount

        let copyResult = await fixture.coordinator.copy(.text("replacement"))
        let pasteResult = await fixture.coordinator.performPaste(
            .text("replacement"),
            into: fixture.target
        )

        XCTAssertEqual(copyResult, .preservationFailed)
        XCTAssertEqual(pasteResult, .failedBecauseClipboardCouldNotBePreserved)
        XCTAssertEqual(fixture.pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 0)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
        XCTAssertEqual(fixture.suppression.count, 0)
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

    func testCopyDoesNotReplaceClipboardChangedDuringSuppression() async {
        let fixture = makeFixture()
        fixture.suppression.onSuppress = {
            fixture.pasteboard.simulateExternalWrite()
        }

        let result = await fixture.coordinator.copy(.text("selected"))

        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 0)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
        XCTAssertFalse(fixture.coordinator.isOperationInProgress)
    }

    func testPasteDoesNotReplaceClipboardChangedDuringSuppression() async {
        let fixture = makeFixture()
        fixture.suppression.onSuppress = {
            fixture.pasteboard.simulateExternalWrite()
        }

        let result = await fixture.coordinator.performPaste(.text("selected"), into: fixture.target)

        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 0)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
        XCTAssertEqual(fixture.target.activateCount, 0)
        XCTAssertFalse(fixture.coordinator.isOperationInProgress)
    }

    func testCopyAndPasteRejectClipboardChangedWhileTakingSnapshot() async {
        for isPaste in [false, true] {
            let fixture = makeFixture()
            fixture.pasteboard.onSnapshot = {
                fixture.pasteboard.simulateExternalWrite()
            }

            if isPaste {
                let result = await fixture.coordinator.performPaste(.text("selected"), into: fixture.target)
                XCTAssertEqual(result, .clipboardChanged)
            } else {
                let result = await fixture.coordinator.copy(.text("selected"))
                XCTAssertEqual(result, .clipboardChanged)
            }
            XCTAssertEqual(fixture.suppression.count, 0)
            XCTAssertEqual(fixture.pasteboard.replaceCount, 0)
            XCTAssertEqual(fixture.events.postPasteCount, 0)
        }
    }

    func testExternalCopyDuringActivationWaitPreventsPostingPaste() async {
        let fixture = makeFixture()
        fixture.events.onSleep = {
            fixture.target.isActive = true
            fixture.target.isFrontmost = true
            fixture.pasteboard.simulateExternalWrite()
        }

        let result = await fixture.coordinator.performPaste(.text("selected"), into: fixture.target)

        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
    }

    func testExternalCopyDuringActivationGracePreventsPostingPaste() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true
        fixture.events.onSleep = {
            fixture.pasteboard.simulateExternalWrite()
        }

        let result = await fixture.coordinator.performPaste(.text("selected"), into: fixture.target)

        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
    }

    func testExternalCopyDuringRestoreSuppressionIsNotOverwritten() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true
        fixture.suppression.onSuppress = {
            if fixture.suppression.count == 2 {
                fixture.pasteboard.simulateExternalWrite()
            }
        }

        let result = await fixture.coordinator.performPaste(.text("selected"), into: fixture.target)

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(fixture.events.postPasteCount, 1)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 0)
    }

    func testPasteReportsClipboardRestorationFailureAfterSuccessfulPost() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true
        fixture.pasteboard.restoreSucceeds = false

        let result = await fixture.coordinator.performPaste(.text("selected"), into: fixture.target)

        XCTAssertEqual(result, .pastedButClipboardRestoreFailed)
        XCTAssertEqual(fixture.events.postPasteCount, 1)
        XCTAssertEqual(fixture.pasteboard.restoreCount, 1)
        XCTAssertFalse(fixture.coordinator.isOperationInProgress)
    }

    func testCopyRejectsOverlappingCopyAndPasteBeforeReplacement() async {
        let fixture = makeFixture()
        fixture.suppression.onSuppress = {
            guard fixture.suppression.count == 1 else { return }
            XCTAssertTrue(fixture.coordinator.isOperationInProgress)
            let copyResult = await fixture.coordinator.copy(.text("second copy"))
            let pasteResult = await fixture.coordinator.performPaste(.text("second paste"), into: fixture.target)
            XCTAssertEqual(copyResult, .busy)
            XCTAssertEqual(pasteResult, .busy)
        }

        let result = await fixture.coordinator.copy(.text("first copy"))

        XCTAssertTrue(result.wasWritten)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 1)
        XCTAssertEqual(fixture.events.postPasteCount, 0)
        XCTAssertEqual(fixture.suppression.count, 1)
        XCTAssertFalse(fixture.coordinator.isOperationInProgress)
    }

    func testPasteRejectsOverlappingOperationsUntilOriginalClipboardIsRestored() async {
        let fixture = makeFixture()
        fixture.target.becomesActiveWhenActivated = true
        fixture.events.onSleepAsync = {
            guard fixture.events.postPasteCount == 1 else { return }
            XCTAssertTrue(fixture.coordinator.isOperationInProgress)
            let copyResult = await fixture.coordinator.copy(.text("second copy"))
            let pasteResult = await fixture.coordinator.performPaste(.text("second paste"), into: fixture.target)
            XCTAssertEqual(copyResult, .busy)
            XCTAssertEqual(pasteResult, .busy)
        }

        let result = await fixture.coordinator.performPaste(.text("first paste"), into: fixture.target)

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(fixture.pasteboard.replaceCount, 1)
        XCTAssertEqual(fixture.events.postPasteCount, 1)
        XCTAssertEqual(fixture.pasteboard.restoredSnapshots, fixture.pasteboard.originalSnapshot)
        XCTAssertFalse(fixture.coordinator.isOperationInProgress)
        let nextCopy = await fixture.coordinator.copy(.text("next copy"))
        XCTAssertTrue(nextCopy.wasWritten)
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

    func testSystemPasteboardNormalWriteKeepsOwnershipGeneration() throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("original", forType: .string))

        let ownershipChangeCount = pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertEqual(pasteboard.changeCount, ownershipChangeCount)

        let accessor = SystemPasteboardAccessor(pasteboard: pasteboard)
        let snapshot = try XCTUnwrap(accessor.snapshot().capturedValue)
        let result = accessor.replace(with: .text("replacement"), preserving: snapshot)

        XCTAssertEqual(result, .written(changeCount: pasteboard.changeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }

    func testSystemPasteboardWriteFailureDoesNotRestoreOverExternalCopy() throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var writeCount = 0
        let accessor = SystemPasteboardAccessor(
            pasteboard: pasteboard,
            writeObjects: { objects in
                writeCount += 1
                guard writeCount == 1 else { return pasteboard.writeObjects(objects) }
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("external copy", forType: .string))
                return false
            }
        )
        let snapshot = try XCTUnwrap(accessor.snapshot().capturedValue)

        let result = accessor.replace(with: .text("replacement"), preserving: snapshot)

        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "external copy")
    }

    func testSystemPasteboardWriteSuccessDoesNotClaimExternalCopy() throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var writeCount = 0
        let accessor = SystemPasteboardAccessor(
            pasteboard: pasteboard,
            writeObjects: { objects in
                writeCount += 1
                let didWrite = pasteboard.writeObjects(objects)
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("external copy", forType: .string))
                return didWrite
            }
        )
        let snapshot = try XCTUnwrap(accessor.snapshot().capturedValue)

        let result = accessor.replace(with: .text("replacement"), preserving: snapshot)

        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "external copy")
    }

    func testSystemPasteboardSnapshotRejectsAnUnreadableAdvertisedType() {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("original", forType: .string))
        XCTAssertTrue(item.setData(Data("representation".utf8), forType: .rtf))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let originalChangeCount = pasteboard.changeCount
        let accessor = SystemPasteboardAccessor(
            pasteboard: pasteboard,
            readData: { item, type in
                type == .rtf ? nil : item.data(forType: type)
            }
        )

        XCTAssertEqual(accessor.snapshot(), .unavailable)
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertTrue(pasteboard.pasteboardItems?.first?.types.contains(.rtf) == true)
    }

    func testSystemPasteboardSnapshotPreservesEmptyDataRepresentation() throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data(), forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let accessor = SystemPasteboardAccessor(pasteboard: pasteboard)

        let snapshot = try XCTUnwrap(accessor.snapshot().capturedValue)

        XCTAssertEqual(snapshot.items, [
            PasteboardItemSnapshot(values: [
                PasteboardTypeData(type: NSPasteboard.PasteboardType.string.rawValue, data: Data()),
            ]),
        ])
    }

    func testOwnedClipboardChangesKeepOnlySixteenGenerations() {
        let changes = ClipboardOwnedChanges()
        for generation in 1...32 { changes.record(generation) }
        for generation in 1...16 { XCTAssertFalse(changes.contains(generation)) }
        for generation in 17...32 { XCTAssertTrue(changes.contains(generation)) }

        for _ in 0..<32 { changes.record(32) }
        for generation in 17...32 { XCTAssertTrue(changes.contains(generation)) }
    }

    func testReaderIgnoresOwnedWriteAndRestoreButAcceptsImmediateExternalCopy() throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let changes = ClipboardOwnedChanges()
        let accessor = SystemPasteboardAccessor(pasteboard: pasteboard, ownedChanges: changes)
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceApplication: { ("com.yorozu.tests.source", "Test Source") }
        )
        let original = try XCTUnwrap(accessor.snapshot().capturedValue)

        XCTAssertTrue(accessor.replace(with: .text("injected"), preserving: original).wasWritten)
        XCTAssertTrue(changes.contains(pasteboard.changeCount))
        XCTAssertNil(reader.readSnapshot(
            excluding: [], expectedChangeCount: pasteboard.changeCount, ownedChanges: changes
        ))

        XCTAssertTrue(accessor.restore(original))
        XCTAssertTrue(changes.contains(pasteboard.changeCount))
        XCTAssertNil(reader.readSnapshot(
            excluding: [], expectedChangeCount: pasteboard.changeCount, ownedChanges: changes
        ))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external copy", forType: .string))
        let snapshot = try XCTUnwrap(reader.readSnapshot(
            excluding: [], expectedChangeCount: pasteboard.changeCount, ownedChanges: changes
        ))
        guard case let .string(text) = snapshot.content else {
            return XCTFail("Expected the external text snapshot")
        }
        XCTAssertEqual(text, "external copy")
    }

    func testReaderRejectsGenerationChangedBeforeMainActorRead() {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let expectedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new copy", forType: .string))
        var sourceReadCount = 0
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceApplication: {
                sourceReadCount += 1
                return ("com.yorozu.tests.source", "Test Source")
            }
        )

        XCTAssertNil(reader.readSnapshot(
            excluding: [], expectedChangeCount: expectedChangeCount,
            ownedChanges: ClipboardOwnedChanges()
        ))
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testReaderRejectsExternalGenerationChangedDuringRead() throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let expectedChangeCount = pasteboard.changeCount
        let changes = ClipboardOwnedChanges()
        var changesOnRead = true
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceApplication: {
                if changesOnRead {
                    changesOnRead = false
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("new copy", forType: .string))
                }
                return ("com.yorozu.tests.source", "Test Source")
            }
        )

        XCTAssertNil(reader.readSnapshot(
            excluding: [], expectedChangeCount: expectedChangeCount, ownedChanges: changes
        ))
        let snapshot = try XCTUnwrap(reader.readSnapshot(
            excluding: [], expectedChangeCount: pasteboard.changeCount, ownedChanges: changes
        ))
        guard case let .string(text) = snapshot.content else {
            return XCTFail("Expected the current external snapshot")
        }
        XCTAssertEqual(text, "new copy")
    }

    func testReaderRejectsOwnRestorationDuringRead() throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let changes = ClipboardOwnedChanges()
        let accessor = SystemPasteboardAccessor(pasteboard: pasteboard, ownedChanges: changes)
        let original = try XCTUnwrap(accessor.snapshot().capturedValue)
        let expectedChangeCount = pasteboard.changeCount
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceApplication: {
                XCTAssertTrue(accessor.restore(original))
                return ("com.yorozu.tests.source", "Test Source")
            }
        )

        XCTAssertNil(reader.readSnapshot(
            excluding: [], expectedChangeCount: expectedChangeCount, ownedChanges: changes
        ))
        XCTAssertTrue(changes.contains(pasteboard.changeCount))
    }

    func testMonitorRecordsExternalCopyImmediatelyAfterOwnWriteAndRestore() async throws {
        let pasteboard = NSPasteboard(name: .init("com.yorozu.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceApplication: { ("com.yorozu.tests.source", "Test Source") }
        )
        let settings = ClipboardRecordingSettings(
            isEnabled: true, isPaused: false, retentionDays: 30,
            maximumItems: 2_000, excludedBundleIdentifiers: []
        )
        let catalog = ClipboardCatalog(store: nil)
        var recordedTexts: [String] = []
        let monitor = ClipboardMonitor(
            reader: reader, settings: settings, catalog: catalog,
            onSnapshot: { recordedTexts = $0.values.compactMap(\.textContent) }
        )
        let accessor = SystemPasteboardAccessor(
            pasteboard: pasteboard, ownedChanges: monitor.ownedChanges
        )
        let original = try XCTUnwrap(accessor.snapshot().capturedValue)

        XCTAssertTrue(accessor.replace(with: .text("injected"), preserving: original).wasWritten)
        await monitor.poll(settings: settings)
        XCTAssertTrue(accessor.restore(original))
        await monitor.poll(settings: settings)
        XCTAssertTrue(recordedTexts.isEmpty)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external copy", forType: .string))
        await monitor.poll(settings: settings)
        for _ in 0..<100 where recordedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await monitor.stop()

        XCTAssertEqual(recordedTexts, ["external copy"])
        let items = await catalog.search(query: "")
        XCTAssertEqual(items.map(\.textContent), ["external copy"])
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
            postPasteShortcut: { processIdentifier in
                events.postPasteCount += 1
                events.postedProcessIdentifiers.append(processIdentifier)
                return events.postPasteSucceeds
            },
            sleep: { _ in
                events.sleepCount += 1
                events.onSleep?()
                await events.onSleepAsync?()
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
                await suppression.onSuppress?()
            },
            dependencies: dependencies
        )
        addTeardownBlock {
            await MainActor.run {
                events.onSleep = nil
                events.onSleepAsync = nil
                suppression.onSuppress = nil
                pasteboard.onSnapshot = nil
            }
        }
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
    let processIdentifier: pid_t = 4_242
    var activationSucceeds = true
    var becomesActiveWhenActivated = false
    var isActive = false
    var isFrontmost = false
    var isTerminated = false
    private(set) var activateCount = 0

    @discardableResult
    func activate() -> Bool {
        activateCount += 1
        if activationSucceeds && becomesActiveWhenActivated {
            isActive = true
            isFrontmost = true
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
    var restoreSucceeds = true
    var onSnapshot: (() -> Void)?

    func snapshot() -> PasteboardSnapshotResult {
        onSnapshot?()
        return snapshotResult ?? .captured(originalSnapshot)
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
        return restoreSucceeds
    }

    func simulateExternalWrite() {
        changeCount += 1
    }
}

@MainActor
private final class PasteEventSpy {
    let postPasteSucceeds: Bool
    var postPasteCount = 0
    var postedProcessIdentifiers: [pid_t] = []
    var sleepCount = 0
    var onSleep: (() -> Void)?
    var onSleepAsync: (() async -> Void)?

    init(postPasteSucceeds: Bool) {
        self.postPasteSucceeds = postPasteSucceeds
    }
}

@MainActor
private final class SuppressionSpy {
    var durations: [Duration] = []
    var onSuppress: (() async -> Void)?
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
