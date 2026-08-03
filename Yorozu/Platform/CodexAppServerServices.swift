import Foundation

enum CodexJSONValue: Codable, Sendable, Equatable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            throw AIChatError.protocolError
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> CodexJSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
}

struct CodexAppServerNotification: Sendable {
    let method: String
    let params: CodexJSONValue
}

protocol CodexAppServerServing: Sendable {
    func request(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue
    func notifications() async -> AsyncStream<CodexAppServerNotification>
    func stop() async
}

actor CodexAppServerClient: CodexAppServerServing {
    private struct ResponseEnvelope: Decodable {
        let id: Int?
        let result: CodexJSONValue?
        let error: CodexJSONValue?
        let method: String?
        let params: CodexJSONValue?
    }

    private let executableURL: URL
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var errorDrainTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<CodexJSONValue, Error>] = [:]
    private var notificationContinuations:
        [UUID: AsyncStream<CodexAppServerNotification>.Continuation] = [:]
    private var isInitialized = false
    private var isStopping = false

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func request(
        method: String,
        params: CodexJSONValue = .object([:])
    ) async throws -> CodexJSONValue {
        try await startIfNeeded()
        return try await sendRequest(method: method, params: params)
    }

    func notifications() async -> AsyncStream<CodexAppServerNotification> {
        let id = UUID()
        return AsyncStream { continuation in
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(id) }
            }
        }
    }

    func stop() async {
        isStopping = true
        outputTask?.cancel()
        errorDrainTask?.cancel()
        outputTask = nil
        errorDrainTask = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputHandle = nil
        isInitialized = false
        finishPending(with: AIChatError.appServerTerminated)
        for continuation in notificationContinuations.values {
            continuation.finish()
        }
        notificationContinuations.removeAll()
    }

    private func startIfNeeded() async throws {
        if process?.isRunning == true, isInitialized { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AIChatError.codexNotInstalled
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processDidTerminate() }
        }
        do {
            try process.run()
        } catch {
            throw AIChatError.codexNotInstalled
        }
        self.process = process
        inputHandle = input.fileHandleForWriting
        isStopping = false

        let outputHandle = output.fileHandleForReading
        outputTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await line in outputHandle.bytes.lines {
                    guard !Task.isCancelled else { break }
                    await self?.receive(line: line)
                }
            } catch {
                await self?.streamDidFail()
            }
        }
        let errorHandle = error.fileHandleForReading
        errorDrainTask = Task.detached(priority: .utility) {
            do {
                for try await _ in errorHandle.bytes {
                    guard !Task.isCancelled else { break }
                }
            } catch {
                // stderr is intentionally drained without retention or logging.
            }
        }

        _ = try await sendRequest(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("yorozu"),
                    "title": .string("Yorozu"),
                    "version": .string("0.1.0"),
                ]),
                "capabilities": .object(["experimentalApi": .bool(false)]),
            ])
        )
        try write(
            .object([
                "method": .string("initialized"),
                "params": .object([:]),
            ])
        )
        isInitialized = true
    }

    private func sendRequest(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        let id = nextRequestID
        nextRequestID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(
                        .object([
                            "id": .number(Double(id)),
                            "method": .string(method),
                            "params": params,
                        ])
                    )
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    private func write(_ value: CodexJSONValue) throws {
        guard let inputHandle else { throw AIChatError.appServerTerminated }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            finishPending(with: AIChatError.protocolError)
            return
        }
        if let id = envelope.id {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if envelope.error != nil {
                continuation.resume(throwing: AIChatError.protocolError)
            } else {
                continuation.resume(returning: envelope.result ?? .null)
            }
            return
        }
        guard let method = envelope.method else { return }
        let notification = CodexAppServerNotification(
            method: method,
            params: envelope.params ?? .object([:])
        )
        for continuation in notificationContinuations.values {
            continuation.yield(notification)
        }
    }

    private func cancelRequest(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func removeNotificationContinuation(_ id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }

    private func processDidTerminate() {
        guard !isStopping else { return }
        process = nil
        inputHandle = nil
        isInitialized = false
        finishPending(with: AIChatError.appServerTerminated)
        for continuation in notificationContinuations.values {
            continuation.finish()
        }
        notificationContinuations.removeAll()
    }

    private func streamDidFail() {
        guard !isStopping else { return }
        finishPending(with: AIChatError.appServerTerminated)
    }

    private func finishPending(with error: Error) {
        let values = pending.values
        pending.removeAll()
        for continuation in values {
            continuation.resume(throwing: error)
        }
    }
}

struct CodexExecutableLocator: Sendable {
    let configuredPath: String

