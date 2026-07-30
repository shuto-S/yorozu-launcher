import Foundation

enum PaletteRoute: String, Hashable, Sendable {
    case root
    case clipboard
    case snippets
    case aliases
    case settings

    var searchPlaceholder: String {
        switch self {
        case .root:
            "Search for apps and commands…"
        case .clipboard:
            "Search Clipboard"
        case .snippets:
            "Search Snippets"
        case .aliases:
            "Search Aliases"
        case .settings:
            "Settings"
        }
    }

    var searchAccessibilityLabel: String {
        switch self {
        case .root:
            "Search applications and commands"
        case .clipboard:
            "Search clipboard history"
        case .snippets:
            "Search snippets"
        case .aliases:
            "Search application aliases"
        case .settings:
            "Settings"
        }
    }
}

enum PalettePresentationOrigin: Hashable, Sendable {
    case root
    case direct
}

enum FeatureCommand: String, Hashable, Sendable {
    case clipboardHistory
    case snippets
    case aliases
    case settings

    static let all: [FeatureCommand] = [
        .clipboardHistory,
        .snippets,
        .aliases,
        .settings,
    ]

    var title: String {
        switch self {
        case .clipboardHistory:
            "Clipboard History"
        case .snippets:
            "Snippets"
        case .aliases:
            "Aliases"
        case .settings:
            "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .clipboardHistory:
            "Search and paste recently copied content"
        case .snippets:
            "Create and paste reusable text"
        case .aliases:
            "Manage custom keywords for applications"
        case .settings:
            "Configure Yorozu"
        }
    }

    var symbolName: String {
        switch self {
        case .clipboardHistory:
            "clipboard"
        case .snippets:
            "text.quote"
        case .aliases:
            "character.cursor.ibeam"
        case .settings:
            "gearshape"
        }
    }

    var route: PaletteRoute {
        switch self {
        case .clipboardHistory:
            .clipboard
        case .snippets:
            .snippets
        case .aliases:
            .aliases
        case .settings:
            .settings
        }
    }

    var preferenceIdentity: ApplicationIdentity {
        ApplicationIdentity(rawValue: "feature:\(rawValue)")
    }

    init?(route: PaletteRoute) {
        switch route {
        case .root:
            return nil
        case .clipboard:
            self = .clipboardHistory
        case .snippets:
            self = .snippets
        case .aliases:
            self = .aliases
        case .settings:
            self = .settings
        }
    }
}

struct FeatureCommandState: Hashable, Sendable {
    let command: FeatureCommand
    var preference: LauncherPreference
}

struct CommandResultID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum CommandResultKind: Hashable, Sendable {
    case application
    case feature
    case clipboard
    case snippet
}

enum CommandIcon: Hashable, Sendable {
    case application(URL)
    case system(String)
}

enum ClipboardItemKind: String, Codable, Hashable, Sendable {
    case text
    case url
    case files
    case image
}

enum PasteboardContent: Hashable, Sendable {
    case text(String)
    case url(String)
    case files([String])
    case image(Data)

    var searchText: String {
        switch self {
        case let .text(value), let .url(value):
            value
        case let .files(paths):
            paths.joined(separator: " ")
        case .image:
            "image"
        }
    }
}

struct ClipboardItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: ClipboardItemKind
    let contentHash: String
    let textContent: String?
    let filePaths: [String]
    let imageData: Data?
    let imageByteCount: Int?
    let imageWidth: Int?
    let imageHeight: Int?
    let normalizedSearchText: String
    let sourceBundleIdentifier: String?
    let sourceApplicationName: String?
    var isPinned: Bool
    var pinnedAt: Date?
    var copiedAt: Date
    var updatedAt: Date

    var pasteboardContent: PasteboardContent {
        switch kind {
        case .text:
            .text(textContent ?? "")
        case .url:
            .url(textContent ?? "")
        case .files:
            .files(filePaths)
        case .image:
            .image(imageData ?? Data())
        }
    }

    var title: String {
        switch kind {
        case .text, .url:
            let value = textContent.map {
                String($0.prefix(240))
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            return value.isEmpty ? "Empty Clipboard Item" : value
        case .files:
            guard let first = filePaths.first else { return "Files" }
            let name = URL(fileURLWithPath: first).lastPathComponent
            return filePaths.count == 1 ? name : "\(name) and \(filePaths.count - 1) more"
        case .image:
            if let imageWidth, let imageHeight {
                return "Image (\(imageWidth)×\(imageHeight))"
            }
            return "Image"
        }
    }

    var kindLabel: String {
        switch kind {
        case .text:
            "Text"
        case .url:
            "URL"
        case .files:
            filePaths.count == 1 ? "File" : "\(filePaths.count) Files"
        case .image:
            "Image"
        }
    }
}

