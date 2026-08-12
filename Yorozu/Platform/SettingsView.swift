import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case clipboard
    case ai
    case shortcuts

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general:
            "settings.sidebar.general"
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
            GeneralSettingsView(viewModel: viewModel)
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
        default:
            EmptyView()
        }
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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("settings.detail.general")
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
