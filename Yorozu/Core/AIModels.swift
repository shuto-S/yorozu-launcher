import Foundation

struct AIProviderID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    static let codex = AIProviderID(rawValue: "codex")
    static let openAIAPI = AIProviderID(rawValue: "openai_api")
}

struct AIProviderCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: UInt

    static let authentication = Self(rawValue: 1 << 0)
    static let modelSelection = Self(rawValue: 1 << 1)
    static let streaming = Self(rawValue: 1 << 2)
    static let attachments = Self(rawValue: 1 << 3)
    static let webSearch = Self(rawValue: 1 << 4)
    static let archive = Self(rawValue: 1 << 5)
    static let deletion = Self(rawValue: 1 << 6)
    static let rateLimitStatus = Self(rawValue: 1 << 7)
}

struct AIProviderDescriptor: Hashable, Sendable, Identifiable {
    let id: AIProviderID
    let displayName: String
    let rootCommandTitle: String
    let description: String
    let symbolName: String
    let capabilities: AIProviderCapabilities
}

enum AIProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

enum AIAuthenticationState: Equatable, Sendable {
    case checking
    case authenticated(detail: String?)
    case authenticationRequired
    case failed(message: String)
}

struct AIConversationReference: Hashable, Codable, Sendable {
    let providerID: AIProviderID
    let providerConversationID: String
}

enum AIChatListScope: String, CaseIterable, Sendable {
    case active
    case archived
}

enum AIChatDestination: Hashable, Sendable {
    case list(AIChatListScope)
    case newChat
    case conversation(String)
}

struct AIModel: Hashable, Codable, Identifiable, Sendable {
    let rawValue: String
    let title: String
    let detail: String
    let isDefault: Bool

    var id: String { rawValue }

    init(
        rawValue: String,
        title: String? = nil,
        detail: String? = nil,
        isDefault: Bool? = nil
    ) {
        self.rawValue = rawValue
        self.title = title ?? Self.knownTitle(for: rawValue) ?? rawValue
        self.detail = detail ?? Self.knownDetail(for: rawValue) ?? ""
        self.isDefault = isDefault
            ?? Self.openAIModels.first(where: { $0.rawValue == rawValue })?.isDefault
            ?? false
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        if let knownModel = Self.openAIModels.first(where: { $0.rawValue == rawValue }) {
            self = knownModel
        } else {
            self.init(rawValue: rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let terra = AIModel(
        rawValue: "gpt-5.6-terra",
        title: "GPT-5.6 Terra",
        detail: "Balanced intelligence and cost",
        isDefault: true
    )
    static let sol = AIModel(
        rawValue: "gpt-5.6-sol",
        title: "GPT-5.6 Sol",
        detail: "Best for complex professional work",
        isDefault: false
    )
    static let luna = AIModel(
        rawValue: "gpt-5.6-luna",
        title: "GPT-5.6 Luna",
        detail: "Fast and cost-efficient",
        isDefault: false
    )
    static let openAIModels = [terra, sol, luna]

    private static func knownTitle(for rawValue: String) -> String? {
        openAIModels.first(where: { $0.rawValue == rawValue })?.title
    }

    private static func knownDetail(for rawValue: String) -> String? {
        openAIModels.first(where: { $0.rawValue == rawValue })?.detail
    }
}

enum AICredentialStatus: Equatable, Sendable {
    case checking
    case saved
    case notSaved
    case unavailable
}

enum AIConversationDeletionState: String, Codable, Sendable {
    case pending
    case failed
}

struct AIConversationSummary: Identifiable, Hashable, Sendable {
    let providerID: AIProviderID
    let providerConversationID: String
    var title: String
    var model: AIModel
    var isArchived: Bool
    var deletionState: AIConversationDeletionState?
    let createdAt: Date
    var lastMessageAt: Date
    var updatedAt: Date

    var id: String { providerConversationID }
    var reference: AIConversationReference {
        AIConversationReference(
            providerID: providerID,
            providerConversationID: providerConversationID
        )
    }

    static func title(from prompt: String) -> String {
        let line = prompt
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "New Chat"
        return String(line.prefix(60))
    }
}

struct AIChatCitation: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let url: URL
    let startIndex: Int?
    let endIndex: Int?
}

enum AIChatCitationFormatter {
    static func markdown(
        text: String,
        citations: [AIChatCitation]
    ) -> String {
        guard !citations.isEmpty else { return text }

        let source = text as NSString
        let indexedCitations = citations.enumerated().map { offset, citation in
            (number: offset + 1, citation: citation)
        }
        let positioned = indexedCitations.compactMap { item -> (Int, Int, URL)? in
            guard let endIndex = item.citation.endIndex,
                  (0...source.length).contains(endIndex) else {
                return nil
            }
            return (endIndex, item.number, item.citation.url)
        }
        let positionedNumbers = Set(positioned.map(\.1))
        var result = text

        for (endIndex, number, url) in positioned.sorted(by: { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1 > rhs.1
        }) {
            let insertionIndex = String.Index(
                utf16Offset: endIndex,
                in: result
            )
            result.insert(
                contentsOf: inlineMarker(number: number, url: url),
                at: insertionIndex
            )
        }

        let unpositioned = indexedCitations.filter {
            !positionedNumbers.contains($0.number)
        }
        if !unpositioned.isEmpty {
            if !result.isEmpty {
                result += " "
            }
            result += unpositioned.map {
                inlineMarker(number: $0.number, url: $0.citation.url)
            }.joined(separator: " ")
        }
        return result
    }

    private static func inlineMarker(number: Int, url: URL) -> String {
        " [[\(number)]](<\(url.absoluteString)>)"
    }
}

enum AIChatMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct AIChatAttachment: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case image
        case file
    }

