import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case clipboard
    case shortcuts

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general:
            "settings.sidebar.general"
        case .clipboard:
            "Clipboard"
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
    @State private var clearAction: ClearAction?

    private enum ClearAction: String, Identifiable {
        case unpinned
        case all

        var id: Self { self }
    }

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
                            clearAction = .unpinned
                        }
                        Button("Clear All…", role: .destructive) {
                            clearAction = .all
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
        .alert(item: $clearAction) { action in
            if action == .all {
                Alert(
                    title: Text("Clear All Clipboard History?"),
                    message: Text("Pinned items will also be permanently deleted."),
                    primaryButton: .destructive(Text("Clear All")) {
                        viewModel.clearClipboardHistory(includePinned: true)
                    },
                    secondaryButton: .cancel()
                )
            } else {
                Alert(
                    title: Text("Clear Clipboard History?"),
                    message: Text("Pinned items will be kept."),
                    primaryButton: .destructive(Text("Clear History")) {
                        viewModel.clearClipboardHistory(includePinned: false)
                    },
                    secondaryButton: .cancel()
                )
            }
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
