import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case windowControl
    case keepAwake
    case clipboard
    case ai
    case shortcuts

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general:
            "settings.sidebar.general"
        case .windowControl:
            "Window Control"
        case .keepAwake:
            "Keep Awake"
        case .clipboard:
            "Clipboard"
        case .ai:
            "AI"
        case .shortcuts:
            "settings.sidebar.shortcuts"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            "gearshape"
        case .windowControl:
            "macwindow"
        case .keepAwake:
            "cup.and.saucer"
        case .clipboard:
            "clipboard"
        case .ai:
            "sparkles"
        case .shortcuts:
            "keyboard"
        }
    }
}

struct SettingsView: View {
    var viewModel: LauncherViewModel
    var appUpdateController: AppUpdateController?
    @State private var selection: SettingsDestination? = .general
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.symbolName)
                    .tag(destination)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = destination
                        isSidebarFocused = true
                    }
                    .accessibilityIdentifier(
                        "settings.destination.\(destination.rawValue)"
                    )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(width: 190)
            .focusable()
            .focused($isSidebarFocused)
            .onMoveCommand(perform: moveSidebarSelection)

            Divider()
                .accessibilityHidden(true)

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .accessibilityIdentifier("launcher.settings")
        .onAppear {
            isSidebarFocused = true
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsView(
                viewModel: viewModel,
                appUpdateController: appUpdateController
            )
        case .windowControl:
            WindowControlSettingsView(
                controller: viewModel.windowControlController
            )
        case .keepAwake:
            KeepAwakeSettingsView(controller: viewModel.keepAwakeController)
        case .clipboard:
            ClipboardSettingsView(viewModel: viewModel)
        case .ai:
            AISettingsView(launcherViewModel: viewModel)
        case .shortcuts:
            ShortcutsSettingsView(settings: viewModel.shortcutSettings)
        }
    }

    private func moveSidebarSelection(_ direction: MoveCommandDirection) {
        let destinations = SettingsDestination.allCases
        let current = selection.flatMap(destinations.firstIndex) ?? 0
        switch direction {
        case .down:
            selection = destinations[min(current + 1, destinations.count - 1)]
        case .up:
            selection = destinations[max(current - 1, 0)]
        default:
            break
        }
    }
}

