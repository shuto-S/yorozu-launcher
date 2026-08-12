import Darwin
import Foundation

enum PaletteRoute: Hashable, Sendable {
    case root
    case translation
    case clipboard
    case snippets
    case aliases
    case ai(providerID: AIProviderID)
    case settings

    var searchPlaceholder: String {
        switch self {
        case .root:
            "Search for apps and commands…"
        case .translation:
            "Translate"
        case .clipboard:
            "Search Clipboard"
        case .snippets:
            "Search Snippets"
        case .aliases:
            "Search Aliases"
        case .ai:
            "Search Chats"
        case .settings:
            "Settings"
        }
    }

    var searchAccessibilityLabel: String {
        switch self {
        case .root:
            "Search applications and commands"
        case .translation:
            "Translation input"
        case .clipboard:
            "Search clipboard history"
        case .snippets:
            "Search snippets"
        case .aliases:
            "Search application aliases"
        case .ai:
            "Search AI chats"
        case .settings:
            "Settings"
        }
    }

    var aiProviderID: AIProviderID? {
        guard case let .ai(providerID) = self else { return nil }
        return providerID
    }

    var isAI: Bool { aiProviderID != nil }
}

enum PalettePresentationOrigin: Hashable, Sendable {
    case root
    case direct
}

enum FeatureCommand: Hashable, Sendable {
    case translation
    case clipboardHistory
    case snippets
    case aliases
    case aiCodex
    case aiOpenAI
    case aiClaude
    case settings

    static let all: [FeatureCommand] = [
        .translation,
        .clipboardHistory,
        .snippets,
        .aliases,
        .aiCodex,
        .aiOpenAI,
        .aiClaude,
        .settings,
    ]

    var title: String {
        switch self {
        case .translation:
            "Translate"
        case .clipboardHistory:
            "Clipboard History"
        case .snippets:
            "Snippets"
        case .aliases:
            "Aliases"
        case .aiCodex:
            "AI Chat: Codex"
        case .aiOpenAI:
            "AI Chat: OpenAI"
        case .aiClaude:
            "AI Chat: Claude"
        case .settings:
            "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .translation:
            "Translate text with your configured AI provider"
        case .clipboardHistory:
            "Search and paste recently copied content"
        case .snippets:
            "Create and paste reusable text"
        case .aliases:
            "Manage custom keywords for applications"
        case .aiCodex:
            "Uses your ChatGPT plan through Codex"
        case .aiOpenAI:
            "Uses API credits and usage-based billing"
        case .aiClaude:
            "Uses Anthropic API credits and usage-based billing"
        case .settings:
            "Configure Yorozu"
        }
    }

    var symbolName: String {
        switch self {
        case .translation:
            "character.bubble"
        case .clipboardHistory:
            "clipboard"
        case .snippets:
            "text.quote"
        case .aliases:
            "character.cursor.ibeam"
        case .aiCodex:
            "terminal"
        case .aiOpenAI:
            "sparkles"
        case .aiClaude:
            "bubble.left.and.bubble.right"
        case .settings:
            "gearshape"
        }
    }

    var route: PaletteRoute {
        switch self {
        case .translation:
            .translation
        case .clipboardHistory:
            .clipboard
        case .snippets:
            .snippets
        case .aliases:
            .aliases
        case .aiCodex:
            .ai(providerID: .codex)
        case .aiOpenAI:
            .ai(providerID: .openAIAPI)
        case .aiClaude:
            .ai(providerID: .claude)
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
        case .translation:
            self = .translation
        case .clipboard:
            self = .clipboardHistory
        case .snippets:
            self = .snippets
        case .aliases:
            self = .aliases
        case let .ai(providerID):
            switch providerID {
            case .codex:
                self = .aiCodex
            case .openAIAPI:
                self = .aiOpenAI
            case .claude:
                self = .aiClaude
            default:
                return nil
            }
        case .settings:
            self = .settings
        }
    }

    var providerID: AIProviderID? {
        switch self {
        case .aiCodex: .codex
        case .aiOpenAI: .openAIAPI
        case .aiClaude: .claude
        default: nil
        }
    }

    var rawValue: String {
        switch self {
        case .translation: "translation"
        case .clipboardHistory: "clipboardHistory"
        case .snippets: "snippets"
        case .aliases: "aliases"
        case .aiCodex: "aiChat.codex"
        case .aiOpenAI: "aiChat.openai_api"
        case .aiClaude: "aiChat.claude"
        case .settings: "settings"
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
    case calculation
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
    var lastUsedAt: Date? = nil
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
    static let maximumPinnedItems = 500
    static let maximumPinnedImageBytes = 256 * 1_024 * 1_024
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
              isAllowedHostLiteral(host),
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

    nonisolated static func isPublicIPAddress(_ address: String) -> Bool {
        let unwrappedHost = address
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        var ipv4 = in_addr()
        if inet_pton(AF_INET, unwrappedHost, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { bytes in
                let octets = Array(bytes)
                let first = Int(octets[0])
                let second = Int(octets[1])
                return first != 0
                    && first != 10
                    && first != 127
                    && !(first == 100 && (64...127).contains(second))
                    && !(first == 169 && second == 254)
                    && !(first == 172 && (16...31).contains(second))
                    && !(first == 192 && second == 0)
                    && !(first == 192 && second == 168)
                    && !(first == 198 && (18...19).contains(second))
                    && !(first == 192 && second == 0 && octets[2] == 2)
                    && !(first == 198 && second == 51 && octets[2] == 100)
                    && !(first == 203 && second == 0 && octets[2] == 113)
                    && first < 224
            }
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, unwrappedHost, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { rawBytes in
                let bytes = Array(rawBytes)
                let isUnspecified = bytes.allSatisfy { $0 == 0 }
                let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 }
                    && bytes.last == 1
                let isUniqueLocal = bytes[0] & 0xFE == 0xFC
                let isLinkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
                let isMulticast = bytes[0] == 0xFF
                let isDocumentation = bytes[0...3] == [0x20, 0x01, 0x0D, 0xB8]
                if isUnspecified || isLoopback || isUniqueLocal || isLinkLocal
                    || isMulticast || isDocumentation {
                    return false
                }
                let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 }
                    && bytes[10] == 0xFF
                    && bytes[11] == 0xFF
                if isIPv4Mapped {
                    return isPublicIPAddress(
                        "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
                    )
                }
                return true
            }
        }
        return false
    }

    private nonisolated static func isAllowedHostLiteral(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return isPublicIPAddress(host)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return isPublicIPAddress(host)
        }
        if host.contains(":")
            || host.unicodeScalars.allSatisfy({
                CharacterSet.decimalDigits.contains($0) || $0 == "."
            }) {
            return false
        }
        return true
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
    case calculation(expression: String, result: String)
    case calculationError(expression: String, message: String)
    case clipboard(UUID)
    case snippet(UUID)
}

struct CommandResult: Identifiable, Hashable, Sendable {
    let id: CommandResultID
    let kind: CommandResultKind
    let title: String
    let subtitle: String
    let icon: CommandIcon
    let score: Int
    let isPinned: Bool
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

        guard !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawContent.count <= 10_000 else {
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
            content: rawContent,
            useCount: existing?.useCount ?? 0,
            lastUsedAt: existing?.lastUsedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }
}
