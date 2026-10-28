import Foundation
import FoundationModels

enum AppleIntelligenceError: LocalizedError {
    case unavailable(String)
    case revisedStream

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        case .revisedStream: "Apple Intelligence revised its response. Please try again."
        }
    }
}

/// The system model runs locally. Each request uses a fresh session built from
/// this conversation's in-memory messages; translations never join a chat.
struct AppleIntelligenceService: OllamaChatServing {
    static func unavailableMessage() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Enable Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): return "The on-device model is not ready. Try again after it finishes downloading."
        case .unavailable: return "Apple Intelligence is currently unavailable."
        }
    }

    func availableModels() async throws -> [AIModel] {
        if let message = Self.unavailableMessage() { throw AppleIntelligenceError.unavailable(message) }
        return [.appleOnDevice]
    }

    func streamResponse(request: AIChatSendRequest, history: [AIChatMessage]) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let message = Self.unavailableMessage() { throw AppleIntelligenceError.unavailable(message) }
                    let entries: [Transcript.Entry] = history.dropLast().map { message in
                        let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: message.text))]
                        switch message.role {
                        case .user: return .prompt(Transcript.Prompt(segments: segments))
                        case .assistant: return .response(Transcript.Response(assetIDs: [], segments: segments))
                        }
                    }
                    let session = LanguageModelSession(model: .default, transcript: Transcript(entries: entries))
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: request.prompt) {
                        try Task.checkCancellation()
                        let current = snapshot.content
                        guard current.utf8.starts(with: previous.utf8) else { throw AppleIntelligenceError.revisedStream }
                        let delta = String(decoding: current.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
                        if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                        previous = current
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    #if compiler(>=6.4)
                    if #available(macOS 27.0, *), let modelError = error as? LanguageModelError {
                        switch modelError {
                        case .contextSizeExceeded:
                            continuation.finish(throwing: AppleIntelligenceError.unavailable("This chat is too long for the on-device model. Start a new chat or shorten the text."))
                        case .unsupportedLanguageOrLocale:
                            continuation.finish(throwing: AppleIntelligenceError.unavailable("Apple Intelligence does not support this language on this Mac."))
                        default:
                            continuation.finish(throwing: AppleIntelligenceError.unavailable("Apple Intelligence could not complete the request. Try again."))
                        }
                        return
                    }
                    #endif
                    if let modelError = error as? LanguageModelSession.GenerationError {
                        switch modelError {
                        case .exceededContextWindowSize:
                            continuation.finish(throwing: AppleIntelligenceError.unavailable("This chat is too long for the on-device model. Start a new chat or shorten the text."))
                        case .unsupportedLanguageOrLocale:
                            continuation.finish(throwing: AppleIntelligenceError.unavailable("Apple Intelligence does not support this language on this Mac."))
                        default:
                            continuation.finish(throwing: AppleIntelligenceError.unavailable("Apple Intelligence could not complete the request. Try again."))
                        }
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor AppleIntelligenceProvider: AIChatProvider {
    nonisolated let descriptor = AIProviderDescriptor(
        id: .appleIntelligence, displayName: "Apple Intelligence",
        rootCommandTitle: "AI Chat: Apple Intelligence",
        description: "Runs on this Mac", symbolName: "sparkles",
        capabilities: [.modelSelection, .streaming, .archive, .deletion, .cancellation, .translation]
    )
    nonisolated let policies = AIProviderPolicies(
        conversationListAuthority: .localIndex, messageAuthority: .local,
        supportsServerSideSearch: false, requiresExplicitConversationCreation: true
    )
    private let conversations: OllamaAIProvider

    init(service: any OllamaChatServing = AppleIntelligenceService()) {
        conversations = OllamaAIProvider(service: service)
    }

    func availability() -> AIProviderAvailability {
        if let message = AppleIntelligenceService.unavailableMessage() { return .unavailable(reason: message) }
        return .available
    }
    func authenticationState() -> AIAuthenticationState {
        if let message = AppleIntelligenceService.unavailableMessage() { return .failed(message: message) }
        return .authenticated(detail: nil)
    }
    func availableModels() async throws -> [AIModel] { try await conversations.availableModels() }
    func createConversation(title: String, model: AIModel) async throws -> String {
        _ = try await conversations.availableModels()
        return await conversations.createConversation(title: title, model: model)
    }
    func updateConversation(conversationID: String, title: String, model: AIModel, isArchived: Bool) async throws {}
    func setConversationArchived(conversationID: String, title: String, model: AIModel, isArchived: Bool) async throws {}
    func loadConversation(conversationID: String, limit: Int, after: String?) async throws -> AIConversationPage {
        let all = await conversations.loadConversation(conversationID: conversationID, limit: Int.max, after: nil).messages
        let end = min(max(Int(after ?? "") ?? all.count, 0), all.count)
        let start = max(0, end - max(1, limit))
        return AIConversationPage(messages: Array(all[start..<end]), nextCursor: start > 0 ? String(start) : nil, hasMore: start > 0)
    }
    func uploadAttachment(_ attachment: AIChatAttachment) async throws -> AIUploadedAttachment { throw AIChatError.invalidAttachment }
    nonisolated func streamResponse(request: AIChatSendRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> { conversations.streamResponse(request: request) }
    nonisolated func streamTranslation(request: AITranslationRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> { conversations.streamTranslation(request: request) }
    func stopGeneration(conversationID: String) async { await conversations.stopGeneration(conversationID: conversationID) }
    func deleteConversationCompletely(conversationID: String) async throws { await conversations.deleteConversationCompletely(conversationID: conversationID) }
    func shutdown() async { await conversations.shutdown() }
}
