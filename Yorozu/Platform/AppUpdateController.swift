import AppKit
import Combine
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
final class AppUpdateController: NSObject, ObservableObject {
    static let latestReleaseURL = URL(
        string: "https://github.com/shuto-S/yorozu-launcher/releases/latest"
    )!

    let isUpdaterConfigured: Bool
    @Published private(set) var canCheckForUpdates: Bool
    private let currentAvailability: @MainActor () -> Bool
    private let performUpdateCheck: @MainActor () -> Void
    private let onWillCheckForUpdates: @MainActor () -> Void
    private var availabilityObservation: NSKeyValueObservation?

    convenience init(
        isDebugBuild: Bool,
        isUITesting: Bool,
        bundle: Bundle = .main,
        onWillCheckForUpdates: @escaping @MainActor () -> Void = {}
    ) {
        let configuration = SoftwareUpdateConfiguration(
            feedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        let updaterController: SPUStandardUpdaterController?
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
        self.init(
            availabilitySource: updaterController?.updater,
            availabilityKeyPath: \SPUUpdater.canCheckForUpdates,
            performUpdateCheck: { updaterController?.checkForUpdates(nil) },
            onWillCheckForUpdates: onWillCheckForUpdates
        )
    }

    // Keeping the observable source injectable lets tests drive Sparkle's KVO
    // contract without starting its network or installation services.
    init<Source: NSObject>(
        availabilitySource: Source?,
        availabilityKeyPath: KeyPath<Source, Bool>,
        performUpdateCheck: @escaping @MainActor () -> Void,
        onWillCheckForUpdates: @escaping @MainActor () -> Void = {}
    ) {
        isUpdaterConfigured = availabilitySource != nil
        canCheckForUpdates = availabilitySource?[keyPath: availabilityKeyPath] == true
        currentAvailability = {
            availabilitySource?[keyPath: availabilityKeyPath] == true
        }
        self.performUpdateCheck = performUpdateCheck
        self.onWillCheckForUpdates = onWillCheckForUpdates
        super.init()
        availabilityObservation = availabilitySource?.observe(
            availabilityKeyPath,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Coalesce queued changes to the live value so delayed KVO
                // delivery cannot restore an obsolete availability state.
                self.canCheckForUpdates = self.currentAvailability()
            }
        }
    }

    func checkForUpdates() {
        // KVO delivery to SwiftUI may still be queued. Gate on the current
        // updater state before hiding the palette or asking Sparkle to present UI.
        guard isUpdaterConfigured, currentAvailability() else { return }
        onWillCheckForUpdates()
        performUpdateCheck()
    }

    func openLatestRelease() {
        NSWorkspace.shared.open(Self.latestReleaseURL)
    }
}