private struct WindowControlSettingsView: View {
    @ObservedObject var controller: WindowControlController

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Enable Window Control",
                    isOn: $controller.isEnabled
                )
                .disabled(
                    !controller.isConfigurationValid && !controller.isEnabled
                )
                .accessibilityIdentifier("settings.window-control.enabled")

                LabeledContent("Status") {
                    Text(controller.runtimeStatus.title)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier(
                            "settings.window-control.status"
                        )
                }

                if !controller.isConfigurationValid {
                    Text("Set different key combinations for Move Window and Resize Window before enabling this feature.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if controller.runtimeStatus == .active,
                   let activity = controller.lastActivity {
                    Text(activity.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "settings.window-control.activity"
                        )
                }
            } header: {
                Text("Window Control")
            } footer: {
                Text("Hold the configured keys and drag with the primary mouse button or trackpad click. A preview appears at the top, left, or right edge. Release the drag to apply it.")
            }

            Section("Gestures") {
                modifierRow(for: .move)
                modifierRow(for: .resize)

                if let validationMessage = controller.validationMessage {
                    Label(
                        validationMessage,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        "settings.window-control.validation"
                    )
                }
            }

            Section {
                LabeledContent("Accessibility") {
                    Label(
                        controller.isAccessibilityGranted
                            ? "Allowed"
                            : "Not Allowed",
                        systemImage: controller.isAccessibilityGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(
                        controller.isAccessibilityGranted
                            ? AnyShapeStyle(.green)
                            : AnyShapeStyle(.orange)
                    )
                }

                HStack {
                    if !controller.isAccessibilityGranted {
                        Button("Request Access") {
                            controller.requestAccessibilityAccess()
                        }
                    }

                    Button("Open Accessibility Settings") {
                        controller.openAccessibilitySettings()
                    }

                    Button("Reveal This Build") {
                        controller.revealCurrentBuild()
                    }

                    Spacer()

                    Button("Check Again") {
                        controller.refreshAuthorization()
                    }
                }

                if !controller.isAccessibilityGranted,
                   controller.codeSigningStatus == .adHoc {
                    Label(
                        "This build uses an ad hoc signature. Accessibility permission may be lost after rebuilding.",
                        systemImage: "signature"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("Window Control uses Accessibility to identify and update the window under the pointer. It does not require a separate Input Monitoring permission.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("settings.detail.window-control")
    }

    @ViewBuilder
    private func modifierRow(for operation: WindowControlOperation) -> some View {
        LabeledContent(operation.title) {
            HStack(spacing: 8) {
                WindowControlModifierRecorder(
                    chord: Binding(
                        get: {
                            controller.configuration.chord(for: operation)
                        },
                        set: { chord in
                            controller.setChord(chord, for: operation)
                        }
                    )
                )
                .accessibilityIdentifier(
                    "settings.window-control.\(operation.rawValue)-recorder"
                )

                Button("Clear") {
                    controller.setChord(nil, for: operation)
                }
                .disabled(
                    controller.configuration.chord(for: operation) == nil
                )
                .accessibilityIdentifier(
                    "settings.window-control.\(operation.rawValue)-clear"
                )
            }
        }
    }

    private var statusColor: Color {
        switch controller.runtimeStatus {
        case .active:
            .green
        case .permissionRequired, .unavailable:
            .orange
        case .off, .needsConfiguration:
            .secondary
        }
    }
}

@MainActor
private final class WindowControlModifierCapture: ObservableObject {
    @Published private(set) var isRecording = false
    private var eventMonitor: Any?
    private var pendingChord: WindowControlModifierChord?
    private var completion: ((WindowControlModifierChord?) -> Void)?

    func begin(
        completion: @escaping (WindowControlModifierChord?) -> Void
    ) {
        stop()
        self.completion = completion
        pendingChord = nil
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        pendingChord = nil
        completion = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            let chord = WindowControlModifierChord(
                eventFlags: event.modifierFlags.cgEventFlags
            )
            if chord.isEmpty {
                if let pendingChord {
                    let completion = completion
                    stop()
                    completion?(pendingChord)
                }
            } else if chord.rawValue.nonzeroBitCount
                >= (pendingChord?.rawValue.nonzeroBitCount ?? 0) {
                pendingChord = chord
            }
            return nil

        case .keyDown where event.keyCode == 53:
            stop()
            return nil

        case .keyDown where event.keyCode == 51 || event.keyCode == 117:
            let completion = completion
            stop()
            completion?(nil)
            return nil

        default:
            return event
        }
    }

}

private struct WindowControlModifierRecorder: View {
    @Binding var chord: WindowControlModifierChord?
    @StateObject private var capture = WindowControlModifierCapture()

    var body: some View {
        Button(capture.isRecording ? "Press Modifier Keys…" : chordTitle) {
            capture.begin { value in
                chord = value
            }
        }
        .onDisappear {
            capture.stop()
        }
        .accessibilityLabel("Modifier key combination")
        .accessibilityValue(chordTitle)
    }

    private var chordTitle: String {
        chord?.displayTitle ?? "Not Set"
    }
}

private extension NSEvent.ModifierFlags {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

private struct KeepAwakeSettingsView: View {
    @Bindable var controller: KeepAwakeController

    var body: some View {
        Form {
            Section {
                Toggle("Keep Mac Awake", isOn: enabledBinding)
                    .accessibilityIdentifier("settings.keep-awake.enabled")

                Picker("Default Duration", selection: $controller.defaultDuration) {
                    ForEach(KeepAwakeDuration.choices, id: \.self) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .accessibilityIdentifier("settings.keep-awake.default-duration")

                Toggle(
                    "Show Separate Menu Bar Icon",
                    isOn: $controller.showsSeparateMenuBarIcon
                )
                .accessibilityIdentifier("settings.keep-awake.menu-bar-icon")
            } header: {
                Text("Keep Awake")
            } footer: {
                Text("Prevents idle display and system sleep. Manual sleep, closing the lid, and system power protections can still put your Mac to sleep.")
            }

            if controller.isActive {
                Section("Current Session") {
                    LabeledContent("Status") {
                        Text(controller.statusSubtitle)
                    }
                    LabeledContent("Duration") {
                        Text(controller.activeDuration?.title ?? "Unknown")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("settings.detail.keep-awake")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.isActive },
            set: { isEnabled in
                if isEnabled {
                    controller.start(for: controller.defaultDuration)
                } else {
                    controller.stop()
                }
            }
        )
    }
}

private struct AISettingsView: View {
    var launcherViewModel: LauncherViewModel
    @ObservedObject private var providerPreferences: AIProviderPreferences
    @State private var selectedProviderID: AIProviderID?

    init(launcherViewModel: LauncherViewModel) {
        self.launcherViewModel = launcherViewModel
        providerPreferences = launcherViewModel.aiProviderPreferences
        _selectedProviderID = State(
            initialValue: launcherViewModel.resolvedAISettingsProviderID(
                preferred: launcherViewModel.aiProviderPreferences.defaultProviderID
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            defaultProviderHeader
            Divider().accessibilityHidden(true)
            providerTabs
            Divider().accessibilityHidden(true)

            if let selectedViewModel {
                AIProviderSettingsDetailView(
                    launcherViewModel: launcherViewModel,
                    providerPreferences: providerPreferences,
                    viewModel: selectedViewModel,
                    chatPreferences: selectedViewModel.preferences
                )
            } else {
                ContentUnavailableView(
                    "No AI Providers Available",
                    systemImage: "sparkles",
                    description: Text("Add an AI provider to configure AI Chat.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.clear)
        .accessibilityIdentifier("settings.detail.ai")
        .onAppear {
            normalizeProviderSelection()
            refreshSelectedProvider()
        }
        .onChange(of: selectedProviderID) { _, providerID in
            guard providerID != nil else { return }
            refreshSelectedProvider()
        }
        .onChange(of: providerIDs) {
            normalizeProviderSelection()
        }
    }

    private var providerViewModels: [AIChatViewModel] {
        launcherViewModel.aiProviderViewModels
    }

    private var providerIDs: [AIProviderID] {
        providerViewModels.map(\.providerID)
    }

    private var enabledProviderViewModels: [AIChatViewModel] {
        providerViewModels.filter {
            providerPreferences.isEnabled($0.providerID)
        }
    }

    private var selectedViewModel: AIChatViewModel? {
        selectedProviderID.flatMap(launcherViewModel.aiChatViewModel(for:))
    }

    private var defaultProviderBinding: Binding<AIProviderID?> {
        Binding(
            get: { providerPreferences.defaultProviderID },
            set: { providerPreferences.setDefault($0) }
        )
    }

    private var defaultProviderHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Text("Default Provider")
                    .font(.headline)
                Spacer()
                Picker("Default Provider", selection: defaultProviderBinding) {
                    ForEach(enabledProviderViewModels, id: \.providerID) { viewModel in
                        Text(viewModel.providerDescriptor.displayName)
                            .tag(Optional(viewModel.providerID))
                    }
                    if enabledProviderViewModels.isEmpty {
                        Text("None").tag(Optional<AIProviderID>.none)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityIdentifier("settings.ai.default-provider")
            }
            Text("The AI shortcut opens this provider when no provider is specified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var providerTabs: some View {
        if providerViewModels.isEmpty {
            EmptyView()
        } else {
            Picker("Provider", selection: $selectedProviderID) {
                ForEach(providerViewModels, id: \.providerID) { viewModel in
                    Label(
                        viewModel.providerDescriptor.displayName,
                        systemImage: viewModel.providerDescriptor.symbolName
                    )
                    .tag(Optional(viewModel.providerID))
                    .accessibilityIdentifier(
                        "settings.ai.provider.\(viewModel.providerID.rawValue)"
                    )
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .accessibilityIdentifier("settings.ai.provider-tabs")
        }
    }

    private func normalizeProviderSelection() {
        selectedProviderID = launcherViewModel.resolvedAISettingsProviderID(
            preferred: selectedProviderID
        )
    }

    private func refreshSelectedProvider() {
        guard let selectedViewModel else { return }
        selectedViewModel.loadCredentialStatus()
        guard selectedViewModel.providerDescriptor.capabilities.contains(.modelSelection) else {
            return
        }
        Task {
            await selectedViewModel.loadModelMetadataForSettings()
        }
    }
}

private struct AIProviderSettingsDetailView: View {
    var launcherViewModel: LauncherViewModel
    @ObservedObject var providerPreferences: AIProviderPreferences
    @Bindable var viewModel: AIChatViewModel
    @ObservedObject var chatPreferences: AIChatPreferences

    var body: some View {
        VStack(spacing: 0) {
            providerHeader
            Divider()
                .accessibilityHidden(true)
            Form {
                connectionSection
                if showsChatDefaults {
                    chatDefaultsSection
                }
                Section("Data and Billing") {
                    Text(dataAndBillingDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(Color.clear)
        .accessibilityIdentifier(
            "settings.ai.provider-detail.\(viewModel.providerID.rawValue)"
        )
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: viewModel.providerDescriptor.symbolName)
                    .imageScale(.large)
                    .frame(width: 28)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.providerDescriptor.displayName)
                        .font(.headline)
                    Text(viewModel.providerDescriptor.description)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    if providerPreferences.defaultProviderID == viewModel.providerID {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Enabled", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .fixedSize()
                        .accessibilityLabel(
                            "Enable \(viewModel.providerDescriptor.displayName)"
                        )
                        .accessibilityIdentifier(
                            "settings.ai.enabled.\(viewModel.providerID.rawValue)"
                        )
                }
            }
            if !providerPreferences.isEnabled(viewModel.providerID) {
                Text("Enable this provider to show it in Root Search and use it from the AI shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var connectionSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: viewModel.credentialStatusSymbolName)
                    .foregroundStyle(
                        viewModel.credentialStatus == .saved
                            ? AnyShapeStyle(.tint)
                            : AnyShapeStyle(.secondary)
                    )
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.credentialStatusTitle)
                        .font(.headline)
                    Text(viewModel.credentialStatusDetail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.credentialStatus == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh Status") {
                        viewModel.loadCredentialStatus()
                    }
                    .buttonStyle(.link)
                }
            }

            AIProviderConnectionSettingsView(
                launcherViewModel: launcherViewModel,
                providerPreferences: providerPreferences,
                viewModel: viewModel
            )

            if let message = viewModel.credentialStatusMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.ai.credential-message")
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(connectionDescription)
        }
    }

    private var chatDefaultsSection: some View {
        Section("Chat Defaults") {
            if viewModel.providerDescriptor.capabilities.contains(.modelSelection),
               !viewModel.availableModels.isEmpty {
                Picker("Model", selection: viewModel.preferencesBinding) {
                    ForEach(viewModel.availableModels) { model in
                        Text(model.title).tag(model)
                    }
                }
                .accessibilityLabel("Model")
            }
            if viewModel.providerDescriptor.capabilities.contains(.reasoningEffort),
               !viewModel.defaultModelReasoningEfforts.isEmpty {
                Picker(
                    "Reasoning",
                    selection: viewModel.reasoningPreferenceBinding
                ) {
                    Text("Model Default")
                        .tag(Optional<AIReasoningEffort>.none)
                    ForEach(viewModel.defaultModelReasoningEfforts) { effort in
                        Text(effort.title).tag(Optional(effort))
                    }
                }
                .accessibilityLabel("Reasoning")
                Text("Used when starting a new chat. Model Default follows the selected model’s recommendation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.providerDescriptor.capabilities.contains(.webSearch) {
                Toggle(
                    "Enable Web Search for New Chats",
                    isOn: viewModel.webSearchPreferenceBinding
                )
            }
        }
    }

    private var showsChatDefaults: Bool {
        let capabilities = viewModel.providerDescriptor.capabilities
        return capabilities.contains(.webSearch)
            || capabilities.contains(.reasoningEffort)
            || (capabilities.contains(.modelSelection) && !viewModel.availableModels.isEmpty)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { providerPreferences.isEnabled(viewModel.providerID) },
            set: { providerPreferences.setEnabled($0, for: viewModel.providerID) }
        )
    }

    private var connectionDescription: String {
        switch viewModel.providerID {
        case .codex:
            "Yorozu communicates with the installed Codex app-server. Codex manages ChatGPT authentication; Yorozu never reads or stores its tokens."
        case .openAIAPI:
            "Your API key is stored in macOS Keychain. Yorozu never writes it to its database or logs."
        case .claude:
            "Your Anthropic API key is stored in macOS Keychain. Yorozu never writes it to its database or logs."
        case .ollama:
            "Yorozu connects to the local Ollama service. No API key or cloud account is required."
        default:
            "Authentication is managed by \(viewModel.providerDescriptor.displayName)."
        }
    }

    private var dataAndBillingDescription: String {
        switch viewModel.providerID {
        case .codex:
            "Codex usage follows your ChatGPT plan. Yorozu stores only chat titles and the Codex thread IDs it indexes."
        case .openAIAPI:
            "OpenAI API usage is billed to your API Platform account. Conversation messages and uploaded files are stored by OpenAI."
        case .claude:
            "Anthropic API usage is billed to your Anthropic account. Conversation messages are sent to Anthropic for processing."
        case .ollama:
            "Models run on this Mac through Ollama. Yorozu does not send Ollama messages to a cloud provider."
        default:
            "Usage, data retention, and billing are managed by \(viewModel.providerDescriptor.displayName)."
        }
    }
}

private struct AIProviderConnectionSettingsView: View {
    var launcherViewModel: LauncherViewModel
    @ObservedObject var providerPreferences: AIProviderPreferences
    @Bindable var viewModel: AIChatViewModel

    @ViewBuilder
    var body: some View {
        switch viewModel.providerID {
        case .codex:
            LabeledContent("Codex Executable") {
                Text(
                    providerPreferences.codexExecutablePath.isEmpty
                        ? "Detected automatically"
                        : providerPreferences.codexExecutablePath
                )
                .lineLimit(1)
            }
            ViewThatFits(in: .horizontal) {
                codexActions
                codexActionsVertical
            }
        case .openAIAPI:
            ViewThatFits(in: .horizontal) {
                openAIActions
                openAIActionsVertical
            }
        case .claude:
            ViewThatFits(in: .horizontal) {
                claudeActions
                claudeActionsVertical
            }
        case .ollama:
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Service") {
                    Text("Local Ollama")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(ollamaModelSummary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Models") {
                        viewModel.refreshAvailableModels()
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private var ollamaModelSummary: String {
        guard viewModel.hasLoadedAvailableModels else {
            return "Model list not loaded"
        }
        let count = viewModel.availableModels.count
        if count == 0 {
            return "No installed models detected"
        }
        return count == 1
            ? "1 installed model"
            : "\(count) installed models"
    }

    private var codexActions: some View {
        HStack {
            codexExecutableButton
            Button("Sign In with ChatGPT") { viewModel.signInWithChatGPT() }
            codexSignOutButton
        }
    }

    private var codexActionsVertical: some View {
        VStack(alignment: .leading) {
            codexExecutableButton
            Button("Sign In with ChatGPT") { viewModel.signInWithChatGPT() }
            codexSignOutButton
        }
    }

    private var codexExecutableButton: some View {
        Button(
            providerPreferences.codexExecutablePath.isEmpty
                ? "Set Executable Path…"
                : "Change Executable Path…"
        ) {
            launcherViewModel.presentCodexExecutablePathModal()
        }
    }

    private var codexSignOutButton: some View {
        Button("Sign Out", role: .destructive) {
            launcherViewModel.requestCodexSignOut()
        }
        .disabled(viewModel.credentialStatus != .saved)
    }

    private var openAIActions: some View {
        HStack {
            openAIKeyButton
            openAITestButton
            openAIRemoveButton
        }
    }

    private var openAIActionsVertical: some View {
        VStack(alignment: .leading) {
            openAIKeyButton
            openAITestButton
            openAIRemoveButton
        }
    }

    private var openAIKeyButton: some View {
        Button(viewModel.hasAPIKey ? "Replace API Key…" : "Set API Key…") {
            launcherViewModel.presentOpenAIAPIKeyModal()
        }
    }

    private var openAITestButton: some View {
        Button("Test Connection") {
            Task { await viewModel.testConnection() }
        }
        .disabled(!viewModel.hasAPIKey)
    }

    private var openAIRemoveButton: some View {
        Button("Remove Key", role: .destructive) {
            launcherViewModel.requestOpenAIAPIKeyRemoval()
        }
        .disabled(!viewModel.hasAPIKey)
    }

    private var claudeActions: some View {
        HStack {
            claudeKeyButton
            claudeTestButton
            claudeRemoveButton
        }
    }

    private var claudeActionsVertical: some View {
        VStack(alignment: .leading) {
            claudeKeyButton
            claudeTestButton
            claudeRemoveButton
        }
    }

    private var claudeKeyButton: some View {
        Button(viewModel.hasAPIKey ? "Replace API Key…" : "Set API Key…") {
            launcherViewModel.presentClaudeAPIKeyModal()
        }
    }

    private var claudeTestButton: some View {
        Button("Test Connection") {
            Task { await viewModel.testConnection() }
        }
        .disabled(!viewModel.hasAPIKey)
    }

    private var claudeRemoveButton: some View {
        Button("Remove Key", role: .destructive) {
            launcherViewModel.requestClaudeAPIKeyRemoval()
        }
        .disabled(!viewModel.hasAPIKey)
    }
}

private struct GeneralSettingsView: View {
    var viewModel: LauncherViewModel
    var appUpdateController: AppUpdateController?
    @ObservedObject private var inputModeController: CommandInputModeController
    private var launchAtLoginController: LaunchAtLoginController

    init(
        viewModel: LauncherViewModel,
        appUpdateController: AppUpdateController?
    ) {
        self.viewModel = viewModel
        self.appUpdateController = appUpdateController
        inputModeController = viewModel.commandInputModeController
        launchAtLoginController = viewModel.launchAtLoginController
    }

    var body: some View {
        Form {
            if let notice = viewModel.storageRecoveryNotice {
                Section {
                    Text("Yorozu recovered from a storage problem and created a new local database.")

                    LabeledContent("Recovered") {
                        Text(notice.recoveredAt, format: .dateTime)
                    }

                    HStack {
                        Button("Reveal Backup") {
                            viewModel.revealStorageRecoveryBackup()
                        }
                        Button("Dismiss") {
                            viewModel.dismissStorageRecoveryNotice()
                        }
                    }
                } header: {
                    Text("Storage Recovery")
                } footer: {
                    Text("The previous database was preserved for manual recovery.")
                }
            }

            Section {
                Toggle(
                    "Open Yorozu at Login",
                    isOn: Binding(
                        get: { launchAtLoginController.isEnabled },
                        set: { launchAtLoginController.setEnabled($0) }
                    )
                )
                .disabled(launchAtLoginController.isUpdating)
                .accessibilityIdentifier("settings.login-item.enabled")

                LabeledContent("Status") {
                    Text(launchAtLoginController.status.title)
                        .foregroundStyle(loginItemStatusColor)
                        .accessibilityIdentifier("settings.login-item.status")
                }

                if launchAtLoginController.status == .requiresApproval {
                    HStack {
                        Button("Open Login Items Settings") {
                            launchAtLoginController.openSystemSettings()
                        }
                        .accessibilityIdentifier(
                            "settings.login-item.open-system-settings"
                        )

                        Spacer()

                        Button("Check Again") {
                            launchAtLoginController.refresh()
                        }
                        .accessibilityIdentifier("settings.login-item.check-again")
                    }

                    Text("Allow Yorozu in Login Items to start it automatically after you sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = launchAtLoginController.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.login-item.error")
                }
            } header: {
                Text("Login")
            } footer: {
                Text("Yorozu starts quietly in the menu bar. The launcher does not open until you use its shortcut.")
            }

            Section {
                Toggle(
                    "Use Command keys to switch input mode",
                    isOn: $inputModeController.isEnabled
                )
                .accessibilityIdentifier("settings.input-mode.enabled")

                Text("Press Left Command alone for English and Right Command alone for Japanese.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if inputModeController.isEnabled {
                    LabeledContent("Current Input Source") {
                        Text(
                            inputModeController.currentInputSourceName
                                ?? inputModeController.currentInputSourceID
                                ?? "Unavailable"
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier(
                        "settings.input-mode.current-source"
                    )

                    permissionRow(
                        title: "Input Monitoring",
                        isGranted: inputModeController.isInputMonitoringGranted,
                        request: inputModeController.requestInputMonitoringAccess
                    )

                    HStack {
                        Button("Open Input Monitoring Settings") {
                            inputModeController.openInputMonitoringSettings()
                        }
                        .accessibilityIdentifier(
                            "settings.input-mode.open-input-monitoring"
                        )

                        Button("Reveal This Build") {
                            inputModeController.revealCurrentBuild()
                        }
                        .accessibilityIdentifier(
                            "settings.input-mode.reveal-current-build"
                        )

                        Spacer()

                        Button("Check Again") {
                            inputModeController.refreshAuthorization()
                        }
                        .accessibilityIdentifier(
                            "settings.input-mode.check-again"
                        )
                    }

                    if !inputModeController.isInputMonitoringGranted {
                        Text("Allow this copy of Yorozu in Input Monitoring so the Command keys can be detected while other apps are active. If Yorozu already appears allowed, remove the older entry and add the build revealed below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "settings.input-mode.permission-guidance"
                            )

                        if inputModeController.codeSigningStatus == .adHoc {
                            Label(
                                "This build uses an ad hoc signature. Input Monitoring permission may be lost after rebuilding.",
                                systemImage: "signature"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier(
                                "settings.input-mode.adhoc-warning"
                            )
                        }
                    } else if inputModeController.runtimeStatus == .unavailable {
                        Label(
                            "Yorozu couldn’t start input mode switching. Restart the app and check again.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "settings.input-mode.unavailable"
                        )
                    }

                    if let report = inputModeController.lastSwitchReport {
                        LabeledContent("Last Switch") {
                            Text(report.result.title)
                                .foregroundStyle(
                                    inputModeSwitchResultColor(report.result)
                                )
                        }
                        LabeledContent("Input Source") {
                            Text(inputModeSourceTransition(report))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }

                        switch report.result {
                        case let .sourceUnavailable(action):
                            Label(
                                "No enabled \(action.title) input source is available. Add one in Keyboard settings, then try again.",
                                systemImage: "keyboard.badge.ellipsis"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        case .selectionFailed, .verificationTimedOut:
                            Label(
                                "Yorozu detected the Command key but macOS did not select the requested input source. Check the available input sources and try again.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        case .switched, .alreadySelected, .cancelled:
                            EmptyView()
                        }
                    }

                    LabeledContent("Accessibility") {
                        Text(
                            inputModeController.isAccessibilityGranted
                                ? "Allowed" : "Not Allowed"
                        )
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Event Posting") {
                        Text(
                            inputModeController.isEventPostingGranted
                                ? "Allowed" : "Not Allowed"
                        )
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Monitor") {
                        Text(inputModeController.monitorStatus.title)
                            .foregroundStyle(.secondary)
                    }
                    if let lastCommandEventAt =
                        inputModeController.lastCommandEventAt {
                        LabeledContent("Last Command Event") {
                            Text(lastCommandEventAt, format: .dateTime)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let lastAction = inputModeController.lastAction {
                        LabeledContent("Last Action") {
                            Text(lastAction.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Input Mode Switching")
            } footer: {
                Text("Input Monitoring is required for the listen-only Command monitor. Yorozu selects enabled macOS input sources directly; it does not synthesize Eisu or Kana key events. Command shortcuts and regular Command clicks continue to work normally.")
            }

            Section {
                LabeledContent("settings.index-count") {
                    Text(viewModel.indexCount, format: .number)
                }

                LabeledContent("settings.last-indexed") {
                    if let lastIndexedAt = viewModel.lastIndexedAt {
                        Text(lastIndexedAt, format: .dateTime)
                    } else {
                        Text("settings.never")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button {
                        Task {
                            await viewModel.reindex()
                        }
                    } label: {
                        if viewModel.isIndexing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("settings.reindex")
                        }
                    }
                    .disabled(viewModel.isIndexing)
                } label: {
                    Text("settings.application-index")
                }
            } header: {
                Text("settings.general.index-section")
            } footer: {
                Text("settings.general.index-footer")
            }

            Section {
                LabeledContent("Installed Version") {
                    Text(installedVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier(
                            "settings.software-update.version"
                        )
                }

                HStack {
                    Button {
                        appUpdateController?.checkForUpdates()
                    } label: {
                        Label(
                            String(localized: "menu.check-for-updates"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(appUpdateController?.canCheckForUpdates != true)
                    .accessibilityIdentifier(
                        "settings.software-update.check"
                    )

                    Button {
                        if let appUpdateController {
                            appUpdateController.openLatestRelease()
                        } else {
                            NSWorkspace.shared.open(
                                AppUpdateController.latestReleaseURL
                            )
                        }
                    } label: {
                        Label(
                            String(localized: "menu.view-latest-release"),
                            systemImage: "safari"
                        )
                    }
                    .accessibilityIdentifier(
                        "settings.software-update.latest-release"
                    )
                }

                if appUpdateController?.canCheckForUpdates != true {
                    Text("Update checks are available in signed Release builds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text("Yorozu verifies updates from its signed GitHub Releases feed before installation.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("settings.detail.general")
        .onAppear {
            inputModeController.refreshAuthorization()
            launchAtLoginController.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            inputModeController.refreshAuthorization()
            launchAtLoginController.refresh()
        }
    }

    private var loginItemStatusColor: Color {
        switch launchAtLoginController.status {
        case .enabled:
            .green
        case .requiresApproval:
            .orange
        case .notRegistered, .unavailable:
            .secondary
        }
    }

    private var installedVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        return switch (version, build) {
        case let (.some(version), .some(build)):
            "\(version) (\(build))"
        case let (.some(version), .none):
            version
        case let (.none, .some(build)):
            build
        case (.none, .none):
            "Unknown"
        }
    }

    private func inputModeSwitchResultColor(
        _ result: CommandInputModeSwitchResult
    ) -> Color {
        switch result {
        case .switched, .alreadySelected:
            .green
        case .cancelled:
            .secondary
        case .sourceUnavailable, .selectionFailed, .verificationTimedOut:
            .orange
        }
    }

    private func inputModeSourceTransition(
        _ report: CommandInputModeSwitchReport
    ) -> String {
        let before = report.sourceIDBefore ?? "Unknown"
        let after = report.sourceIDAfter ?? "Unknown"
        return "\(before) → \(after)"
    }

    private func permissionRow(
        title: String,
        isGranted: Bool,
        request: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(isGranted ? "Allowed" : "Permission Required")
                    .foregroundStyle(isGranted ? Color.green : Color.secondary)
                if !isGranted {
                    Button("Request Access", action: request)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct ShortcutsSettingsView: View {
    @ObservedObject var settings: AppShortcutSettings

    var body: some View {
        Form {
            Section {
                ForEach(AppShortcutCatalog.settings) { shortcut in
                    LabeledContent {
                        KeyboardShortcuts.Recorder(
                            shortcut: settings.binding(for: shortcut)
                        )
                            .shortcutValidation { candidate in
                                settings.validation(
                                    for: shortcut,
                                    shortcut: candidate
                                )
                            }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.title)
                            Text(shortcut.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                LabeledContent {
                    Button("Reset Shortcuts") {
                        settings.reset()
                    }
                } label: {
                    Text("Defaults")
                }
            } header: {
                Text("settings.shortcuts.global-section")
            } footer: {
                Text("settings.shortcuts.footer")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("settings.detail.shortcuts")
    }
}

private struct ClipboardSettingsView: View {
    var viewModel: LauncherViewModel
    @ObservedObject private var preferences: ClipboardPreferences
    @State private var isAccessibilityGranted = AXIsProcessTrusted()

    init(viewModel: LauncherViewModel) {
        self.viewModel = viewModel
        preferences = viewModel.clipboardPreferences
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Clipboard History", isOn: $preferences.isEnabled)
                Toggle("Pause Recording", isOn: $preferences.isPaused)
                    .disabled(!preferences.isEnabled)
            } header: {
                Text("Recording")
            } footer: {
                Text("Yorozu stores clipboard history only on this Mac. Concealed and transient clipboard content is ignored.")
            }

            Section {
                Toggle("Load URL Previews", isOn: $preferences.loadURLPreviews)
            } header: {
                Text("Link Previews")
            } footer: {
                Text("When enabled, Yorozu validates each HTTP or HTTPS destination and resolved address, then loads bounded page metadata and an optional preview image.")
            }

            Section("Retention") {
                Picker("Keep History", selection: $preferences.retentionDays) {
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                    Text("90 Days").tag(90)
                }
                .onChange(of: preferences.retentionDays) {
                    viewModel.applyClipboardRetentionSettings()
                }

                Picker("Maximum Items", selection: $preferences.maximumItems) {
                    Text("500").tag(500)
                    Text("1,000").tag(1_000)
                    Text("2,000").tag(2_000)
                }
                .onChange(of: preferences.maximumItems) {
                    viewModel.applyClipboardRetentionSettings()
                }
            }

            Section("Excluded Applications") {
                if preferences.excludedBundleIdentifiers.isEmpty {
                    Text("No applications are excluded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        preferences.excludedBundleIdentifiers.sorted(),
                        id: \.self
                    ) { bundleIdentifier in
                        LabeledContent {
                            Button {
                                preferences.setExcluded(
                                    false,
                                    bundleIdentifier: bundleIdentifier
                                )
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(applicationName(for: bundleIdentifier))")
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(applicationName(for: bundleIdentifier))
                                Text(bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Menu("Add Application…") {
                    ForEach(availableApplications) { application in
                        Button(application.primaryName) {
                            if let bundleIdentifier = application.bundleIdentifier {
                                preferences.setExcluded(
                                    true,
                                    bundleIdentifier: bundleIdentifier
                                )
                            }
                        }
                    }
                }
                .disabled(availableApplications.isEmpty)
            }

            Section {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(isAccessibilityGranted ? "Allowed" : "Not Allowed")
                            .foregroundStyle(
                                isAccessibilityGranted ? Color.secondary : Color.red
                            )
                        Button("Check Again") {
                            refreshAccessibilityStatus()
                        }
                        if !isAccessibilityGranted {
                            Button("Open System Settings") {
                                openAccessibilitySettings()
                            }
                        }
                    }
                }
            } header: {
                Text("Automatic Paste")
            } footer: {
                Text(
                    "Yorozu checks permission for the current build and uses it only to send Command-V after you choose Paste. If an older build is enabled in System Settings, you may need to allow this build again."
                )
            }

            Section("History") {
                LabeledContent {
                    HStack {
                        Button("Clear History…") {
                            viewModel.requestClearClipboardHistory(includePinned: false)
                        }
                        Button("Clear All…", role: .destructive) {
                            viewModel.requestClearClipboardHistory(includePinned: true)
                        }
                    }
                } label: {
                    Text("\(viewModel.clipboardItemCount) Items")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("settings.detail.clipboard")
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshAccessibilityStatus()
        }
    }

    private var availableApplications: [LaunchableApplication] {
        viewModel.installedApplications.filter {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return !preferences.excludedBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    private func applicationName(for bundleIdentifier: String) -> String {
        viewModel.installedApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        })?.primaryName ?? knownApplicationName(for: bundleIdentifier)
    }

    private func knownApplicationName(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.apple.Passwords":
            "Passwords"
        case "com.apple.keychainaccess":
            "Keychain Access"
        case "com.1password.1password":
            "1Password"
        case "com.bitwarden.desktop":
            "Bitwarden"
        case "org.keepassxc.keepassxc":
            "KeePassXC"
        default:
            bundleIdentifier
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshAccessibilityStatus() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }
}
