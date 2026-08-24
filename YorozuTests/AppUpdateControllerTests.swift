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
}