    func executableURL() -> URL? {
        let candidates = [configuredPath]
            + [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/MacOS/codex",
            ]
            + ProcessInfo.processInfo.environment["PATH", default: ""]
                .split(separator: ":")
                .map { "\($0)/codex" }
        for candidate in candidates where !candidate.isEmpty {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

actor CodexAIProvider: AIChatProvider, CodexAuthenticationManaging {
    nonisolated let descriptor = AIProviderDescriptor(
        id: .codex,
        displayName: "Codex",
        rootCommandTitle: "AI Chat: Codex",
        description: "Uses your ChatGPT plan through Codex",
        symbolName: "terminal",
        capabilities: [
            .authentication, .modelSelection, .streaming, .archive,
            .deletion, .rateLimitStatus,
        ]
    )

    private var configuredExecutablePath: String
    private let clientFactory: (@Sendable () throws -> any CodexAppServerServing)?
    private var client: (any CodexAppServerServing)?
    private var activeTurnByConversation: [String: String] = [:]
    private var activeLoginID: String?

    init(
        configuredExecutablePath: String = "",
        clientFactory: (@Sendable () throws -> any CodexAppServerServing)? = nil
    ) {
        self.configuredExecutablePath = configuredExecutablePath
        self.clientFactory = clientFactory
    }

    func availability() -> AIProviderAvailability {
        clientFactory == nil && resolvedExecutableURL() == nil
            ? .unavailable(reason: "Codex is not installed.")
            : .available
    }

    func authenticationState() async -> AIAuthenticationState {
        do {
            let result = try await resolvedClient().request(
                method: "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
            guard let account = result["account"] else {
                return .authenticationRequired
            }
            guard account != .null else { return .authenticationRequired }
            let plan = account["planType"]?.stringValue
            return .authenticated(detail: plan.map { "ChatGPT \($0)" })
        } catch let error as AIChatError where error == .codexNotInstalled {
            return .failed(message: error.localizedDescription)
        } catch {
            return .failed(message: "Codex authentication status is unavailable.")
        }
    }

    func availableModels() async throws -> [AIModel] {
        var cursor: String?
        var models: [AIModel] = []
        repeat {
            var params: [String: CodexJSONValue] = [
                "includeHidden": .bool(false),
                "limit": .number(100),
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await resolvedClient().request(
                method: "model/list",
                params: .object(params)
            )
            let page = result["data"]?.arrayValue ?? []
            models.append(contentsOf: page.compactMap { value in
                guard let id = value["model"]?.stringValue
                    ?? value["id"]?.stringValue else { return nil }
                return AIModel(
                    rawValue: id,
                    title: value["displayName"]?.stringValue ?? id,
                    detail: value["description"]?.stringValue ?? "",
                    isDefault: value["isDefault"]?.boolValue ?? false
                )
            })
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        return models
    }

    func createConversation(title: String, model: AIModel) async throws -> String {
        let result = try await resolvedClient().request(
            method: "thread/start",
            params: .object([
                "model": .string(model.rawValue),
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
                "cwd": .string(FileManager.default.temporaryDirectory.path),
                "baseInstructions": .string(
                    "You are a concise general-purpose assistant inside Yorozu. "
                        + "Do not inspect local files or run tools unless the user explicitly asks."
                ),
            ])
        )
        guard let id = result["thread"]?["id"]?.stringValue else {
            throw AIChatError.protocolError
        }
        return id
    }

    func updateConversation(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {}

    func setConversationArchived(
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) async throws {
        _ = try await resolvedClient().request(
            method: isArchived ? "thread/archive" : "thread/unarchive",
            params: .object(["threadId": .string(conversationID)])
        )
    }

    func loadConversation(
        conversationID: String,
        limit: Int,
        after: String?
    ) async throws -> AIConversationPage {
        let result = try await resolvedClient().request(
            method: "thread/read",
            params: .object([
                "threadId": .string(conversationID),
                "includeTurns": .bool(true),
            ])
        )
        return AIConversationPage(
            messages: Self.messages(from: result["thread"]),
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
                    try await self.performStream(request: request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    await self.stopGeneration(conversationID: request.conversationID)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stopGeneration(conversationID: String) async {
        guard let turnID = activeTurnByConversation[conversationID],
              let client else { return }
        _ = try? await client.request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(conversationID),
                "turnId": .string(turnID),
            ])
        )
        activeTurnByConversation.removeValue(forKey: conversationID)
    }

    func deleteConversationCompletely(conversationID: String) async throws {
        _ = try await resolvedClient().request(
            method: "thread/delete",
            params: .object(["threadId": .string(conversationID)])
        )
    }

    func shutdown() async {
        await client?.stop()
        client = nil
    }

    func signInWithChatGPT() async throws -> URL {
        let result = try await resolvedClient().request(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("codex"),
            ])
        )
        guard let value = result["authUrl"]?.stringValue,
              let loginID = result["loginId"]?.stringValue,
              let url = URL(string: value) else {
            throw AIChatError.protocolError
        }
        activeLoginID = loginID
        return url
    }

    func cancelSignIn() async {
        guard let client, let activeLoginID else { return }
        _ = try? await client.request(
            method: "account/login/cancel",
            params: .object(["loginId": .string(activeLoginID)])
        )
        self.activeLoginID = nil
    }

    func signOut() async throws {
        _ = try await resolvedClient().request(
            method: "account/logout",
            params: .object([:])
        )
    }

    func accountPlanType() async throws -> String? {
        let result = try await resolvedClient().request(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )
        return result["account"]?["planType"]?.stringValue
    }

    func rateLimitSummary() async throws -> String? {
        let result = try await resolvedClient().request(
            method: "account/rateLimits/read",
            params: .object([:])
        )
        guard result != .null else { return nil }
        return "Rate-limit status available"
    }

    func executablePath() -> String? {
        resolvedExecutableURL()?.path
    }

    func updateExecutablePath(_ path: String) async {
        guard configuredExecutablePath != path else { return }
        await client?.stop()
        client = nil
        configuredExecutablePath = path
    }

    func authenticationUpdates() async -> AsyncStream<AIAuthenticationState> {
        guard let client = try? resolvedClient() else {
            return AsyncStream { $0.finish() }
        }
        let source = await client.notifications()
        return AsyncStream { continuation in
            let task = Task {
                for await notification in source {
                    guard notification.method == "account/updated"
                            || notification.method == "account/login/completed" else {
                        continue
                    }
                    self.activeLoginID = nil
                    continuation.yield(await self.authenticationState())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStream(
        request: AIChatSendRequest,
        continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    ) async throws {
        let client = try resolvedClient()
        let notifications = await client.notifications()
        _ = try? await client.request(
            method: "thread/resume",
            params: .object(["threadId": .string(request.conversationID)])
        )
        let result = try await client.request(
            method: "turn/start",
            params: .object([
                "threadId": .string(request.conversationID),
                "model": .string(request.model.rawValue),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(request.prompt),
                    ]),
                ]),
            ])
        )
        guard let turnID = result["turn"]?["id"]?.stringValue else {
            throw AIChatError.protocolError
        }
        activeTurnByConversation[request.conversationID] = turnID
        continuation.yield(.responseCreated(turnID))
        for await notification in notifications {
            try Task.checkCancellation()
            guard notification.params["threadId"]?.stringValue == request.conversationID else {
                continue
            }
            switch notification.method {
            case "item/agentMessage/delta":
                guard notification.params["turnId"]?.stringValue == turnID,
                      let delta = notification.params["delta"]?.stringValue else { continue }
                continuation.yield(.textDelta(delta))
            case "turn/completed":
                guard notification.params["turn"]?["id"]?.stringValue == turnID else { continue }
                activeTurnByConversation.removeValue(forKey: request.conversationID)
                let status = notification.params["turn"]?["status"]?.stringValue
                if status == nil || status == "completed" {
                    continuation.yield(.completed)
                    return
                }
                throw status == "interrupted"
                    ? CancellationError()
                    : AIChatError.apiFailure(code: status)
            default:
                continue
            }
        }
        throw AIChatError.appServerTerminated
    }

    private func resolvedClient() throws -> any CodexAppServerServing {
        if let client { return client }
        if let clientFactory {
            let value = try clientFactory()
            client = value
            return value
        }
        guard let executableURL = resolvedExecutableURL() else {
            throw AIChatError.codexNotInstalled
        }
        let value = CodexAppServerClient(executableURL: executableURL)
        client = value
        return value
    }

    private func resolvedExecutableURL() -> URL? {
        CodexExecutableLocator(configuredPath: configuredExecutablePath).executableURL()
    }

    private nonisolated static func messages(from thread: CodexJSONValue?) -> [AIChatMessage] {
        let turns = thread?["turns"]?.arrayValue ?? []
        return turns.flatMap { turn in
            (turn["items"]?.arrayValue ?? []).compactMap { item in
                guard let type = item["type"]?.stringValue else { return nil }
                let role: AIChatMessageRole
                switch type {
                case "userMessage": role = .user
                case "agentMessage": role = .assistant
                default: return nil
                }
                let text = item["text"]?.stringValue
                    ?? item["content"]?.arrayValue?.compactMap {
                        $0["text"]?.stringValue
                    }.joined(separator: "\n")
                    ?? ""
                guard !text.isEmpty else { return nil }
                return AIChatMessage(
                    id: item["id"]?.stringValue ?? UUID().uuidString,
                    role: role,
                    text: text,
                    citations: [],
                    attachments: [],
                    isStreaming: false
                )
            }
        }
    }
}
