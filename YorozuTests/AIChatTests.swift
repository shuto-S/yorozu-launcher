import XCTest
@testable import Yorozu

final class AIChatStorageTests: XCTestCase {
    @MainActor
    func testProviderPreferencesDefaultToCodexAndFallbackWhenDisabled() {
        let defaults = UserDefaults(
            suiteName: "com.yorozu.provider-tests.\(UUID().uuidString)"
        )!
        let preferences = AIProviderPreferences(defaults: defaults)

        XCTAssertEqual(preferences.enabledProviderIDs, [.codex])
        XCTAssertEqual(preferences.defaultProviderID, .codex)

        preferences.setEnabled(true, for: .openAIAPI)
        XCTAssertEqual(preferences.enabledProviderIDs, [.codex, .openAIAPI])
        preferences.setEnabled(false, for: .codex)
        XCTAssertEqual(preferences.defaultProviderID, .openAIAPI)
        preferences.setEnabled(false, for: .openAIAPI)
        XCTAssertTrue(preferences.enabledProviderIDs.isEmpty)
        XCTAssertNil(preferences.defaultProviderID)
    }

    @MainActor
    func testProviderPreferencesPersistEnabledAndDefaultProviders() {
        let suiteName = "com.yorozu.provider-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let initial = AIProviderPreferences(defaults: defaults)
        initial.setEnabled(true, for: .openAIAPI)
        initial.setDefault(.openAIAPI)

        let restored = AIProviderPreferences(defaults: defaults)
        XCTAssertEqual(restored.enabledProviderIDs, [.codex, .openAIAPI])
        XCTAssertEqual(restored.defaultProviderID, .openAIAPI)
    }

    func testProviderRegistryKeepsMultipleProvidersAndRejectsUnknownID() async throws {
        let registry = AIProviderRegistry(providers: [
            RegistryTestProvider(providerID: .codex),
            RegistryTestProvider(providerID: .openAIAPI),
        ])

        let descriptors = await registry.descriptors()
        XCTAssertEqual(
            descriptors.map(\.id),
            [AIProviderID.codex, AIProviderID.openAIAPI]
        )
        let provider = try await registry.provider(for: AIProviderID.openAIAPI)
        XCTAssertEqual(provider.descriptor.id, AIProviderID.openAIAPI)
        do {
            _ = try await registry.provider(
                for: AIProviderID(rawValue: "unregistered")
            )
            XCTFail("Expected an unregistered provider error")
        } catch {
            XCTAssertEqual(
                error as? AIProviderRegistry.RegistryError,
                .providerNotRegistered
            )
        }
    }

    func testConversationIndexSeparatesIdenticalProviderConversationIDs() async throws {
        let fixture = try makeStore()
        let openAI = makeConversation(
            id: "shared-id",
            title: "OpenAI",
            providerID: .openAIAPI,
            lastMessageAt: Date(timeIntervalSince1970: 100)
        )
        let codex = makeConversation(
            id: "shared-id",
            title: "Codex",
            providerID: .codex,
            lastMessageAt: Date(timeIntervalSince1970: 200)
        )

        try await fixture.store.saveAIConversation(openAI)
        try await fixture.store.saveAIConversation(codex)

        let openAIValues = try await fixture.store.loadAIConversationIndex(
            providerID: .openAIAPI
        )
        let codexValues = try await fixture.store.loadAIConversationIndex(
            providerID: .codex
        )
        XCTAssertEqual(openAIValues, [openAI])
        XCTAssertEqual(codexValues, [codex])
    }