    let id: String
    let kind: Kind
    let filename: String
    let fileID: String?
    let localURL: URL?
    let byteCount: Int?
}

struct AIChatMessage: Identifiable, Hashable, Sendable {
    let id: String
    let role: AIChatMessageRole
    var text: String
    var citations: [AIChatCitation]
    var attachments: [AIChatAttachment]
    var isStreaming: Bool
}

struct AIConversationPage: Sendable {
    let messages: [AIChatMessage]
    let nextCursor: String?
    let hasMore: Bool
}

enum AIChatStreamEvent: Sendable {
    case responseCreated(String)
    case webSearchStarted
    case textDelta(String)
    case citation(AIChatCitation)
    case completed
}

struct AIUploadedAttachment: Hashable, Sendable {
    let kind: AIChatAttachment.Kind
    let filename: String
    let fileID: String
}

struct AIChatSendRequest: Sendable {
    let conversationID: String
    let model: AIModel
    let prompt: String
    let attachments: [AIUploadedAttachment]
    let enablesWebSearch: Bool
    let clientRequestID: String
}

struct OpenAIRequestDiagnostics: Equatable, Sendable {
    let clientRequestID: String
    let serverRequestID: String?
}

enum AIChatError: LocalizedError, Equatable {
    case providerDisabled
    case providerUnavailable
    case authenticationRequired
    case missingAPIKey
    case authenticationFailed
    case modelUnavailable
    case invalidAttachment
    case attachmentLimitExceeded
    case quotaExceeded
    case rateLimited
    case serverUnavailable
    case requestTimedOut
    case apiFailure(code: String?)
    case streamProtocolError
    case streamTransportError(code: Int)
    case requestFailed(statusCode: Int)
    case invalidResponse
    case conversationUnavailable
    case deletionFailed
    case offline
    case codexNotInstalled
    case unsupportedCodexVersion
    case loginCanceled
    case appServerTerminated
    case protocolError

