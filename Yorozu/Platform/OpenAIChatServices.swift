import Combine
import Foundation
import Security

actor KeychainOpenAICredentialStore: OpenAICredentialStoring {
    private let service = "com.yorozu.app.openai"
    private let account = "api-key"

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return value
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw AIChatError.authenticationFailed
        }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw keychainError(insertStatus)
            }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "The API key could not be saved securely."]
        )
    }
}

actor KeychainClaudeCredentialStore: OpenAICredentialStoring {
    private let service = "com.yorozu.app.claude"
    private let account = "api-key"

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return value
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw AIChatError.authenticationFailed
        }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw keychainError(insertStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "The API key could not be saved securely."]
        )
    }
}

actor InMemoryOpenAICredentialStore: OpenAICredentialStoring {
    private var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadAPIKey() -> String? {
        value
    }

    func saveAPIKey(_ value: String) {
        self.value = value
    }

    func deleteAPIKey() {
        value = nil
    }
}

actor DeferredOpenAICredentialStore: OpenAICredentialStoring {
    private let factory: @Sendable () -> any OpenAICredentialStoring
    private var storage: (any OpenAICredentialStoring)?

    init(factory: @escaping @Sendable () -> any OpenAICredentialStoring) {
        self.factory = factory
    }

    func loadAPIKey() async throws -> String? {
        try await resolved().loadAPIKey()
    }

    func saveAPIKey(_ value: String) async throws {
        try await resolved().saveAPIKey(value)
    }

    func deleteAPIKey() async throws {
        try await resolved().deleteAPIKey()
    }

    private func resolved() -> any OpenAICredentialStoring {
        if let storage {
            return storage
        }
        let value = factory()
        storage = value
        return value
    }
}

@MainActor
final class AIChatPreferences: ObservableObject {
    @Published var defaultModel: AIModel {
        didSet {
            defaults.set(defaultModel.rawValue, forKey: Keys.defaultModel(providerID))
        }
    }
    @Published var enablesWebSearchByDefault: Bool {
        didSet {
            defaults.set(
                enablesWebSearchByDefault,
                forKey: Keys.webSearch(providerID)
            )
        }
    }
    @Published var defaultReasoningEffort: AIReasoningEffort? {
        didSet {
            let key = Keys.defaultReasoningEffort(providerID)
            if let defaultReasoningEffort {
                defaults.set(defaultReasoningEffort.rawValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults,
        providerID: AIProviderID = .openAIAPI,
        fallbackModel: AIModel? = nil
    ) {
        self.defaults = defaults
        self.providerID = providerID
        let modelKey = Keys.defaultModel(providerID)
        let legacyModel = providerID == .openAIAPI
            ? defaults.string(forKey: "ai.defaultModel")
            : nil
        defaultModel = (defaults.string(forKey: modelKey) ?? legacyModel)
            .map { AIModel(rawValue: $0) }
            ?? fallbackModel
            ?? .terra
        defaultReasoningEffort = defaults
            .string(forKey: Keys.defaultReasoningEffort(providerID))
            .map { AIReasoningEffort(rawValue: $0) }
        let webKey = Keys.webSearch(providerID)
        enablesWebSearchByDefault = defaults.object(forKey: webKey) != nil
            ? defaults.bool(forKey: webKey)
            : (providerID == .openAIAPI && defaults.bool(forKey: "ai.webSearchByDefault"))
    }

    private enum Keys {
        static func defaultModel(_ providerID: AIProviderID) -> String {
            "ai.\(providerID.rawValue).defaultModel"
        }
        static func webSearch(_ providerID: AIProviderID) -> String {
            "ai.\(providerID.rawValue).webSearchByDefault"
        }
        static func defaultReasoningEffort(_ providerID: AIProviderID) -> String {
            "ai.\(providerID.rawValue).defaultReasoningEffort"
        }
    }

    private let providerID: AIProviderID
}

@MainActor
final class AIProviderPreferences: ObservableObject {
    @Published private(set) var enabledProviderIDs: Set<AIProviderID>
    @Published private(set) var defaultProviderID: AIProviderID?
    @Published var codexExecutablePath: String {
        didSet {
            defaults.set(codexExecutablePath, forKey: Keys.codexExecutablePath)
        }
    }

    var didChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let storedIDs = defaults.stringArray(forKey: Keys.enabledProviderIDs)
        let initialEnabledProviderIDs: Set<AIProviderID>
        if let storedIDs {
            initialEnabledProviderIDs = Set(storedIDs.map(AIProviderID.init(rawValue:)))
        } else {
            initialEnabledProviderIDs = [.codex]
            defaults.set([AIProviderID.codex.rawValue], forKey: Keys.enabledProviderIDs)
        }
        let initialDefaultProviderID: AIProviderID?
        if let value = defaults.string(forKey: Keys.defaultProviderID) {
            let candidate = AIProviderID(rawValue: value)
            initialDefaultProviderID = initialEnabledProviderIDs.contains(candidate)
                ? candidate
                : (initialEnabledProviderIDs.contains(.codex)
                    ? .codex
                    : initialEnabledProviderIDs.sorted(by: { $0.rawValue < $1.rawValue }).first)
        } else {
            initialDefaultProviderID = initialEnabledProviderIDs.contains(.codex)
                ? .codex
                : initialEnabledProviderIDs.sorted(by: { $0.rawValue < $1.rawValue }).first
            defaults.set(initialDefaultProviderID?.rawValue, forKey: Keys.defaultProviderID)
        }
        enabledProviderIDs = initialEnabledProviderIDs
        defaultProviderID = initialDefaultProviderID
        codexExecutablePath = defaults.string(forKey: Keys.codexExecutablePath) ?? ""
    }

    func isEnabled(_ id: AIProviderID) -> Bool {
        enabledProviderIDs.contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: AIProviderID) {
        if enabled {
            enabledProviderIDs.insert(id)
            if defaultProviderID == nil {
                defaultProviderID = id
            }
        } else {
            enabledProviderIDs.remove(id)
            normalizeDefault()
        }
        persist()
        didChange?()
    }

    func setDefault(_ id: AIProviderID?) {
        if let id, enabledProviderIDs.contains(id) {
            defaultProviderID = id
        } else if id == nil {
            defaultProviderID = nil
        }
        normalizeDefault()
        persist()
        didChange?()
    }

    func enableOpenAIForLegacyCredential() {
        guard !enabledProviderIDs.contains(.openAIAPI) else { return }
        enabledProviderIDs.insert(.openAIAPI)
        persist()
        didChange?()
    }

    private func normalizeDefault() {
        guard let defaultProviderID,
              enabledProviderIDs.contains(defaultProviderID) else {
            self.defaultProviderID = enabledProviderIDs.contains(.codex)
                ? .codex
                : enabledProviderIDs.sorted(by: { $0.rawValue < $1.rawValue }).first
            return
        }
    }

    private func persist() {
        defaults.set(
            enabledProviderIDs.map(\.rawValue).sorted(),
            forKey: Keys.enabledProviderIDs
        )
        defaults.set(defaultProviderID?.rawValue, forKey: Keys.defaultProviderID)
    }

    private enum Keys {
        static let enabledProviderIDs = "ai.providers.enabled"
        static let defaultProviderID = "ai.providers.default"
        static let codexExecutablePath = "ai.codex.executablePath"
    }
}

actor AIProviderRegistry {
    enum RegistryError: LocalizedError, Equatable {
        case providerNotRegistered

        var errorDescription: String? {
            "This AI provider is not registered."
        }
    }

    private let providers: [AIProviderID: any AIChatProvider]

    init(providers: [any AIChatProvider]) {
        self.providers = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) }
        )
    }

    func provider(for id: AIProviderID) throws -> any AIChatProvider {
        guard let provider = providers[id] else {
            throw RegistryError.providerNotRegistered
        }
        return provider
    }

    func descriptors() -> [AIProviderDescriptor] {
        providers.values.map(\.descriptor).sorted {
            if $0.id == .codex { return true }
            if $1.id == .codex { return false }
            return $0.displayName < $1.displayName
        }
    }

    func shutdown() async {
        for provider in providers.values {
            await provider.shutdown()
        }
    }
}

