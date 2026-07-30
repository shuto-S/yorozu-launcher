import Foundation

struct ApplicationIdentity: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct LauncherPreference: Hashable, Sendable {
    var alias: String?
    var isPinned: Bool
    var pinnedAt: Date?
    var launchCount: Int
    var lastLaunchedAt: Date?

    nonisolated static let empty = LauncherPreference(
        alias: nil,
        isPinned: false,
        pinnedAt: nil,
        launchCount: 0,
        lastLaunchedAt: nil
    )
}

struct DiscoveredApplication: Identifiable, Hashable, Sendable {
    let id: ApplicationIdentity
    let bundleIdentifier: String?
    let canonicalURL: URL
    let displayName: String
    let localizedName: String?
    let version: String?
    let normalizedSearchText: String
    let rootPriority: Int
}

struct LaunchableApplication: Identifiable, Hashable, Sendable {
    let id: ApplicationIdentity
    let bundleIdentifier: String?
    let canonicalURL: URL
    let displayName: String
    let localizedName: String?
    let version: String?
    var preference: LauncherPreference
    let primarySearchField: ApplicationSearchField
    let displaySearchField: ApplicationSearchField
    let bundleSearchField: ApplicationSearchField?

    init(
        id: ApplicationIdentity,
        bundleIdentifier: String?,
        canonicalURL: URL,
        displayName: String,
        localizedName: String?,
        version: String?,
        preference: LauncherPreference
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.canonicalURL = canonicalURL
        self.displayName = displayName
        self.localizedName = localizedName
        self.version = version
        self.preference = preference
        primarySearchField = ApplicationSearchField(rawValue: localizedName ?? displayName)
        displaySearchField = ApplicationSearchField(rawValue: displayName)
        bundleSearchField = bundleIdentifier.map(ApplicationSearchField.init(rawValue:))
    }

    var primaryName: String {
        localizedName ?? displayName
    }

    var subtitle: String {
        if let alias = preference.alias {
            return "\(alias) · \(bundleIdentifier ?? canonicalURL.path)"
        }
        return bundleIdentifier ?? canonicalURL.path
    }
}

struct ApplicationSearchField: Hashable, Sendable {
    let value: String
    let words: [String]
    let acronym: String
    let characters: [Character]

    init(rawValue: String) {
        let normalizedValue = rawValue.launcherNormalized
        value = normalizedValue
        words = normalizedValue
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        acronym = String(words.compactMap(\.first))
        characters = Array(normalizedValue)
    }
}

struct CatalogSnapshot: Sendable {
    let applications: [LaunchableApplication]
    let lastIndexedAt: Date?
    let storageAvailable: Bool
    let message: String?
}

struct SearchQuery: Hashable, Sendable {
    let rawValue: String
}

struct SearchContext: Hashable, Sendable {
    let frontmostApplicationBundleIdentifier: String?
}

struct CommandProviderID: RawRepresentable, Hashable, Sendable {
    let rawValue: String
}

struct CommandActionID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    nonisolated static let open = Self(rawValue: "open")
    nonisolated static let togglePin = Self(rawValue: "toggle-pin")
    nonisolated static let editAlias = Self(rawValue: "edit-alias")
    nonisolated static let revealInFinder = Self(rawValue: "reveal-in-finder")
}

struct CommandAction: Identifiable, Hashable, Sendable {
    let id: CommandActionID
    let title: String
    let systemImageName: String
}

protocol CommandProvider: Sendable {
    var id: CommandProviderID { get }
    func search(query: SearchQuery, context: SearchContext) async -> [CommandResult]
    func actions(for result: CommandResult) async -> [CommandAction]
    func perform(action: CommandActionID, result: CommandResult) async throws
}

protocol ApplicationDiscovering: Sendable {
    func discoverApplications() async throws -> [DiscoveredApplication]
}

@MainActor
protocol ApplicationLaunching: AnyObject {
    func launch(_ application: LaunchableApplication) async throws
    func revealInFinder(_ application: LaunchableApplication)
}

enum LauncherError: LocalizedError {
    case applicationUnavailable(String)
    case invalidAlias
    case aliasStorageUnavailable
    case aliasCouldNotBeSaved
    case commandNotSupported

    var errorDescription: String? {
        switch self {
        case let .applicationUnavailable(name):
            return "\(name) could not be found or opened."
        case .invalidAlias:
            return "Enter an alias between 1 and 64 characters."
        case .aliasStorageUnavailable:
            return "Alias storage is unavailable."
        case .aliasCouldNotBeSaved:
            return "The alias could not be saved. Try again."
        case .commandNotSupported:
            return "This action is not available yet."
        }
    }
}

extension String {
    nonisolated var launcherNormalized: String {
        let compatibilityNormalized = precomposedStringWithCompatibilityMapping
        let folded = compatibilityNormalized.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
        return folded
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
