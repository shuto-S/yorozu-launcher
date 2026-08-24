import AppKit
import Sparkle

struct SoftwareUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL?
    let publicEDKey: String?

    init(feedURLString: String?, publicEDKey: String?) {
        let trimmedFeedURL = feedURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedFeedURL,
           let url = URL(string: trimmedFeedURL),
           url.scheme?.lowercased() == "https",
           url.host != nil {
            feedURL = url
        } else {
            feedURL = nil
        }

        let trimmedKey = publicEDKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedKey,
           !trimmedKey.isEmpty,
           !trimmedKey.contains("$("),
           let decodedKey = Data(base64Encoded: trimmedKey),
           decodedKey.count == 32 {
            self.publicEDKey = trimmedKey
        } else {
            self.publicEDKey = nil
        }
    }

    var isValid: Bool {
        feedURL != nil && publicEDKey != nil
    }
}

enum SoftwareUpdatePolicy {
    static func allowsUpdater(
        isDebugBuild: Bool,
        isUITesting: Bool,
        configuration: SoftwareUpdateConfiguration
    ) -> Bool {
        !isDebugBuild && !isUITesting && configuration.isValid
    }
}

@MainActor
final class AppUpdateController: NSObject {
    static let latestReleaseURL = URL(
        string: "https://github.com/shuto-S/yorozu-launcher/releases/latest"
    )!

    private let updaterController: SPUStandardUpdaterController?

    init(
        isDebugBuild: Bool,
        isUITesting: Bool,
        bundle: Bundle = .main
    ) {
        let configuration = SoftwareUpdateConfiguration(
            feedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        if SoftwareUpdatePolicy.allowsUpdater(
            isDebugBuild: isDebugBuild,
            isUITesting: isUITesting,
            configuration: configuration
        ) {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }
        super.init()
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates == true
    }

    func checkForUpdates() {
        guard let updaterController, updaterController.updater.canCheckForUpdates else {
            return
        }
        updaterController.checkForUpdates(nil)
    }

    func openLatestRelease() {
        NSWorkspace.shared.open(Self.latestReleaseURL)
    }
}