actor OpenAIAPIProvider: AIChatProvider, OpenAIAPIKeyManaging {
    nonisolated let descriptor = AIProviderDescriptor(
        id: .openAIAPI,
        displayName: "OpenAI API",
        rootCommandTitle: "AI Chat: OpenAI",
        description: "Uses API credits and usage-based billing",
        symbolName: "sparkles",
        capabilities: [
            .authentication, .modelSelection, .streaming, .attachments,
            .webSearch, .archive, .deletion, .citations, .translation,
        ]
    )
    nonisolated let policies = AIProviderPolicies.localConversationIndex

    private let service: any OpenAIChatServing
    private let credentials: any OpenAICredentialStoring

    init(
        service: any OpenAIChatServing,
        credentials: any OpenAICredentialStoring
    ) {
        self.service = service
        self.credentials = credentials
    }

    func availability() -> AIProviderAvailability { .available }

    func authenticationState() async -> AIAuthenticationState {
        do {
            return try await hasAPIKey()
                ? .authenticated(detail: "API key saved")
                : .authenticationRequired
        } catch {
            return .failed(message: "The API key status could not be read.")
        }
    }

    func availableModels() async throws -> [AIModel] {
        let ids = try await service.availableModelIDs(apiKey: requiredAPIKey())
        return AIModel.openAIModels.filter { ids.contains($0.rawValue) }
    }

    func createConversation(title: String, model: AIModel) async throws -> String {
        try await service.createConversation(
            apiKey: requiredAPIKey(),
            title: title,
            model: model
        )
    }

    func updateConversation(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        try await service.updateConversation(
            apiKey: requiredAPIKey(),
            conversationID: conversationID,
            title: title,
            model: model,
            isArchived: isArchived
        )
    }

    func setConversationArchived(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        try await service.updateConversation(
            apiKey: requiredAPIKey(),
            conversationID: conversationID,
            title: title,
            model: model,
            isArchived: isArchived
        )
    }

    func loadConversation(
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage {
        try await service.loadConversation(
            apiKey: requiredAPIKey(),
            conversationID: conversationID,
            limit: limit,
            after: after
        )
    }

    func uploadAttachment(_ attachment: AIChatAttachment) async throws -> AIUploadedAttachment {
        try await service.uploadAttachment(apiKey: requiredAPIKey(), attachment: attachment)
    }

    nonisolated func streamResponse(
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try await self.requiredAPIKey()
                    for try await event in self.service.streamResponse(apiKey: key, request: request) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func streamTranslation(
        request: AITranslationRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        streamResponse(
            request: AIChatSendRequest(
                conversationID: "",
                model: request.model,
                reasoningEffort: request.reasoningEffort,
                prompt: request.prompt,
                attachments: [],
                enablesWebSearch: false,
                clientRequestID: request.clientRequestID
            )
        )
    }

    func stopGeneration(conversationID: String) async {}

    func deleteConversationCompletely(conversationID: String) async throws {
        try await service.deleteConversationCompletely(
            apiKey: requiredAPIKey(),
            conversationID: conversationID
        )
    }

    func shutdown() async {}

    func hasAPIKey() async throws -> Bool {
        try await credentials.loadAPIKey()?.isEmpty == false
    }

    func saveAPIKey(_ value: String) async throws {
        try await credentials.saveAPIKey(value)
    }

    func removeAPIKey() async throws {
        try await credentials.deleteAPIKey()
    }

    private func requiredAPIKey() async throws -> String {
        guard let value = try await credentials.loadAPIKey(), !value.isEmpty else {
            throw AIChatError.missingAPIKey
        }
        return value
    }
}

actor DisabledAIChatProvider: AIChatProvider {
    nonisolated let descriptor = AIProviderDescriptor(
        id: .openAIAPI,
        displayName: "AI",
        rootCommandTitle: "AI Chat",
        description: "AI is unavailable",
        symbolName: "sparkles",
        capabilities: []
    )
    nonisolated let policies = AIProviderPolicies(
        conversationListAuthority: .unavailable,
        messageAuthority: .provider,
        supportsServerSideSearch: false,
        requiresExplicitConversationCreation: true
    )

    func availability() -> AIProviderAvailability {
        .unavailable(reason: "AI is unavailable.")
    }
    func authenticationState() -> AIAuthenticationState { .authenticationRequired }
    func availableModels() async throws -> [AIModel] { [] }
    func createConversation(title: String, model: AIModel) async throws -> String {
        throw AIChatError.providerUnavailable
    }
    func updateConversation(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        throw AIChatError.providerUnavailable
    }
    func loadConversation(
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage {
        throw AIChatError.providerUnavailable
    }
    func uploadAttachment(_ attachment: AIChatAttachment) async throws -> AIUploadedAttachment {
        throw AIChatError.providerUnavailable
    }
    nonisolated func streamResponse(
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIChatError.providerUnavailable) }
    }
    func stopGeneration(conversationID: String) async {}
    func deleteConversationCompletely(conversationID: String) async throws {
        throw AIChatError.providerUnavailable
    }
    func shutdown() async {}
}

actor OpenAIChatClient: OpenAIChatServing {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.openai.com/v1")!
    private var latestDiagnostics: OpenAIRequestDiagnostics?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    func requestDiagnostics() -> OpenAIRequestDiagnostics? {
        latestDiagnostics
    }

    func availableModelIDs(apiKey: String) async throws -> Set<String> {
        let data = try await requestData(
            path: ["models"],
            method: "GET",
            apiKey: apiKey
        )
        let object = try jsonObject(data)
        let models = object["data"] as? [[String: Any]] ?? []
        return Set(models.compactMap { $0["id"] as? String })
    }

    func createConversation(
        apiKey: String,
        title: String,
        model: AIModel
    ) async throws -> String {
        let body: [String: Any] = [
            "metadata": conversationMetadata(
                title: title,
                model: model,
                isArchived: false
            ),
        ]
        let data = try await requestData(
            path: ["conversations"],
            method: "POST",
            apiKey: apiKey,
            body: body
        )
        guard let id = try jsonObject(data)["id"] as? String else {
            throw AIChatError.invalidResponse
        }
        return id
    }

    func updateConversation(
        apiKey: String,
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        let body: [String: Any] = [
            "metadata": conversationMetadata(
                title: title,
                model: model,
                isArchived: isArchived
            ),
        ]
        _ = try await requestData(
            path: ["conversations", conversationID],
            method: "POST",
            apiKey: apiKey,
            body: body
        )
    }

    func loadConversation(
        apiKey: String,
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage {
        var components = URLComponents(
            url: endpoint(["conversations", conversationID, "items"]),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "order", value: "desc"),
        ]
        if let after {
            queryItems.append(URLQueryItem(name: "after", value: after))
        }
        components.queryItems = queryItems
        let data = try await requestData(
            url: components.url!,
            method: "GET",
            apiKey: apiKey
        )
        let object = try jsonObject(data)
        let rawItems = object["data"] as? [[String: Any]] ?? []
        let messages = rawItems.compactMap(parseMessage).reversed()
        return AIConversationPage(
            messages: Array(messages),
            nextCursor: object["last_id"] as? String,
            hasMore: object["has_more"] as? Bool ?? false
        )
    }

    func uploadAttachment(
        apiKey: String,
        attachment: AIChatAttachment
    ) async throws -> AIUploadedAttachment {
        guard let localURL = attachment.localURL else {
            throw AIChatError.invalidAttachment
        }
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        guard data.count < 50 * 1_024 * 1_024 else {
            throw AIChatError.attachmentLimitExceeded
        }
        let boundary = "Yorozu-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(
            name: "purpose",
            value: "user_data",
            boundary: boundary
        )
        body.appendMultipartFile(
            name: "file",
            filename: attachment.filename,
            mimeType: Self.mimeType(for: localURL),
            data: data,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let responseData = try await requestData(
            path: ["files"],
            method: "POST",
            apiKey: apiKey,
            rawBody: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        guard let fileID = try jsonObject(responseData)["id"] as? String else {
            throw AIChatError.invalidResponse
        }
        return AIUploadedAttachment(
            kind: attachment.kind,
            filename: attachment.filename,
            fileID: fileID
        )
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        apiKey: apiKey,
                        request: request,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func deleteConversationCompletely(
        apiKey: String,
        conversationID: String
    ) async throws {
        var after: String?
        var itemIDs: [String] = []
        var fileIDs = Set<String>()

        repeat {
            var components = URLComponents(
                url: endpoint(["conversations", conversationID, "items"]),
                resolvingAgainstBaseURL: false
            )!
            var queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "order", value: "desc"),
            ]
            if let after {
                queryItems.append(URLQueryItem(name: "after", value: after))
            }
            components.queryItems = queryItems
            let data = try await requestData(
                url: components.url!,
                method: "GET",
                apiKey: apiKey
            )
            let object = try jsonObject(data)
            let items = object["data"] as? [[String: Any]] ?? []
            itemIDs.append(contentsOf: items.compactMap { $0["id"] as? String })
            for item in items {
                collectFileIDs(from: item, into: &fileIDs)
            }
            let hasMore = object["has_more"] as? Bool ?? false
            after = hasMore ? object["last_id"] as? String : nil
        } while after != nil

        for itemID in itemIDs {
            try await deleteIgnoringNotFound(
                path: ["conversations", conversationID, "items", itemID],
                apiKey: apiKey
            )
        }
        for fileID in fileIDs {
            try await deleteIgnoringNotFound(path: ["files", fileID], apiKey: apiKey)
        }
        try await deleteIgnoringNotFound(
            path: ["conversations", conversationID],
            apiKey: apiKey
        )
    }

    private func performStream(
        apiKey: String,
        request: AIChatSendRequest,
        continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    ) async throws {
        var urlRequest = try makeRequest(
            url: endpoint(["responses"]),
            method: "POST",
            apiKey: apiKey,
            body: Self.responseBody(for: request)
        )
        urlRequest.setValue(request.clientRequestID, forHTTPHeaderField: "X-Client-Request-Id")
        latestDiagnostics = OpenAIRequestDiagnostics(
            clientRequestID: request.clientRequestID,
            serverRequestID: nil
        )

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            latestDiagnostics = OpenAIRequestDiagnostics(
                clientRequestID: request.clientRequestID,
                serverRequestID: (response as? HTTPURLResponse)?.value(
                    forHTTPHeaderField: "x-request-id"
                )
            )
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                var errorData = Data()
                for try await byte in bytes {
                    guard errorData.count < 65_536 else { break }
                    errorData.append(byte)
                }
                throw Self.apiError(
                    statusCode: response.statusCode,
                    data: errorData
                )
            }
            guard response is HTTPURLResponse else {
                throw AIChatError.invalidResponse
            }
            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                if let event = try Self.streamEvent(fromSSELine: rawLine) {
                    continuation.yield(event)
                    if case .completed = event {
                        return
                    }
                }
            }
            throw AIChatError.streamTransportError(code: -1)
        } catch let error as AIChatError {
            throw error
        } catch let error as URLError {
            throw Self.transportError(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIChatError.streamTransportError(code: (error as NSError).code)
        }
    }

    nonisolated static func normalizedSSELine(_ line: String) -> String {
        line.last == "\r" ? String(line.dropLast()) : line
    }

    nonisolated static func responseBody(
        for request: AIChatSendRequest
    ) -> [String: Any] {
        let inputContent: [[String: Any]] = [
            ["type": "input_text", "text": request.prompt],
        ] + request.attachments.map { attachment in
            if attachment.kind == .image {
                return [
                    "type": "input_image",
                    "file_id": attachment.fileID,
                    "detail": "auto",
                ]
            }
            return [
                "type": "input_file",
                "file_id": attachment.fileID,
            ]
        }
        var body: [String: Any] = [
            "model": request.model.rawValue,
            "input": [
                [
                    "role": "user",
                    "content": inputContent,
                ],
            ],
            "stream": true,
            "store": !request.conversationID.isEmpty,
        ]
        if !request.conversationID.isEmpty {
            body["conversation"] = request.conversationID
        }
        if let reasoningEffort = request.reasoningEffort {
            body["reasoning"] = ["effort": reasoningEffort.rawValue]
        }
        if request.enablesWebSearch {
            body["tools"] = [["type": "web_search"]]
            body["include"] = ["web_search_call.action.sources"]
        }
        return body
    }

    nonisolated static func streamEvent(
        from dataString: String
    ) throws -> AIChatStreamEvent? {
        guard dataString != "[DONE]" else {
            return nil
        }
        guard let data = dataString.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            throw AIChatError.streamProtocolError
        }
        switch type {
        case "response.created":
            guard let response = event["response"] as? [String: Any],
                  let id = response["id"] as? String else {
                return nil
            }
            return .responseCreated(id)
        case "response.output_text.delta":
            return (event["delta"] as? String).map(AIChatStreamEvent.textDelta)
        case "response.output_text.annotation.added":
            guard let annotation = event["annotation"] as? [String: Any],
                  let citation = parseCitationValue(annotation) else {
                return nil
            }
            return .citation(citation)
        case "response.output_item.added":
            guard let item = event["item"] as? [String: Any],
                  item["type"] as? String == "web_search_call" else {
                return nil
            }
            return .webSearchStarted
        case "response.completed":
            return .completed
        case "response.failed":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw apiError(statusCode: nil, error: error)
        case "error":
            let error = event["error"] as? [String: Any] ?? event
            throw apiError(statusCode: nil, error: error)
        default:
            return nil
        }
    }

    nonisolated static func streamEvent(
        fromSSELine rawLine: String
    ) throws -> AIChatStreamEvent? {
        let line = normalizedSSELine(rawLine)
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5))
            .trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }
        return try streamEvent(from: payload)
    }

    private func parseMessage(_ item: [String: Any]) -> AIChatMessage? {
        guard item["type"] as? String == "message",
              let id = item["id"] as? String,
              let rawRole = item["role"] as? String,
              let role = AIChatMessageRole(rawValue: rawRole) else {
            return nil
        }
        let content = item["content"] as? [[String: Any]] ?? []
        var textParts: [String] = []
        var citations: [AIChatCitation] = []
        var attachments: [AIChatAttachment] = []
        for part in content {
            let type = part["type"] as? String
            if type == "input_text" || type == "output_text",
               let text = part["text"] as? String {
                textParts.append(text)
                let annotations = part["annotations"] as? [[String: Any]] ?? []
                citations.append(contentsOf: annotations.compactMap(parseCitation))
            } else if type == "input_file" || type == "input_image" {
                let fileID = part["file_id"] as? String
                let filename = part["filename"] as? String
                    ?? (type == "input_image" ? "Image" : "File")
                attachments.append(
                    AIChatAttachment(
                        id: fileID ?? "\(id)-\(attachments.count)",
                        kind: type == "input_image" ? .image : .file,
                        filename: filename,
                        fileID: fileID,
                        localURL: nil,
                        byteCount: nil
                    )
                )
            }
        }
        return AIChatMessage(
            id: id,
            role: role,
            text: textParts.joined(separator: "\n"),
            citations: citations,
            attachments: attachments,
            isStreaming: false
        )
    }

    private func parseCitation(_ value: [String: Any]) -> AIChatCitation? {
        Self.parseCitationValue(value)
    }

    private nonisolated static func parseCitationValue(
        _ value: [String: Any]
    ) -> AIChatCitation? {
        guard value["type"] as? String == "url_citation",
              let rawURL = value["url"] as? String,
              let url = URL(string: rawURL) else {
            return nil
        }
        return AIChatCitation(
            id: "\(rawURL)#\(value["start_index"] as? Int ?? 0)",
            title: value["title"] as? String ?? url.host() ?? rawURL,
            url: url,
            startIndex: value["start_index"] as? Int,
            endIndex: value["end_index"] as? Int
        )
    }

    private func collectFileIDs(
        from item: [String: Any],
        into fileIDs: inout Set<String>
    ) {
        let content = item["content"] as? [[String: Any]] ?? []
        for part in content {
            if let fileID = part["file_id"] as? String {
                fileIDs.insert(fileID)
            }
        }
    }

    private func deleteIgnoringNotFound(
        path: [String],
        apiKey: String
    ) async throws {
        do {
            _ = try await requestData(path: path, method: "DELETE", apiKey: apiKey)
        } catch let error as AIChatError {
            if error != .requestFailed(statusCode: 404) {
                throw error
            }
        }
    }

    private func conversationMetadata(
        title: String,
        model: AIModel,
        isArchived: Bool
    ) -> [String: String] {
        [
            "yorozu_title": title,
            "yorozu_model": model.rawValue,
            "yorozu_archived": isArchived ? "true" : "false",
            "yorozu_updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    private func requestData(
        path: [String],
        method: String,
        apiKey: String,
        body: [String: Any]? = nil,
        rawBody: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> Data {
        try await requestData(
            url: endpoint(path),
            method: method,
            apiKey: apiKey,
            body: body,
            rawBody: rawBody,
            contentType: contentType
        )
    }

    private func requestData(
        url: URL,
        method: String,
        apiKey: String,
        body: [String: Any]? = nil,
        rawBody: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> Data {
        let request = try makeRequest(
            url: url,
            method: method,
            apiKey: apiKey,
            body: body,
            rawBody: rawBody,
            contentType: contentType
        )
        do {
            var attempt = 0
            while true {
                let (data, response) = try await session.data(for: request)
                let clientRequestID = request.value(
                    forHTTPHeaderField: "X-Client-Request-Id"
                ) ?? "unknown"
                latestDiagnostics = OpenAIRequestDiagnostics(
                    clientRequestID: clientRequestID,
                    serverRequestID: (response as? HTTPURLResponse)?.value(
                        forHTTPHeaderField: "x-request-id"
                    )
                )
                if method == "GET",
                   attempt < 2,
                   let response = response as? HTTPURLResponse,
                   response.statusCode == 429 || (500...599).contains(response.statusCode) {
                    let retrySeconds = response.value(
                        forHTTPHeaderField: "Retry-After"
                    ).flatMap(Double.init)
                    let delay = min(max(retrySeconds ?? pow(2, Double(attempt)), 0.1), 8)
                    attempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                try validate(response, data: data)
                return data
            }
        } catch let error as AIChatError {
            throw error
        } catch let error as URLError {
            throw Self.transportError(error)
        }
    }

    private func makeRequest(
        url: URL,
        method: String,
        apiKey: String,
        body: [String: Any]? = nil,
        rawBody: Data? = nil,
        contentType: String = "application/json"
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-Id")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            request.httpBody = rawBody
        }
        return request
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AIChatError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.apiError(statusCode: response.statusCode, data: data)
        }
    }

    nonisolated static func apiError(
        statusCode: Int?,
        data: Data
    ) -> AIChatError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return apiError(
            statusCode: statusCode,
            error: object?["error"] as? [String: Any]
        )
    }

    private nonisolated static func apiError(
        statusCode: Int?,
        error: [String: Any]?
    ) -> AIChatError {
        let code = (error?["code"] as? String)?.lowercased()
        let type = (error?["type"] as? String)?.lowercased()
        let values = Set([code, type].compactMap { $0 })
        if !values.isDisjoint(with: ["invalid_api_key", "authentication_error"]) {
            return .authenticationFailed
        }
        if !values.isDisjoint(with: ["model_not_found", "model_not_available"]) {
            return .modelUnavailable
        }
        if !values.isDisjoint(with: [
            "insufficient_quota",
            "billing_hard_limit_reached",
            "usage_limit_reached",
        ]) {
            return .quotaExceeded
        }
        if !values.isDisjoint(with: ["rate_limit_exceeded", "rate_limit_error"]) {
            return .rateLimited
        }
        if !values.isDisjoint(with: ["server_error", "service_unavailable"]) {
            return .serverUnavailable
        }
        if let statusCode, (500...599).contains(statusCode) {
            return .serverUnavailable
        }
        switch statusCode {
        case 401, 403:
            return .authenticationFailed
        case 408:
            return .requestTimedOut
        case 429:
            return .rateLimited
        case let statusCode?:
            return .requestFailed(statusCode: statusCode)
        case nil:
            return .apiFailure(code: safeAPIErrorIdentifier(code ?? type))
        }
    }

    private nonisolated static func safeAPIErrorIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let sanitized = value.unicodeScalars.filter(allowed.contains).prefix(64)
        let result = String(String.UnicodeScalarView(sanitized))
        return result.isEmpty ? nil : result
    }

    private nonisolated static func transportError(_ error: URLError) -> AIChatError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed:
            return .offline
        case .timedOut:
            return .requestTimedOut
        default:
            return .invalidResponse
        }
    }

    private func endpoint(_ path: [String]) -> URL {
        path.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIChatError.invalidResponse
        }
        return object
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "pdf": "application/pdf"
        case "csv": "text/csv"
        case "json": "application/json"
        case "md", "markdown": "text/markdown"
        case "txt": "text/plain"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: "application/octet-stream"
        }
    }
}

