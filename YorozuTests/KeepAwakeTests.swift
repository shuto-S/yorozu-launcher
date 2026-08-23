import Foundation
import XCTest
@testable import Yorozu

@MainActor
final class KeepAwakeTests: XCTestCase {
    func testDurationChoicesCoverInfinityAndFiveMinuteStepsThroughFourHours() {
        XCTAssertEqual(KeepAwakeDuration.choices.first, .untilTurnedOff)
        XCTAssertEqual(KeepAwakeDuration.choices.dropFirst().first, .minutes(5))
        XCTAssertEqual(KeepAwakeDuration.choices.last, .minutes(240))
        XCTAssertEqual(KeepAwakeDuration.choices.count, 49)
    }

    func testInvalidStoredDurationFallsBackToThirtyMinutes() {
        XCTAssertEqual(KeepAwakeDuration(storedValue: 7), .minutes(30))
        XCTAssertEqual(KeepAwakeDuration(storedValue: 245), .minutes(30))
        XCTAssertEqual(KeepAwakeDuration(storedValue: 0), .untilTurnedOff)
    }

    func testStartingAndStoppingBalancesSleepActivity() {
        let fixture = makeFixture()

        fixture.controller.start(for: .minutes(30))
        XCTAssertTrue(fixture.controller.isActive)
        XCTAssertEqual(fixture.manager.beginCount, 1)
        XCTAssertEqual(fixture.manager.endCount, 0)

        fixture.controller.stop()
        XCTAssertFalse(fixture.controller.isActive)
        XCTAssertEqual(fixture.manager.endCount, 1)
    }

    func testStartingAnotherDurationReplacesExistingActivity() {
        let fixture = makeFixture()

        fixture.controller.start(for: .minutes(30))
        fixture.controller.start(for: .untilTurnedOff)

        XCTAssertEqual(fixture.manager.beginCount, 2)
        XCTAssertEqual(fixture.manager.endCount, 1)
        XCTAssertEqual(fixture.controller.activeDuration, .untilTurnedOff)
        XCTAssertNil(fixture.controller.expirationDate)
    }

    func testFiniteSessionStopsAfterReconciliationPastDeadline() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = makeFixture(now: { now })
        fixture.controller.start(for: .minutes(5))

        now = now.addingTimeInterval(301)
        fixture.controller.reconcileExpiration()

        XCTAssertFalse(fixture.controller.isActive)
        XCTAssertEqual(fixture.manager.endCount, 1)
    }

    func testUntilTurnedOffDoesNotExpireWhenReconciled() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = makeFixture(now: { now })
        fixture.controller.start(for: .untilTurnedOff)

        now = now.addingTimeInterval(24 * 60 * 60)
        fixture.controller.reconcileExpiration()

        XCTAssertTrue(fixture.controller.isActive)
        XCTAssertEqual(fixture.manager.endCount, 0)
    }

    func testPreferencesPersistButActiveSessionDoesNot() {
        let suiteName = "com.yorozu.tests.keep-awake." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let firstManager = FakeSleepActivityManager()
        let first = KeepAwakeController(
            defaults: defaults,
            activityManager: firstManager,
            observesSystemNotifications: false
        )
        first.defaultDuration = .minutes(75)
        first.showsSeparateMenuBarIcon = true
        first.start(for: .minutes(5))

        let restarted = KeepAwakeController(
            defaults: defaults,
            activityManager: FakeSleepActivityManager(),
            observesSystemNotifications: false
        )

        XCTAssertEqual(restarted.defaultDuration, .minutes(75))
        XCTAssertTrue(restarted.showsSeparateMenuBarIcon)
        XCTAssertFalse(restarted.isActive)
        first.invalidate()
        restarted.invalidate()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeFixture(
        now: @escaping () -> Date = Date.init
    ) -> (controller: KeepAwakeController, manager: FakeSleepActivityManager) {
        let suiteName = "com.yorozu.tests.keep-awake." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = FakeSleepActivityManager()
        let controller = KeepAwakeController(
            defaults: defaults,
            activityManager: manager,
            now: now,
            observesSystemNotifications: false
        )
        addTeardownBlock {
            controller.invalidate()
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (controller, manager)
    }
}

@MainActor
private final class FakeSleepActivityManager: SleepActivityManaging {
    private final class Token: NSObject {}
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginPreventingIdleSleep(reason: String) -> NSObjectProtocol {
        beginCount += 1
        return Token()
    }

    func endPreventingIdleSleep(_ token: NSObjectProtocol) {
        endCount += 1
    }
}