    func testCodexProviderStartsLazilyAndMapsCoreAppServerMethods() async throws {
        let server = FakeCodexAppServer()
        let provider = CodexAIProvider(clientFactory: { server })

        let methodsBeforeAvailability = await server.recordedMethods()
        let availability = await provider.availability()
        let methodsAfterAvailability = await server.recordedMethods()
        XCTAssertEqual(methodsBeforeAvailability, [])
        XCTAssertEqual(availability, .available)
        XCTAssertEqual(methodsAfterAvailability, [])

        let authenticationState = await provider.authenticationState()
        XCTAssertEqual(authenticationState, .authenticated(detail: "ChatGPT plus"))
        let models = try await provider.availableModels()
        XCTAssertEqual(models.map(\.rawValue), ["codex-test-model"])
        let conversationID = try await provider.createConversation(
            title: "Test",
            model: try XCTUnwrap(models.first)
        )
        XCTAssertEqual(conversationID, "thread-test")
        try await provider.setConversationArchived(
            conversationID: conversationID,
            title: "Test",
            model: models[0],
            isArchived: true
        )
        try await provider.setConversationArchived(
            conversationID: conversationID,
            title: "Test",
            model: models[0],
            isArchived: false
        )
        try await provider.deleteConversationCompletely(
            conversationID: conversationID
        )

        let methods = await server.recordedMethods()
        XCTAssertEqual(
            methods,
            [
                "account/read", "model/list", "thread/start",
                "thread/archive", "thread/unarchive", "thread/delete",
            ]
        )
    }

    func testCodexLoginCancelUsesReturnedLoginID() async throws {
        let server = FakeCodexAppServer()
        let provider = CodexAIProvider(clientFactory: { server })

        let url = try await provider.signInWithChatGPT()
        XCTAssertEqual(url.absoluteString, "https://example.com/login")
        await provider.cancelSignIn()

        let cancelLoginID = await server.params(
            for: "account/login/cancel"
        )?["loginId"]?.stringValue
        XCTAssertEqual(cancelLoginID, "login-test")
    }

    func testCodexStreamMapsDeltaCompletionAndInterrupt() async throws {
        let server = FakeCodexAppServer()
        let provider = CodexAIProvider(clientFactory: { server })
        let request = AIChatSendRequest(
            conversationID: "thread-test",
            model: AIModel(rawValue: "codex-test-model"),
            prompt: "Hello",
            attachments: [],
            enablesWebSearch: false,
            clientRequestID: "client-test"
        )

        var events: [String] = []
        for try await event in provider.streamResponse(request: request) {
            switch event {
            case .responseCreated: events.append("created")
            case let .textDelta(delta): events.append(delta)
            case .completed: events.append("completed")
            default: break
            }
        }
        XCTAssertEqual(events, ["created", "Hello", "completed"])

        await server.setCompletesTurns(false)
        let task = Task {
            for try await _ in provider.streamResponse(request: request) {}
        }
        await server.waitUntilRequested("turn/start", count: 2)
        await provider.stopGeneration(conversationID: "thread-test")
        task.cancel()
        _ = try? await task.value
        let methods = await server.recordedMethods()
        XCTAssertTrue(methods.contains("turn/interrupt"))
    }

    func testConversationIndexRoundTripsOnlyListMetadata() async throws {
        let fixture = try makeStore()
        let conversation = makeConversation(
            id: "conv-roundtrip",
            title: "A private title",
            model: .sol,
            isArchived: true,
            deletionState: .failed,
            lastMessageAt: Date(timeIntervalSince1970: 200)
        )

        try await fixture.store.saveAIConversation(conversation)
        let loaded = try await fixture.store.loadAIConversationIndex(
            providerID: .openAIAPI
        )

        XCTAssertEqual(loaded, [conversation])
    }

    func testCatalogSortsByLastMessageAndSearchesTitleLocally() async throws {
        let fixture = try makeStore()
        let older = makeConversation(
            id: "conv-older",
            title: "Swift concurrency",
            lastMessageAt: Date(timeIntervalSince1970: 100)
        )
        let newer = makeConversation(
            id: "conv-newer",
            title: "Travel planning",
            lastMessageAt: Date(timeIntervalSince1970: 200)
        )
        try await fixture.store.saveAIConversation(older)
        try await fixture.store.saveAIConversation(newer)

        let catalog = AIConversationCatalog(
            providerID: .openAIAPI,
            store: fixture.store
        )
        _ = await catalog.load()

        let allIDs = await catalog.search(query: "", scope: .active).map(\.id)
        let searchIDs = await catalog.search(query: "SWIFT", scope: .active).map(\.id)
        XCTAssertEqual(allIDs, ["conv-newer", "conv-older"])
        XCTAssertEqual(searchIDs, ["conv-older"])
    }