actor DisabledOpenAIChatService: OpenAIChatServing {
    func availableModelIDs(apiKey: String) -> Set<String> {
        Set(AIModel.openAIModels.map(\.rawValue))
    }

    func createConversation(
        apiKey: String,
        title: String,
        model: AIModel
    ) throws -> String {
        throw AIChatError.offline
    }

    func updateConversation(
        apiKey: String,
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) throws {
        throw AIChatError.offline
    }

    func loadConversation(
        apiKey: String,
        conversationID: String,
        limit: Int,
        after: String?
    ) throws -> AIConversationPage {
        throw AIChatError.offline
    }

    func uploadAttachment(
        apiKey: String,
        attachment: AIChatAttachment
    ) throws -> AIUploadedAttachment {
        throw AIChatError.offline
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIChatError.offline)
        }
    }

    func deleteConversationCompletely(
        apiKey: String,
        conversationID: String
    ) throws {
        throw AIChatError.offline
    }
}

actor DeferredOpenAIChatService: OpenAIChatServing {
    private let factory: @Sendable () -> any OpenAIChatServing
    private var storage: (any OpenAIChatServing)?

    init(factory: @escaping @Sendable () -> any OpenAIChatServing) {
        self.factory = factory
    }

    func availableModelIDs(apiKey: String) async throws -> Set<String> {
        try await resolved().availableModelIDs(apiKey: apiKey)
    }

    func createConversation(
        apiKey: String,
        title: String,
        model: AIModel
    ) async throws -> String {
        try await resolved().createConversation(
            apiKey: apiKey,
            title: title,
            model: model
        )
    }

    func updateConversation(
        apiKey: String,
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        try await resolved().updateConversation(
            apiKey: apiKey,
            conversationID: conversationID,
            title: title,
            model: model,
            isArchived: isArchived
        )
    }

    func loadConversation(
        apiKey: String,
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage {
        try await resolved().loadConversation(
            apiKey: apiKey,
            conversationID: conversationID,
            limit: limit,
            after: after
        )
    }

    func uploadAttachment(
        apiKey: String,
        attachment: AIChatAttachment
    ) async throws -> AIUploadedAttachment {
        try await resolved().uploadAttachment(
            apiKey: apiKey,
            attachment: attachment
        )
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let service = await self.resolved()
                    for try await event in service.streamResponse(
                        apiKey: apiKey,
                        request: request
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func deleteConversationCompletely(
        apiKey: String,
        conversationID: String
    ) async throws {
        try await resolved().deleteConversationCompletely(
            apiKey: apiKey,
            conversationID: conversationID
        )
    }

    private func resolved() -> any OpenAIChatServing {
        if let storage {
            return storage
        }
        let value = factory()
        storage = value
        return value
    }
}

private extension Data {
    mutating func appendMultipartField(
        name: String,
        value: String,
        boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        let safeFilename = filename.replacingOccurrences(of: "\"", with: "_")
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeFilename)\"\r\n"
                .data(using: .utf8)!
        )
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}

// MARK: - Claude Messages API

protocol ClaudeChatServing: Sendable {
    func availableModelIDs(apiKey: String) async throws -> Set<String>
    func streamResponse(
        apiKey: String,
        request: AIChatSendRequest,
        history: [AIChatMessage]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error>
}

actor ClaudeChatClient: ClaudeChatServing {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.anthropic.com/v1")!

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    func availableModelIDs(apiKey: String) async throws -> Set<String> {
        let data = try await requestData(path: ["models"], method: "GET", apiKey: apiKey)
        let object = try jsonObject(data)
        let models = object["data"] as? [[String: Any]] ?? []
        return Set(models.compactMap { $0["id"] as? String })
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest,
        history: [AIChatMessage]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        apiKey: apiKey,
                        request: request,
                        history: history,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStream(
        apiKey: String,
        request: AIChatSendRequest,
        history: [AIChatMessage],
        continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    ) async throws {
        let messages = history.map { message in
            [
                "role": message.role.rawValue,
                "content": message.text,
            ]
        }
        let body: [String: Any] = [
            "model": request.model.rawValue,
            "max_tokens": 4096,
            "messages": messages,
            "stream": true,
        ]
        var urlRequest = try makeRequest(
            url: endpoint(["messages"]),
            method: "POST",
            apiKey: apiKey,
            body: body
        )
        urlRequest.setValue(request.clientRequestID, forHTTPHeaderField: "X-Client-Request-Id")

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIChatError.invalidResponse
            }
            if !(200..<300).contains(httpResponse.statusCode) {
                var errorData = Data()
                for try await byte in bytes {
                    guard errorData.count < 65_536 else { break }
                    errorData.append(byte)
                }
                throw Self.apiError(statusCode: httpResponse.statusCode, data: errorData)
            }

            var eventName: String?
            var receivedStop = false
            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : rawLine
                if line.hasPrefix("event:") {
                    eventName = line.dropFirst(6)
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5))
                    .trimmingCharacters(in: .whitespaces)
                guard let event = try Self.streamEvent(
                    eventName: eventName,
                    payload: payload
                ) else { continue }
                continuation.yield(event)
                if case .completed = event {
                    receivedStop = true
                    break
                }
            }
            guard receivedStop else {
                throw AIChatError.streamTransportError(code: -1)
            }
        } catch let error as AIChatError {
            throw error
        } catch let error as URLError {
            throw Self.transportError(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIChatError.streamTransportError(code: (error as NSError).code)
        }
    }

    private func requestData(
        path: [String],
        method: String,
        apiKey: String,
        body: [String: Any]? = nil
    ) async throws -> Data {
        let request = try makeRequest(
            url: endpoint(path),
            method: method,
            apiKey: apiKey,
            body: body
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AIChatError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw Self.apiError(statusCode: response.statusCode, data: data)
            }
            return data
        } catch let error as AIChatError {
            throw error
        } catch let error as URLError {
            throw Self.transportError(error)
        }
    }

    private func makeRequest(
        url: URL,
        method: String,
        apiKey: String,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func endpoint(_ path: [String]) -> URL {
        path.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIChatError.invalidResponse
        }
        return object
    }

    private nonisolated static func streamEvent(
        eventName: String?,
        payload: String
    ) throws -> AIChatStreamEvent? {
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIChatError.streamProtocolError
        }
        let type = (object["type"] as? String) ?? eventName
        switch type {
        case "message_start":
            let message = object["message"] as? [String: Any]
            return (message?["id"] as? String).map(AIChatStreamEvent.responseCreated)
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any]
            guard delta?["type"] as? String == "text_delta" else { return nil }
            return (delta?["text"] as? String).map(AIChatStreamEvent.textDelta)
        case "message_stop":
            return .completed
        case "error":
            let error = object["error"] as? [String: Any]
            throw apiError(statusCode: nil, error: error)
        default:
            return nil
        }
    }

    private nonisolated static func apiError(
        statusCode: Int?,
        data: Data
    ) -> AIChatError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return apiError(statusCode: statusCode, error: object?["error"] as? [String: Any])
    }

    private nonisolated static func apiError(
        statusCode: Int?,
        error: [String: Any]?
    ) -> AIChatError {
        let type = (error?["type"] as? String)?.lowercased()
        switch statusCode {
        case 401, 403:
            return .authenticationFailed
        case 408:
            return .requestTimedOut
        case 429:
            return .rateLimited
        case let code? where (500...599).contains(code):
            return .serverUnavailable
        case let code?:
            return .requestFailed(statusCode: code)
        case nil where type == "authentication_error":
            return .authenticationFailed
        default:
            return .apiFailure(code: type)
        }
    }

    private nonisolated static func transportError(_ error: URLError) -> AIChatError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed:
            return .offline
        case .timedOut:
            return .requestTimedOut
        default:
            return .invalidResponse
        }
    }
}

