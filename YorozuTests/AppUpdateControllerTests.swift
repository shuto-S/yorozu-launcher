import Combine
import XCTest
@testable import Yorozu

final class AppUpdateControllerTests: XCTestCase {
    private let validConfiguration = SoftwareUpdateConfiguration(
        feedURLString: "https://shuto-s.github.io/yorozu-launcher/appcast.xml",
        publicEDKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    )

    func testReleaseBuildWithValidConfigurationAllowsUpdater() {
        XCTAssertTrue(SoftwareUpdatePolicy.allowsUpdater(
            isDebugBuild: false,
            isUITesting: false,
            configuration: validConfiguration
        ))
    }

    func testDebugBuildNeverAllowsUpdater() {
        XCTAssertFalse(SoftwareUpdatePolicy.allowsUpdater(
            isDebugBuild: true,
            isUITesting: false,
            configuration: validConfiguration
        ))
    }

    func testUITestingNeverAllowsUpdater() {
        XCTAssertFalse(SoftwareUpdatePolicy.allowsUpdater(
            isDebugBuild: false,
            isUITesting: true,
            configuration: validConfiguration
        ))
    }

    func testDebugTestHostDoesNotEmbedExternalUpdateConfiguration() {
        #if DEBUG
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey"))
        #endif
    }

    func testMissingPublicKeyRejectsConfiguration() {
        let configuration = SoftwareUpdateConfiguration(
            feedURLString: "https://shuto-s.github.io/yorozu-launcher/appcast.xml",
            publicEDKey: nil
        )

        XCTAssertFalse(configuration.isValid)
    }

    func testNonHTTPSFeedRejectsConfiguration() {
        let configuration = SoftwareUpdateConfiguration(
            feedURLString: "http://example.com/appcast.xml",
            publicEDKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        )

        XCTAssertFalse(configuration.isValid)
    }

    func testUnexpandedBuildSettingRejectsConfiguration() {
        let configuration = SoftwareUpdateConfiguration(
            feedURLString: "https://shuto-s.github.io/yorozu-launcher/appcast.xml",
            publicEDKey: "$(YOROZU_SPARKLE_PUBLIC_KEY)"
        )

        XCTAssertFalse(configuration.isValid)
    }

    func testPublicKeyMustDecodeToThirtyTwoBytes() {
        let configuration = SoftwareUpdateConfiguration(
            feedURLString: "https://shuto-s.github.io/yorozu-launcher/appcast.xml",
            publicEDKey: "dG9vLXNob3J0"
        )

        XCTAssertFalse(configuration.isValid)
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