    var errorDescription: String? {
        switch self {
        case .providerDisabled:
            "This AI provider is currently disabled."
        case .providerUnavailable:
            "This AI provider is currently unavailable."
        case .authenticationRequired:
            "Sign in or add credentials to use this AI provider."
        case .missingAPIKey:
            "Add your OpenAI API key in Settings."
        case .authenticationFailed:
            "The OpenAI API key could not be authenticated."
        case .modelUnavailable:
            "The selected model is not available for this API key."
        case .invalidAttachment:
            "One or more attachments are not supported."
        case .attachmentLimitExceeded:
            "Attach up to 5 files with a combined size below 50 MB."
        case .quotaExceeded:
            "OpenAI API credits are unavailable. Check billing and usage limits."
        case .rateLimited:
            "OpenAI is receiving too many requests. Wait a moment and try again."
        case .serverUnavailable:
            "OpenAI is temporarily unavailable. Try again in a moment."
        case .requestTimedOut:
            "The OpenAI request timed out. Check your connection and try again."
        case let .apiFailure(code):
            if let code {
                "OpenAI could not complete this request (\(code))."
            } else {
                "OpenAI could not complete this request."
            }
        case .streamProtocolError:
            "Yorozu could not read the OpenAI response stream."
        case let .streamTransportError(code):
            "The OpenAI response stream ended unexpectedly (\(code))."
        case let .requestFailed(statusCode):
            "OpenAI returned an error (\(statusCode))."
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .conversationUnavailable:
            "This conversation is no longer available."
        case .deletionFailed:
            "The chat could not be completely deleted. Try again."
        case .offline:
            "Connect to the internet and try again."
        case .codexNotInstalled:
            "Codex is not installed. Install or select the Codex executable to continue."
        case .unsupportedCodexVersion:
            "The installed Codex version does not support Yorozu."
        case .loginCanceled:
            "ChatGPT sign-in was canceled."
        case .appServerTerminated:
            "Codex stopped unexpectedly. Try again."
        case .protocolError:
            "Yorozu could not read the Codex app-server response."
        }
    }
}

protocol AIChatProvider: Sendable {
    var descriptor: AIProviderDescriptor { get }

    func availability() async -> AIProviderAvailability
    func authenticationState() async -> AIAuthenticationState
    func availableModels() async throws -> [AIModel]
    func createConversation(title: String, model: AIModel) async throws -> String
    func updateConversation(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws
    func setConversationArchived(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws
    func loadConversation(
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage
    func uploadAttachment(_ attachment: AIChatAttachment) async throws -> AIUploadedAttachment
    func streamResponse(
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error>
    func stopGeneration(conversationID: String) async
    func deleteConversationCompletely(conversationID: String) async throws
    func shutdown() async
}

extension AIChatProvider {
    func setConversationArchived(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        throw AIChatError.providerUnavailable
    }
}

protocol OpenAIAPIKeyManaging: Sendable {
    func hasAPIKey() async throws -> Bool
    func saveAPIKey(_ value: String) async throws
    func removeAPIKey() async throws
}

protocol CodexAuthenticationManaging: Sendable {
    func signInWithChatGPT() async throws -> URL
    func cancelSignIn() async
    func signOut() async throws
    func accountPlanType() async throws -> String?
    func rateLimitSummary() async throws -> String?
    func executablePath() async -> String?
    func updateExecutablePath(_ path: String) async
    func authenticationUpdates() async -> AsyncStream<AIAuthenticationState>
}

protocol OpenAICredentialStoring: Sendable {
    func loadAPIKey() async throws -> String?
    func saveAPIKey(_ value: String) async throws
    func deleteAPIKey() async throws
}

protocol OpenAIChatServing: Sendable {
    func availableModelIDs(apiKey: String) async throws -> Set<String>
    func createConversation(
        apiKey: String,
        title: String,
        model: AIModel
    ) async throws -> String
    func updateConversation(
        apiKey: String,
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws
    func loadConversation(
        apiKey: String,
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage
    func uploadAttachment(
        apiKey: String,
        attachment: AIChatAttachment
    ) async throws -> AIUploadedAttachment
    func streamResponse(
        apiKey: String,
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error>
    func deleteConversationCompletely(
        apiKey: String,
        conversationID: String
    ) async throws
}
