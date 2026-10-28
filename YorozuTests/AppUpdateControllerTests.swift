import Combine
import XCTest
@testable import Yorozu

final class AppUpdateControllerTests: XCTestCase {
    private let validConfiguration = SoftwareUpdateConfiguration(
        feedURLString: "https://shuto-s.github.io/yorozu-launcher/appcast.xml",
        publicEDKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    )

    func testUpdaterIsAvailableOnlyInConfiguredNonTestReleaseBuilds() {
        let cases: [(name: String, isDebug: Bool, isUITesting: Bool, expected: Bool)] = [
            ("release", false, false, true),
            ("debug", true, false, false),
            ("UI test", false, true, false),
        ]
        for testCase in cases {
            XCTAssertEqual(
                SoftwareUpdatePolicy.allowsUpdater(
                    isDebugBuild: testCase.isDebug,
                    isUITesting: testCase.isUITesting,
                    configuration: validConfiguration
                ),
                testCase.expected,
                testCase.name
            )
        }

        XCTAssertFalse(SoftwareUpdatePolicy.allowsUpdater(
            isDebugBuild: false,
            isUITesting: false,
            configuration: SoftwareUpdateConfiguration(feedURLString: nil, publicEDKey: nil)
        ))
    }

    func testDebugTestHostDoesNotEmbedExternalUpdateConfiguration() {
        #if DEBUG
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey"))
        #endif
    }

    func testInvalidUpdateConfigurationsAreRejected() {
        let validFeed = "https://shuto-s.github.io/yorozu-launcher/appcast.xml"
        let validKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let cases: [(name: String, feed: String?, key: String?)] = [
            ("missing key", validFeed, nil),
            ("non-HTTPS feed", "http://example.com/appcast.xml", validKey),
            ("unexpanded build setting", validFeed, "$(YOROZU_SPARKLE_PUBLIC_KEY)"),
            ("short public key", validFeed, "dG9vLXNob3J0"),
        ]
        for testCase in cases {
            XCTAssertFalse(
                SoftwareUpdateConfiguration(
                    feedURLString: testCase.feed,
                    publicEDKey: testCase.key
                ).isValid,
                testCase.name
            )
        }
    }

    @MainActor
    func testUpdaterAvailabilityChangesArePublishedWithoutReopeningSettings() async {
        let availability = TestSoftwareUpdateAvailability(canCheckForUpdates: false)
        let controller = AppUpdateController(
            availabilitySource: availability,
            availabilityKeyPath: \.canCheckForUpdates,
            performUpdateCheck: {}
        )
        let becameAvailable = expectation(description: "Background check completed")
        let becameBusy = expectation(description: "Next update check started")
        var values: [Bool] = []
        let observation = controller.$canCheckForUpdates.sink { canCheck in
            values.append(canCheck)
            if values == [false, true] { becameAvailable.fulfill() }
            if values == [false, true, false] { becameBusy.fulfill() }
        }
        defer { observation.cancel() }

        XCTAssertTrue(controller.isUpdaterConfigured)
        availability.canCheckForUpdates = true
        await fulfillment(of: [becameAvailable], timeout: 1)
        XCTAssertTrue(controller.canCheckForUpdates)

        availability.canCheckForUpdates = false
        await fulfillment(of: [becameBusy], timeout: 1)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertTrue(controller.isUpdaterConfigured)
        XCTAssertEqual(values, [false, true, false])
    }

    @MainActor
    func testUpdateCheckPreparesPresentationBeforeSparkleAndRejectsCurrentBusyState() {
        let availability = TestSoftwareUpdateAvailability(canCheckForUpdates: true)
        var actions: [String] = []
        let controller = AppUpdateController(
            availabilitySource: availability,
            availabilityKeyPath: \.canCheckForUpdates,
            performUpdateCheck: { actions.append("check") },
            onWillCheckForUpdates: { actions.append("prepare") }
        )

        controller.checkForUpdates()
        XCTAssertEqual(actions, ["prepare", "check"])

        availability.canCheckForUpdates = false
        // The UI notification is queued, but a second invocation must already
        // respect Sparkle's current state and leave the palette alone.
        XCTAssertTrue(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(actions, ["prepare", "check"])
    }

    @MainActor
    func testUnconfiguredUpdaterNeverPreparesPresentationOrChecks() {
        var actions: [String] = []
        let controller = AppUpdateController(
            availabilitySource: nil as TestSoftwareUpdateAvailability?,
            availabilityKeyPath: \.canCheckForUpdates,
            performUpdateCheck: { actions.append("check") },
            onWillCheckForUpdates: { actions.append("prepare") }
        )

        controller.checkForUpdates()

        XCTAssertFalse(controller.isUpdaterConfigured)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertTrue(actions.isEmpty)
    }
}

private final class TestSoftwareUpdateAvailability: NSObject {
    @objc dynamic var canCheckForUpdates: Bool

    init(canCheckForUpdates: Bool) {
        self.canCheckForUpdates = canCheckForUpdates
        super.init()
    }
}