    func testConversationTitleUsesFirstNonEmptyLineAndSixtyCharacters() {
        let title = AIConversationSummary.title(
            from: "\n  \(String(repeating: "a", count: 80))\nSecond"
        )

        XCTAssertEqual(title.count, 60)
        XCTAssertEqual(title, String(repeating: "a", count: 60))
    }

    func testWebSearchToolIsIncludedOnlyWhenExplicitlyEnabled() {
        let disabled = OpenAIChatClient.responseBody(
            for: makeRequest(enablesWebSearch: false)
        )
        let enabled = OpenAIChatClient.responseBody(
            for: makeRequest(enablesWebSearch: true)
        )

        XCTAssertNil(disabled["tools"])
        XCTAssertNil(disabled["include"])
        XCTAssertNotNil(enabled["tools"])
        XCTAssertNotNil(enabled["include"])
    }

    func testSSEDecoderHandlesStreamingEventsAndCitations() throws {
        let created = try OpenAIChatClient.streamEvent(
            from: #"{"type":"response.created","response":{"id":"resp_1"}}"#
        )
        let delta = try OpenAIChatClient.streamEvent(
            from: #"{"type":"response.output_text.delta","delta":"Hello"}"#
        )
        let citation = try OpenAIChatClient.streamEvent(
            from: #"{"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://example.com/source","title":"Example","start_index":1,"end_index":8}}"#
        )
        let searching = try OpenAIChatClient.streamEvent(
            from: #"{"type":"response.output_item.added","item":{"type":"web_search_call"}}"#
        )
        let completed = try OpenAIChatClient.streamEvent(
            from: #"{"type":"response.completed"}"#
        )

        guard case .responseCreated("resp_1") = created else {
            return XCTFail("Expected response.created")
        }
        guard case .textDelta("Hello") = delta else {
            return XCTFail("Expected text delta")
        }
        guard case let .citation(value) = citation else {
            return XCTFail("Expected citation")
        }
        XCTAssertEqual(value.title, "Example")
        XCTAssertEqual(value.url.absoluteString, "https://example.com/source")
        guard case .webSearchStarted = searching else {
            return XCTFail("Expected web search event")
        }
        guard case .completed = completed else {
            return XCTFail("Expected completed event")
        }
        XCTAssertThrowsError(
            try OpenAIChatClient.streamEvent(from: #"{"type":"response.failed"}"#)
        )
    }

    func testAPIErrorMapsQuotaAndRateLimitWithoutUsingServerMessage() throws {
        let quota = Data(
            #"{"error":{"message":"sensitive server detail","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8
        )
        let rateLimit = Data(
            #"{"error":{"type":"rate_limit_error","code":"rate_limit_exceeded"}}"#.utf8
        )

        XCTAssertEqual(
            OpenAIChatClient.apiError(statusCode: 429, data: quota),
            .quotaExceeded
        )
        XCTAssertEqual(
            OpenAIChatClient.apiError(statusCode: 429, data: rateLimit),
            .rateLimited
        )
    }

    func testSSEDecoderMapsResponseFailureDetails() {
        XCTAssertThrowsError(
            try OpenAIChatClient.streamEvent(
                from: #"{"type":"response.failed","response":{"error":{"type":"server_error","code":"server_error"}}}"#
            )
        ) { error in
            XCTAssertEqual(error as? AIChatError, .serverUnavailable)
        }
    }

    func testSSEDecoderMapsNestedTopLevelErrorDetails() {
        XCTAssertThrowsError(
            try OpenAIChatClient.streamEvent(
                from: #"{"type":"error","error":{"type":"invalid_request_error","code":"model_not_found","message":"sensitive server detail"}}"#
            )
        ) { error in
            XCTAssertEqual(error as? AIChatError, .modelUnavailable)
        }
    }

    func testSSEDecoderPreservesOnlySafeUnknownErrorIdentifier() {
        XCTAssertThrowsError(
            try OpenAIChatClient.streamEvent(
                from: #"{"type":"error","code":"future_error<script>"}"#
            )
        ) { error in
            XCTAssertEqual(
                error as? AIChatError,
                .apiFailure(code: "future_errorscript")
            )
        }
    }

    func testMalformedSSEIsReportedAsProtocolError() {
        XCTAssertThrowsError(
            try OpenAIChatClient.streamEvent(from: "not-json")
        ) { error in
            XCTAssertEqual(error as? AIChatError, .streamProtocolError)
        }
    }

    func testSSELineNormalizerTreatsCRLFSeparatorAsEmptyLine() {
        XCTAssertEqual(OpenAIChatClient.normalizedSSELine("\r"), "")
        XCTAssertEqual(
            OpenAIChatClient.normalizedSSELine("data: {\"type\":\"response.created\"}\r"),
            "data: {\"type\":\"response.created\"}"
        )
        XCTAssertEqual(OpenAIChatClient.normalizedSSELine("data: keep"), "data: keep")
    }

    func testEachSSEDataLineIsDecodedWithoutWaitingForBlankSeparator() throws {
        let first = try OpenAIChatClient.streamEvent(
            fromSSELine: #"data: {"type":"response.output_text.delta","delta":"O"}"# + "\r"
        )
        let second = try OpenAIChatClient.streamEvent(
            fromSSELine: #"data: {"type":"response.output_text.delta","delta":"K"}"# + "\r"
        )

        guard case .textDelta("O") = first else {
            return XCTFail("Expected first SSE data line")
        }
        guard case .textDelta("K") = second else {
            return XCTFail("Expected second SSE data line")
        }
        XCTAssertNil(try OpenAIChatClient.streamEvent(fromSSELine: "data:\r"))
        XCTAssertNil(try OpenAIChatClient.streamEvent(fromSSELine: "event: ping\r"))
    }

    func testCitationFormatterBuildsVisibleInlineLinksAtAnnotationOffsets() {
        let citation = AIChatCitation(
            id: "citation-1",
            title: "Example",
            url: URL(string: "https://example.com/source")!,
            startIndex: 0,
            endIndex: 5
        )

        let markdown = AIChatCitationFormatter.markdown(
            text: "Hello world",
            citations: [citation]
        )

        XCTAssertEqual(
            markdown,
            "Hello [[1]](<https://example.com/source>) world"
        )
    }

    private func makeRequest(enablesWebSearch: Bool) -> AIChatSendRequest {
        AIChatSendRequest(
            conversationID: "conversation-test",
            model: .terra,
            prompt: "Hello",
            attachments: [],
            enablesWebSearch: enablesWebSearch,
            clientRequestID: "client-request-test"
        )
    }

    private func makeStore() throws -> (store: LauncherStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yorozu-ai-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = try LauncherStore(
            databaseURL: directory.appendingPathComponent("Yorozu.sqlite")
        )
        addTeardownBlock {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (store, directory)
    }

    private func makeConversation(
        id: String,
        title: String,
        providerID: AIProviderID = .openAIAPI,
        model: AIModel = .terra,
        isArchived: Bool = false,
        deletionState: AIConversationDeletionState? = nil,
        lastMessageAt: Date
    ) -> AIConversationSummary {
        AIConversationSummary(
            providerID: providerID,
            providerConversationID: id,
            title: title,
            model: model,
            isArchived: isArchived,
            deletionState: deletionState,
            createdAt: Date(timeIntervalSince1970: 50),
            lastMessageAt: lastMessageAt,
            updatedAt: lastMessageAt
        )
    }
}

@MainActor
final class AIChatViewModelTests: XCTestCase {
    func testPrepareForPresentationPreservesProviderDestinationAndDraft() async {
        let viewModel = makeViewModel(service: AIChatTestService())
        viewModel.beginNewChat()
        viewModel.prompt = "Provider-specific draft"

        viewModel.prepareForPresentation()

        XCTAssertEqual(viewModel.destination, .newChat)
        XCTAssertEqual(viewModel.prompt, "Provider-specific draft")
    }

    func testNewChatDoesNotCreateServerConversationUntilFirstSend() async throws {
        let service = AIChatTestService()
        let viewModel = makeViewModel(service: service)
        viewModel.prepareForPresentation()
        await waitUntil { viewModel.selectedListID != nil }

        viewModel.beginNewChat()
        let callsBeforeSend = await service.recordedCreateCallCount()
        XCTAssertEqual(callsBeforeSend, 0)

        viewModel.prompt = "Hello from Yorozu"
        viewModel.send()
        await waitUntil { !viewModel.isStreaming }

        let callsAfterSend = await service.recordedCreateCallCount()
        XCTAssertEqual(callsAfterSend, 1)
        XCTAssertEqual(viewModel.currentConversation?.title, "Hello from Yorozu")
        XCTAssertEqual(viewModel.messages.last?.text, "Hello")
    }

    func testModelChangeAppliesToTheNextRequest() async throws {
        let service = AIChatTestService()
        let viewModel = makeViewModel(service: service)
        await viewModel.testConnection()
        viewModel.beginNewChat()
        viewModel.chooseModel(.luna)
        viewModel.prompt = "Use Luna"

        viewModel.send()
        await waitUntil { !viewModel.isStreaming }

        let requestedModel = await service.recordedModel()
        XCTAssertEqual(requestedModel, .luna)
    }

    func testTitleSearchDoesNotCallOpenAI() async {
        let service = AIChatTestService()
        let conversation = makeConversation(title: "Swift concurrency")
        let viewModel = makeViewModel(
            service: service,
            conversations: [conversation]
        )
        viewModel.prepareForPresentation()
        await waitUntil { viewModel.visibleConversations.count == 1 }

        viewModel.query = "swift"
        await waitUntil { viewModel.visibleConversations.first?.id == conversation.id }

        let loadCalls = await service.recordedLoadCallCount()
        XCTAssertEqual(loadCalls, 0)
    }

    func testArchiveUpdatesRemoteMetadataBeforeRemovingFromActiveList() async {
        let service = AIChatTestService()
        let conversation = makeConversation(title: "Archive me")
        let viewModel = makeViewModel(
            service: service,
            conversations: [conversation]
        )
        viewModel.prepareForPresentation()
        await waitUntil { viewModel.visibleConversations.count == 1 }
        viewModel.selectListItem(conversation.id)

        viewModel.archiveSelectedConversation()
        await waitUntil {
            viewModel.conversations.first?.isArchived == true
                && viewModel.visibleConversations.isEmpty
        }

        let archiveState = await service.recordedArchiveState()
        XCTAssertEqual(archiveState, true)
    }

    func testCompleteDeleteRemovesLocalIndexOnlyAfterRemoteSuccess() async {
        let service = AIChatTestService()
        let conversation = makeConversation(title: "Delete me")
        let viewModel = makeViewModel(
            service: service,
            conversations: [conversation]
        )
        viewModel.prepareForPresentation()
        await waitUntil { viewModel.visibleConversations.count == 1 }
        viewModel.selectListItem(conversation.id)

        viewModel.deleteConversation(reference: conversation.reference) { _, _ in }
        await waitUntil { !viewModel.isDeleting && viewModel.conversations.isEmpty }

        let deleteCalls = await service.recordedDeleteCallCount()
        XCTAssertEqual(deleteCalls, 1)
    }

    func testDeleteFailureRemainsArchivedForRetry() async {
        let service = AIChatTestService(deleteShouldFail: true)
        let conversation = makeConversation(title: "Retry deletion")
        let viewModel = makeViewModel(
            service: service,
            conversations: [conversation]
        )
        viewModel.prepareForPresentation()
        await waitUntil { viewModel.visibleConversations.count == 1 }
        viewModel.selectListItem(conversation.id)

        viewModel.deleteConversation(reference: conversation.reference) { _, _ in }
        await waitUntil {
            !viewModel.isDeleting
                && viewModel.listScope == .archived
                && viewModel.conversations.first?.deletionState == .failed
        }

        XCTAssertEqual(viewModel.visibleConversations.first?.id, conversation.id)
        let deleteCalls = await service.recordedDeleteCallCount()
        XCTAssertEqual(deleteCalls, 1)
    }

    func testOnlyOneConversationCanGenerateAtATime() async {
        let service = AIChatTestService(streamDelay: .milliseconds(200))
        let viewModel = makeViewModel(service: service)
        viewModel.beginNewChat()
        viewModel.prompt = "First"
        viewModel.send()
        await waitUntil { viewModel.isStreaming }
        await waitUntilAsync {
            await service.recordedCreateCallCount() == 1
        }

        viewModel.beginNewChat()
        viewModel.prompt = "Second"
        XCTAssertFalse(viewModel.canSend)
        viewModel.send()
        let createCalls = await service.recordedCreateCallCount()
        XCTAssertEqual(createCalls, 1)

        await waitUntil { !viewModel.isStreaming }
    }

    func testStreamFailureReloadsConversationWithoutRetryingGeneration() async {
        let service = AIChatTestService(streamShouldFail: true)
        let viewModel = makeViewModel(service: service)
        viewModel.beginNewChat()
        viewModel.prompt = "Reconcile this response"

        viewModel.send()
        await waitUntil { !viewModel.isStreaming }

        XCTAssertEqual(viewModel.messages.first?.text, "Hello")
        let streamCalls = await service.recordedStreamCallCount()
        let loadCalls = await service.recordedLoadCallCount()
        XCTAssertEqual(streamCalls, 1)
        XCTAssertEqual(loadCalls, 1)
    }

    func testCompletedEventFinishesGenerationBeforeTransportCloses() async {
        let service = AIChatTestService(
            streamCompletionDelay: .seconds(3)
        )
        let viewModel = makeViewModel(service: service)
        viewModel.beginNewChat()
        viewModel.prompt = "Do not wait for the connection to close"

        viewModel.send()
        await waitUntil { !viewModel.isStreaming }

        XCTAssertEqual(viewModel.messages.last?.text, "Hello")
        XCTAssertFalse(viewModel.messages.last?.isStreaming ?? true)
    }

    func testAIConversationPageLeavesTextNavigationToComposer() {
        for keyCode: UInt16 in [36, 76, 126, 125, 48] {
            XCTAssertEqual(
                PaletteKeyEventPolicy.action(
                    keyCode: keyCode,
                    modifiers: [],
                    hasMarkedText: false,
                    route: .ai(providerID: .openAIAPI),
                    isActionPanelPresented: false,
                    isAIConversationPage: true
                ),
                .passThrough
            )
        }
        XCTAssertEqual(
            PaletteKeyEventPolicy.action(
                keyCode: 53,
                modifiers: [],
                hasMarkedText: false,
                route: .ai(providerID: .openAIAPI),
                isActionPanelPresented: false,
                isAIConversationPage: true
            ),
            .escape
        )
    }

    func testMarkedTextReturnPassesThroughOnAIListAndConversation() {
        for isConversation in [false, true] {
            XCTAssertEqual(
                PaletteKeyEventPolicy.action(
                    keyCode: 36,
                    modifiers: [],
                    hasMarkedText: true,
                    route: .ai(providerID: .openAIAPI),
                    isActionPanelPresented: false,
                    isAIConversationPage: isConversation
                ),
                .passThrough
            )
        }
    }

    private func makeViewModel(
        service: AIChatTestService,
        conversations: [AIConversationSummary] = []
    ) -> AIChatViewModel {
        let suite = "com.yorozu.ai-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return AIChatViewModel(
            catalog: AIConversationCatalog(
                providerID: .openAIAPI,
                store: nil,
                initialConversations: conversations
            ),
            provider: OpenAIAPIProvider(
                service: service,
                credentials: InMemoryOpenAICredentialStore(value: "test-key")
            ),
            preferences: AIChatPreferences(defaults: defaults)
        )
    }

    private func makeConversation(title: String) -> AIConversationSummary {
        AIConversationSummary(
            providerID: .openAIAPI,
            providerConversationID: "conversation-\(UUID().uuidString)",
            title: title,
            model: .terra,
            isArchived: false,
            deletionState: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            lastMessageAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for AI state")
    }

    private func waitUntilAsync(
        timeoutIterations: Int = 200,
        _ condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous AI state")
    }
}

private actor AIChatTestService: OpenAIChatServing {
    private(set) var createCallCount = 0
    private(set) var loadCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var streamCallCount = 0
    private(set) var lastRequestedModel: AIModel?
    private(set) var lastArchiveState: Bool?
    private let deleteShouldFail: Bool
    private let streamShouldFail: Bool
    nonisolated let streamDelay: Duration
    nonisolated let streamCompletionDelay: Duration

    init(
        deleteShouldFail: Bool = false,
        streamShouldFail: Bool = false,
        streamDelay: Duration = .zero,
        streamCompletionDelay: Duration = .zero
    ) {
        self.deleteShouldFail = deleteShouldFail
        self.streamShouldFail = streamShouldFail
        self.streamDelay = streamDelay
        self.streamCompletionDelay = streamCompletionDelay
    }

    func availableModelIDs(apiKey: String) -> Set<String> {
        Set(AIModel.openAIModels.map(\.rawValue))
    }

    func createConversation(
        apiKey: String,
        title: String,
        model: AIModel
    ) -> String {
        createCallCount += 1
        return "conv-test"
    }

    func updateConversation(
        apiKey: String,
        conversationID: String,
        title: String,
        model: AIModel,
        isArchived: Bool
    ) {
        lastArchiveState = isArchived
    }

    func loadConversation(
        apiKey: String,
        conversationID: String,
        limit: Int,
        after: String?
    ) -> AIConversationPage {
        loadCallCount += 1
        return AIConversationPage(
            messages: [
                AIChatMessage(
                    id: "assistant-test",
                    role: .assistant,
                    text: "Hello",
                    citations: [],
                    attachments: [],
                    isStreaming: false
                ),
            ],
            nextCursor: nil,
            hasMore: false
        )
    }

    func uploadAttachment(
        apiKey: String,
        attachment: AIChatAttachment
    ) throws -> AIUploadedAttachment {
        throw AIChatError.invalidAttachment
    }

    nonisolated func streamResponse(
        apiKey: String,
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let shouldFail = await self.recordStream(model: request.model)
                if shouldFail {
                    continuation.finish(throwing: AIChatError.invalidResponse)
                    return
                }
                if streamDelay > .zero {
                    try? await Task.sleep(for: streamDelay)
                }
                continuation.yield(.responseCreated("response-test"))
                continuation.yield(.textDelta("Hello"))
                continuation.yield(.completed)
                if streamCompletionDelay > .zero {
                    try? await Task.sleep(for: streamCompletionDelay)
                }
                continuation.finish()
            }
        }
    }