enum ClipboardStoragePolicy {
    // Full image payloads stay in SQLite and are loaded only for the selected
    // item. This cap prevents ordinary, unpinned history from growing without
    // bound when screenshots are copied frequently.
    static let maximumUnpinnedImageBytes = 256 * 1_024 * 1_024
}

struct ClipboardCapture: Hashable, Sendable {
    let id: UUID
    let kind: ClipboardItemKind
    let contentHash: String
    let textContent: String?
    let filePaths: [String]
    let imageData: Data?
    let imageWidth: Int?
    let imageHeight: Int?
    let normalizedSearchText: String
    let sourceBundleIdentifier: String?
    let sourceApplicationName: String?
    let copiedAt: Date
}

struct URLPreviewCacheEntry: Hashable, Sendable {
    let url: String
    let metadataData: Data
    let fetchedAt: Date
}

enum URLPreviewPolicy {
    nonisolated static func previewableURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !isLocalHost(host),
              !isPrivateIPAddress(host),
              let url = components.url else {
            return nil
        }
        return url
    }

    private nonisolated static func isLocalHost(_ host: String) -> Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
    }

    private nonisolated static func isPrivateIPAddress(_ host: String) -> Bool {
        let unwrappedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if unwrappedHost.contains(":") {
            return unwrappedHost == "::"
                || unwrappedHost == "::1"
                || unwrappedHost.hasPrefix("fc")
                || unwrappedHost.hasPrefix("fd")
                || unwrappedHost.hasPrefix("fe8")
                || unwrappedHost.hasPrefix("fe9")
                || unwrappedHost.hasPrefix("fea")
                || unwrappedHost.hasPrefix("feb")
        }

        let octets = unwrappedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]),
              octets.allSatisfy({ value in
                  guard let number = Int(value) else { return false }
                  return (0...255).contains(number)
              }) else {
            return false
        }

        return first == 0
            || first == 10
            || first == 127
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || first >= 224
    }
}

struct Snippet: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var keyword: String?
    var content: String
    var useCount: Int
    var lastUsedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    let normalizedSearchText: String

    init(
        id: UUID,
        name: String,
        keyword: String?,
        content: String,
        useCount: Int,
        lastUsedAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        normalizedSearchText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.content = content
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.normalizedSearchText = normalizedSearchText
            ?? [name, keyword, content]
                .compactMap { $0 }
                .joined(separator: " ")
                .launcherNormalized
    }

    var normalizedKeyword: String? {
        keyword?.launcherNormalized
    }

}

enum CommandPayload: Hashable, Sendable {
    case application(LaunchableApplication)
    case feature(FeatureCommand)
    case clipboard(ClipboardItem)
    case snippet(Snippet)
}

struct CommandResult: Identifiable, Hashable, Sendable {
    let id: CommandResultID
    let kind: CommandResultKind
    let title: String
    let subtitle: String
    let icon: CommandIcon
    let score: Int
    let payload: CommandPayload
}

struct FeatureSnapshot<Value: Sendable>: Sendable {
    let values: [Value]
    let storageAvailable: Bool
    let message: String?
}

enum SnippetValidationError: LocalizedError, Equatable {
    case invalidName
    case invalidContent
    case invalidKeyword
    case duplicateKeyword

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Name must be between 1 and 80 characters."
        case .invalidContent:
            "Content must be between 1 and 10,000 characters."
        case .invalidKeyword:
            "Keywords may contain only ASCII letters, numbers, semicolons, colons, underscores, and hyphens."
        case .duplicateKeyword:
            "This keyword is already used by another snippet."
        }
    }
}

extension Snippet {
    nonisolated static func validated(
        id: UUID = UUID(),
        name rawName: String,
        keyword rawKeyword: String,
        content rawContent: String,
        existing: Snippet? = nil,
        now: Date = Date()
    ) throws -> Snippet {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else {
            throw SnippetValidationError.invalidName
        }

        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...10_000).contains(content.count) else {
            throw SnippetValidationError.invalidContent
        }

        let trimmedKeyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = trimmedKeyword.isEmpty ? nil : trimmedKeyword
        if let keyword {
            guard keyword.count <= 64,
                  keyword.unicodeScalars.allSatisfy({
                          $0.isASCII
                              && (CharacterSet.alphanumerics.contains($0)
                              || CharacterSet(charactersIn: ";:_-").contains($0))
                  }) else {
                throw SnippetValidationError.invalidKeyword
            }
        }

        return Snippet(
            id: existing?.id ?? id,
            name: name,
            keyword: keyword,
            content: content,
            useCount: existing?.useCount ?? 0,
            lastUsedAt: existing?.lastUsedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }
}