actor DeferredClaudeChatService: ClaudeChatServing {
    private let factory: @Sendable () -> any ClaudeChatServing
    private var storage: (any ClaudeChatServing)?

    init(factory: @escaping @Sendable () -> any ClaudeChatServing) {
        self.factory = factory
    }

    func availableModelIDs(apiKey: String) async throws -> Set<String> {
        try await resolved().availableModelIDs(apiKey: apiKey)
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest,
        history: [AIChatMessage]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let service = await self.resolved()
                    for try await event in service.streamResponse(
                        apiKey: apiKey,
                        request: request,
                        history: history
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolved() -> any ClaudeChatServing {
        if let storage { return storage }
        let value = factory()
        storage = value
        return value
    }
}

actor DisabledClaudeChatService: ClaudeChatServing {
    func availableModelIDs(apiKey: String) -> Set<String> {
        Set(AIModel.claudeModels.map(\.rawValue))
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest,
        history: [AIChatMessage]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIChatError.offline) }
    }
}

actor ClaudeAPIProvider: AIChatProvider, OpenAIAPIKeyManaging {
    nonisolated let descriptor = AIProviderDescriptor(
        id: .claude,
        displayName: "Claude",
        rootCommandTitle: "AI Chat: Claude",
        description: "Uses Anthropic API credits and usage-based billing",
        symbolName: "bubble.left.and.bubble.right",
        capabilities: [
            .authentication, .modelSelection, .streaming,
            .archive, .deletion, .translation,
        ]
    )
    nonisolated let policies = AIProviderPolicies.localConversationIndex

    private let service: any ClaudeChatServing
    private let credentials: any OpenAICredentialStoring
    private var messagesByConversation: [String: [AIChatMessage]] = [:]

    init(
        service: any ClaudeChatServing,
        credentials: any OpenAICredentialStoring
    ) {
        self.service = service
        self.credentials = credentials
    }

    func availability() -> AIProviderAvailability { .available }

    func authenticationState() async -> AIAuthenticationState {
        do {
            return try await hasAPIKey()
                ? .authenticated(detail: "API key saved")
                : .authenticationRequired
        } catch {
            return .failed(message: "The Anthropic API key status could not be read.")
        }
    }

    func availableModels() async throws -> [AIModel] {
        let ids = try await service.availableModelIDs(apiKey: requiredAPIKey())
        let models = ids.map { id in
            AIModel(
                rawValue: id,
                title: AIModel(rawValue: id).title,
                detail: "Anthropic Claude model",
                isDefault: id == AIModel.claudeSonnet.rawValue
            )
        }
        return models.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.title < rhs.title
        }
    }

    func createConversation(title: String, model: AIModel) -> String {
        let id = UUID().uuidString
        messagesByConversation[id] = []
        return id
    }

    func updateConversation(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) {}

    func setConversationArchived(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) {}

    func loadConversation(
        conversationID: String,
        limit: Int,
        after: String?
    ) -> AIConversationPage {
        let messages = messagesByConversation[conversationID] ?? []
        return AIConversationPage(
            messages: Array(messages.suffix(max(1, limit))),
            nextCursor: nil,
            hasMore: false
        )
    }

    func uploadAttachment(_ attachment: AIChatAttachment) async throws -> AIUploadedAttachment {
        throw AIChatError.invalidAttachment
    }

    nonisolated func streamResponse(
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try await self.requiredAPIKey()
                    let history = await self.recordUserMessage(request)
                    for try await event in self.service.streamResponse(
                        apiKey: key,
                        request: request,
                        history: history
                    ) {
                        continuation.yield(event)
                        if case let .textDelta(text) = event {
                            await self.appendAssistantDelta(text, conversationID: request.conversationID)
                        } else if case .completed = event {
                            await self.finishAssistantMessage(conversationID: request.conversationID)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func streamTranslation(
        request: AITranslationRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        streamResponse(
            request: AIChatSendRequest(
                conversationID: "",
                model: request.model,
                reasoningEffort: request.reasoningEffort,
                prompt: request.prompt,
                attachments: [],
                enablesWebSearch: false,
                clientRequestID: request.clientRequestID
            )
        )
    }

    func stopGeneration(conversationID: String) async {}

    func deleteConversationCompletely(conversationID: String) {
        messagesByConversation.removeValue(forKey: conversationID)
    }

    func shutdown() async {}

    func hasAPIKey() async throws -> Bool {
        try await credentials.loadAPIKey()?.isEmpty == false
    }

    func saveAPIKey(_ value: String) async throws {
        try await credentials.saveAPIKey(value)
    }

    func removeAPIKey() async throws {
        try await credentials.deleteAPIKey()
    }

    private func requiredAPIKey() async throws -> String {
        guard let value = try await credentials.loadAPIKey(), !value.isEmpty else {
            throw AIChatError.missingClaudeAPIKey
        }
        return value
    }

    private func recordUserMessage(_ request: AIChatSendRequest) -> [AIChatMessage] {
        let message = AIChatMessage(
            id: "user-\(request.clientRequestID)",
            role: .user,
            text: request.prompt,
            citations: [],
            attachments: [],
            isStreaming: false
        )
        guard !request.conversationID.isEmpty else { return [message] }
        var messages = messagesByConversation[request.conversationID] ?? []
        messages.append(message)
        messagesByConversation[request.conversationID] = messages
        return messages
    }

    private func appendAssistantDelta(_ text: String, conversationID: String) {
        guard !conversationID.isEmpty else { return }
        var messages = messagesByConversation[conversationID] ?? []
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].text += text
        } else {
            messages.append(
                AIChatMessage(
                    id: "assistant-\(UUID().uuidString)",
                    role: .assistant,
                    text: text,
                    citations: [],
                    attachments: [],
                    isStreaming: true
                )
            )
        }
        messagesByConversation[conversationID] = messages
    }

    private func finishAssistantMessage(conversationID: String) {
        guard !conversationID.isEmpty,
              var messages = messagesByConversation[conversationID],
              let index = messages.lastIndex(where: { $0.role == .assistant }) else {
            return
        }
        messages[index].isStreaming = false
        messagesByConversation[conversationID] = messages
    }
}