    func deleteConversationCompletely(
        apiKey: String,
        conversationID: String
    ) throws {
        deleteCallCount += 1
        if deleteShouldFail {
            throw AIChatError.deletionFailed
        }
    }

    private func recordStream(model: AIModel) -> Bool {
        streamCallCount += 1
        lastRequestedModel = model
        return streamShouldFail
    }

    func recordedCreateCallCount() -> Int {
        createCallCount
    }

    func recordedModel() -> AIModel? {
        lastRequestedModel
    }

    func recordedLoadCallCount() -> Int {
        loadCallCount
    }

    func recordedStreamCallCount() -> Int {
        streamCallCount
    }

    func recordedDeleteCallCount() -> Int {
        deleteCallCount
    }

    func recordedArchiveState() -> Bool? {
        lastArchiveState
    }
}

private actor FakeCodexAppServer: CodexAppServerServing {
    private var methods: [String] = []
    private var parameters: [String: CodexJSONValue] = [:]
    private var notificationContinuations:
        [UUID: AsyncStream<CodexAppServerNotification>.Continuation] = [:]
    private var completesTurns = true

    func request(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        methods.append(method)
        parameters[method] = params
        switch method {
        case "account/read":
            return .object([
                "account": .object(["planType": .string("plus")]),
            ])
        case "account/login/start":
            return .object([
                "type": .string("chatgpt"),
                "loginId": .string("login-test"),
                "authUrl": .string("https://example.com/login"),
            ])
        case "model/list":
            return .object([
                "data": .array([
                    .object([
                        "model": .string("codex-test-model"),
                        "displayName": .string("Codex Test"),
                        "description": .string("Test model"),
                        "isDefault": .bool(true),
                    ]),
                ]),
                "nextCursor": .null,
            ])
        case "thread/start":
            return .object([
                "thread": .object(["id": .string("thread-test")]),
            ])
        case "turn/start":
            if completesTurns {
                Task {
                    self.emit(
                        method: "item/agentMessage/delta",
                        params: .object([
                            "threadId": .string("thread-test"),
                            "turnId": .string("turn-test"),
                            "itemId": .string("item-test"),
                            "delta": .string("Hello"),
                        ])
                    )
                    self.emit(
                        method: "turn/completed",
                        params: .object([
                            "threadId": .string("thread-test"),
                            "turn": .object([
                                "id": .string("turn-test"),
                                "status": .string("completed"),
                            ]),
                        ])
                    )
                }
            }
            return .object([
                "turn": .object(["id": .string("turn-test")]),
            ])
        default:
            return .object([:])
        }
    }

    func notifications() async -> AsyncStream<CodexAppServerNotification> {
        let id = UUID()
        return AsyncStream { continuation in
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func stop() async {
        for continuation in notificationContinuations.values {
            continuation.finish()
        }
        notificationContinuations.removeAll()
    }

    func recordedMethods() -> [String] { methods }

    func params(for method: String) -> CodexJSONValue? {
        parameters[method]
    }

    func setCompletesTurns(_ value: Bool) {
        completesTurns = value
    }

    func waitUntilRequested(_ method: String, count: Int = 1) async {
        for _ in 0..<100 where methods.filter({ $0 == method }).count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func emit(method: String, params: CodexJSONValue) {
        let notification = CodexAppServerNotification(
            method: method,
            params: params
        )
        for continuation in notificationContinuations.values {
            continuation.yield(notification)
        }
    }

    private func removeContinuation(_ id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }
}

private actor RegistryTestProvider: AIChatProvider {
    nonisolated let descriptor: AIProviderDescriptor

    init(providerID: AIProviderID) {
        descriptor = AIProviderDescriptor(
            id: providerID,
            displayName: providerID.rawValue,
            rootCommandTitle: providerID.rawValue,
            description: "Test provider",
            symbolName: "sparkles",
            capabilities: [.streaming]
        )
    }

    func availability() -> AIProviderAvailability { .available }
    func authenticationState() -> AIAuthenticationState {
        .authenticated(detail: nil)
    }
    func availableModels() -> [AIModel] { [.terra] }
    func createConversation(title: String, model: AIModel) -> String { "test" }
    func updateConversation(
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
        AIConversationPage(messages: [], nextCursor: nil, hasMore: false)
    }
    func uploadAttachment(_ attachment: AIChatAttachment) throws -> AIUploadedAttachment {
        throw AIChatError.invalidAttachment
    }
    nonisolated func streamResponse(
        request: AIChatSendRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stopGeneration(conversationID: String) {}
    func deleteConversationCompletely(conversationID: String) {}
    func shutdown() {}
}
