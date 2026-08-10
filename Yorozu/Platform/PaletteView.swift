import AppKit
import SwiftUI

struct PaletteView: View {
    @Bindable var viewModel: LauncherViewModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if viewModel.route.isAI {
                    AIChatView(
                        viewModel: viewModel.aiChatViewModel,
                        onBackToRoot: viewModel.returnToRoot,
                        onShowActions: viewModel.showActionMenu
                    )
                } else if viewModel.route == .translation {
                    TranslationView(
                        viewModel: viewModel.translationViewModel,
                        onBack: viewModel.returnToRoot,
                        onOpenSettings: viewModel.openSettingsFromTranslation
                    )
                } else {
                    VStack(spacing: 0) {
                        paletteHeader
                            .padding(.horizontal, 14)
                        Divider()
                            .padding(.horizontal, 14)
                        results
                            .padding(.horizontal, 8)
                        if viewModel.route != .settings {
                            Divider()
                                .padding(.horizontal, 14)
                            footer
                                .padding(.horizontal, 14)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .disabled(viewModel.isModalPresented)
            .accessibilityHidden(viewModel.isModalPresented)

            if viewModel.isActionPanelPresented {
                ActionPanelView(viewModel: viewModel)
                    .padding(.trailing, 22)
                    .padding(.bottom, 54)
            }

            if viewModel.isModalPresented {
                Color.primary.opacity(0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)

                PaletteModalView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(24)
            }
        }
        .frame(minWidth: 760, idealWidth: 760, maxWidth: 760)
        .coordinateSpace(name: "palette.content")
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var paletteHeader: some View {
        if viewModel.route == .settings {
            settingsHeader
        } else {
            searchHeader
        }
    }

    private var searchHeader: some View {
        ZStack(alignment: .leading) {
            GlassSearchField(
                text: $viewModel.query,
                focusRequest: viewModel.focusRequest,
                placeholder: viewModel.searchPlaceholder,
                accessibilityLabel: viewModel.searchAccessibilityLabel,
                leadingInset: viewModel.route == .root ? 20 : 58
            )
            .frame(minHeight: 58)
            .layoutPriority(1)

            if viewModel.route != .root {
                Button {
                    viewModel.returnToRoot()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Yorozu")
                .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.returnToRoot()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Yorozu")

            Text("Settings")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("launcher.settings.title")

            Spacer()
        }
        .frame(minHeight: 58)
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.route == .settings {
            SettingsView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.route == .aliases {
            aliasesSplitView
        } else if viewModel.route == .clipboard,
           !viewModel.clipboardPreferences.isEnabled,
           viewModel.results.isEmpty {
            ContentUnavailableView {
                Label("Clipboard History Is Off", systemImage: "clipboard")
            } description: {
                Text("Enable history to save text, links, and files you copy.")
            } actions: {
                Button("Enable Clipboard History") {
                    viewModel.clipboardPreferences.isEnabled = true
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.route == .snippets,
                  viewModel.results.isEmpty,
                  viewModel.query.isEmpty {
            ContentUnavailableView {
                Label("No Snippets", systemImage: "text.quote")
            } description: {
                Text("Create reusable text and paste it into any application.")
            } actions: {
                Button("New Snippet") {
                    viewModel.newSnippet()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty {
            ContentUnavailableView {
                Label(viewModel.emptyStateTitle, systemImage: viewModel.emptyStateSymbol)
            } description: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            commandResults
        }
    }

    private var commandResults: some View {
        HStack(spacing: 0) {
            CommandResultsListView(
                viewModel: viewModel,
                compact: viewModel.route != .root
            )
            .frame(width: viewModel.route == .root ? nil : 320)

            if viewModel.route != .root {
                Divider()
                    .accessibilityHidden(true)

                DeferredFeatureDetailView(viewModel: viewModel)
                    .id(viewModel.route)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private var aliasesSplitView: some View {
        HStack(spacing: 0) {
            aliasesListPane
                .frame(width: 320)

            Divider()
                .accessibilityHidden(true)

            AliasDetailView(viewModel: viewModel)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.aliases")
    }

    @ViewBuilder
    private var aliasesListPane: some View {
        if viewModel.results.isEmpty {
            ContentUnavailableView {
                Label(viewModel.emptyStateTitle, systemImage: viewModel.emptyStateSymbol)
            } description: {
                Text(
                    viewModel.query.isEmpty
                        ? "Add an alias to find applications using your own keywords."
                        : "Try another application name or alias."
                )
            } actions: {
                if viewModel.query.isEmpty {
                    Button("Add Alias") {
                        viewModel.beginAddAlias()
                    }
                    .accessibilityIdentifier("aliases.empty.add")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CommandResultsListView(viewModel: viewModel, compact: true)
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if viewModel.isIndexing, viewModel.route == .root {
                ProgressView()
                    .controlSize(.small)
                Text("Indexing applications…")
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.footerText)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                ForEach(viewModel.footerActions) { action in
                    Button {
                        viewModel.performFooterAction(action.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text(action.shortcut)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    .quinary,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(.quaternary, lineWidth: 1)
                                }
                                .accessibilityHidden(true)

                            Text(action.title)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.isFooterActionEnabled(action.id))
                    .accessibilityIdentifier("launcher.footer.\(action.id.rawValue)")
                    .accessibilityLabel("\(action.title), \(action.shortcut)")
                    .help("\(action.title) (\(action.shortcut))")
                }
            }
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

}

private struct TranslationView: View {
    @Bindable var viewModel: TranslationViewModel
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Yorozu")

                Text("Translate")
                    .font(.title3.weight(.semibold))

                Spacer()

                Picker("Target language", selection: $viewModel.targetLanguage) {
                    ForEach(TranslationViewModel.supportedTargetLanguages, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Target language")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)

            Divider()
                .padding(.horizontal, 14)

            if let selectionPermissionMessage = viewModel.selectionPermissionMessage {
                HStack(spacing: 8) {
                    Label(selectionPermissionMessage, systemImage: "hand.raised")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open System Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            if let configurationMessage = viewModel.configurationMessage {
                HStack(spacing: 8) {
                    Label(configurationMessage, systemImage: "gearshape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            HStack(spacing: 0) {
                translationPane(
                    title: "Input"
                ) {
                    TextEditor(text: $viewModel.inputText)
                        .focused($inputFocused)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .overlay(alignment: .topLeading) {
                            if viewModel.inputText.isEmpty {
                                Text("Enter text to translate…")
                                    .foregroundStyle(.tertiary)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: viewModel.inputText) { _, _ in
                            if viewModel.outputTextIsPresent {
                                viewModel.clearOutput()
                            }
                        }
                }

                Divider()

                translationPane(title: "Translation") {
                    ScrollView {
                        Text(viewModel.outputText.isEmpty ? "Your translation will appear here." : viewModel.outputText)
                            .foregroundStyle(viewModel.outputText.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 14)

            HStack(spacing: 10) {
                Picker("Provider", selection: Binding(
                    get: { viewModel.selectedProviderID },
                    set: { if let value = $0 { viewModel.selectProvider(value) } }
                )) {
                    ForEach(viewModel.providerViewModels, id: \.providerID) { provider in
                        Text(provider.providerDescriptor.displayName)
                            .tag(Optional(provider.providerID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(viewModel.providerViewModels.isEmpty || viewModel.isTranslating)
                .accessibilityLabel("Translation provider")

                Picker("Model", selection: Binding(
                    get: { viewModel.selectedModel },
                    set: { viewModel.selectModel($0) }
                )) {
                    ForEach(viewModel.availableModels) { model in
                        Text(model.title).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(viewModel.availableModels.isEmpty || viewModel.isTranslating)
                .accessibilityLabel("Translation model")

                if !viewModel.availableReasoningEfforts.isEmpty {
                    Picker("Reasoning", selection: Binding(
                        get: { viewModel.selectedReasoningEffort },
                        set: { viewModel.selectReasoningEffort($0) }
                    )) {
                        Text("Default").tag(AIReasoningEffort?.none)
                        ForEach(viewModel.availableReasoningEfforts) { effort in
                            Text(effort.title).tag(Optional(effort))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(viewModel.isTranslating)
                    .accessibilityLabel("Reasoning level")
                }

                Spacer()

                if viewModel.isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(viewModel.isTranslating ? "Stop" : "Translate") {
                    if viewModel.isTranslating {
                        viewModel.stop()
                    } else {
                        viewModel.translate()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isTranslating && !viewModel.canTranslate)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityIdentifier("translation.submit")
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
        .padding(.top, 12)
        .task(id: viewModel.focusRequest) {
            inputFocused = true
            viewModel.loadModelsIfNeeded()
        }
        .accessibilityIdentifier("launcher.translation")
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func translationPane<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CommandResultsListView: View {
    @Bindable var viewModel: LauncherViewModel
    let compact: Bool

    @State private var visibleResults = ResultVisibilityTracker()
    @State private var hoveredResultID: CommandResultID?
    @FocusState private var focusedResultID: CommandResultID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.results) { result in
                        resultRow(result)
                            .padding(
                                EdgeInsets(
                                    top: 6,
                                    leading: 8,
                                    bottom: 6,
                                    trailing: 10
                                )
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background {
                                if viewModel.selectedID == result.id {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(.quaternary)
                                } else if hoveredResultID == result.id {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(.quinary)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                Divider()
                                    .padding(.horizontal, 6)
                            }
                            .id(result.id)
                            .focusable()
                            .focused($focusedResultID, equals: result.id)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(result.title)
                            .accessibilityIdentifier(
                                "launcher.row.\(result.id.rawValue)"
                            )
                            .accessibilityAddTraits(
                                viewModel.selectedID == result.id
                                    ? [.isButton, .isSelected]
                                    : [.isButton]
                            )
                            .accessibilityAction {
                                viewModel.selectedID = result.id
                                viewModel.performPrimaryAction()
                            }
                            .onTapGesture(count: 2) {
                                viewModel.selectedID = result.id
                                viewModel.performPrimaryAction()
                            }
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    viewModel.selectedID = result.id
                                }
                            )
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredResultID = result.id
                                } else if hoveredResultID == result.id {
                                    hoveredResultID = nil
                                }
                            }
                            .onScrollVisibilityChange(threshold: 0.999) { isVisible in
                                if isVisible {
                                    visibleResults.ids.insert(result.id)
                                } else {
                                    visibleResults.ids.remove(result.id)
                                }
                            }
                            .contextMenu {
                                contextMenu(for: result)
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.automatic)
            .background(Color.clear)
            .onChange(of: viewModel.selectedID) { previousID, selectedID in
                if focusedResultID != nil {
                    focusedResultID = selectedID
                }
                guard let selectedID,
                      !visibleResults.ids.contains(selectedID) else {
                    return
                }
                proxy.scrollTo(
                    selectedID,
                    anchor: selectionScrollAnchor(
                        from: previousID,
                        to: selectedID
                    )
                )
            }
            .onChange(of: viewModel.resultsRevision) {
                visibleResults.ids.removeAll()
                guard let selectedID = viewModel.selectedID else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .onChange(of: focusedResultID) { _, focusedResultID in
                guard let focusedResultID,
                      viewModel.resultIndex(for: focusedResultID) != nil else {
                    return
                }
                viewModel.selectedID = focusedResultID
            }
            .task(id: viewModel.route) {
                visibleResults.ids.removeAll()
                await Task.yield()
                guard let selectedID = viewModel.selectedID else { return }
                proxy.scrollTo(selectedID, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: CommandResult) -> some View {
        if compact {
            if viewModel.route == .aliases {
                AliasCommandResultRow(result: result)
            } else {
                CompactCommandResultRow(result: result)
            }
        } else {
            CommandResultRow(result: result)
        }
    }

    private func selectionScrollAnchor(
        from previousID: CommandResultID?,
        to selectedID: CommandResultID
    ) -> UnitPoint {
        guard let previousID,
              let previousIndex = viewModel.resultIndex(for: previousID),
              let selectedIndex = viewModel.resultIndex(for: selectedID) else {
            return .center
        }

        if selectedIndex > previousIndex {
            return .bottom
        }
        if selectedIndex < previousIndex {
            return .top
        }
        return .center
    }

    @ViewBuilder
    private func contextMenu(for result: CommandResult) -> some View {
        switch result.payload {
        case .application:
            Button {
                select(result) { viewModel.openSelectedApplication() }
            } label: {
                Label(
                    viewModel.route == .aliases ? "Open Application" : "Open",
                    systemImage: "arrow.up.forward.app"
                )
            }
            if viewModel.route != .aliases {
                Button {
                    select(result) { viewModel.togglePinForSelectedResult() }
                } label: {
                    Label("Pin or Unpin", systemImage: "pin")
                }
            }
            Button {
                select(result) { viewModel.editAliasForSelectedApplication() }
            } label: {
                Label("Edit Alias", systemImage: "character.cursor.ibeam")
            }
            if viewModel.route == .aliases {
                Button(role: .destructive) {
                    select(result) { viewModel.requestAliasDeletion() }
                } label: {
                    Label("Delete Alias", systemImage: "trash")
                }
            }
            Divider()
            Button {
                select(result) { viewModel.revealSelectedApplicationInFinder() }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        case let .feature(feature):
            Button {
                viewModel.openFeature(feature)
            } label: {
                Label("Open", systemImage: "arrow.right")
            }
        case .clipboard:
            Button {
                select(result) { viewModel.pasteSelected() }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            Button {
                select(result) { viewModel.copySelected() }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                select(result) { viewModel.togglePinForSelectedResult() }
            } label: {
                Label("Pin or Unpin", systemImage: "pin")
            }
            Divider()
            Button(role: .destructive) {
                select(result) { viewModel.requestDeleteSelected() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .snippet:
            Button {
                select(result) { viewModel.pasteSelected() }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            Button {
                select(result) { viewModel.copySelected() }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                select(result) { viewModel.editSelectedSnippet() }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                select(result) { viewModel.duplicateSelectedSnippet() }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                select(result) { viewModel.requestDeleteSelected() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func select(_ result: CommandResult, action: () -> Void) {
        viewModel.selectedID = result.id
        action()
    }
}

@MainActor
private final class ResultVisibilityTracker {
    var ids: Set<CommandResultID> = []
}

@MainActor
private final class ActionVisibilityTracker {
    var ids: Set<LauncherActionID> = []
}

private struct ActionPanelView: View {
    @Bindable var viewModel: LauncherViewModel
    @State private var visibleActions = ActionVisibilityTracker()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.actionPanelTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.filteredActionItems) { action in
                            actionRow(action)
                                .id(action.id)
                                .onScrollVisibilityChange(threshold: 0.999) { isVisible in
                                    if isVisible {
                                        visibleActions.ids.insert(action.id)
                                    } else {
                                        visibleActions.ids.remove(action.id)
                                    }
                                }
                        }

                        if viewModel.filteredActionItems.isEmpty {
                            Text("No actions found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: viewModel.selectedActionID) { previousID, selectedID in
                    guard let selectedID,
                          !visibleActions.ids.contains(selectedID) else {
                        return
                    }
                    proxy.scrollTo(
                        selectedID,
                        anchor: selectionScrollAnchor(
                            from: previousID,
                            to: selectedID
                        )
                    )
                }
                .onChange(of: viewModel.filteredActionItems.map(\.id)) { _, _ in
                    visibleActions.ids.removeAll()
                    guard let selectedID = viewModel.selectedActionID else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard selectedID == viewModel.selectedActionID else { return }
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }

            Divider()

            TextField("Search for actions…", text: $viewModel.actionQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityIdentifier("launcher.action-search")
                .accessibilityLabel("Search actions")
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 342, height: 258)
        .modifier(AdaptiveActionPanelSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.action-panel")
        .onAppear {
            // The panel enters the hierarchy during the same update that leaves
            // the AppKit root search field as first responder. Defer one run-loop
            // turn so the action field can reliably take keyboard focus.
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onDisappear {
            isSearchFocused = false
        }
    }

    private func actionRow(_ action: LauncherActionItem) -> some View {
        Button(role: action.role) {
            viewModel.performAction(action.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbolName)
                    .frame(width: 16)
                    .foregroundStyle(
                        action.role == .destructive ? Color.red : Color.primary
                    )
                    .accessibilityHidden(true)

                Text(action.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 12)

                HStack(spacing: 3) {
                    ForEach(Array(action.shortcutGlyphs.enumerated()), id: \.offset) { _, glyph in
                        Text(glyph)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background {
                if viewModel.selectedActionID == action.id {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("launcher.action.\(action.id.rawValue)")
        .accessibilityAddTraits(
            viewModel.selectedActionID == action.id ? .isSelected : []
        )
        .onHover { isHovering in
            if isHovering {
                viewModel.selectAction(action.id)
            }
        }
    }

    private func selectionScrollAnchor(
        from previousID: LauncherActionID?,
        to selectedID: LauncherActionID
    ) -> UnitPoint {
        let actionIDs = viewModel.filteredActionItems.map(\.id)
        guard let previousID,
              let previousIndex = actionIDs.firstIndex(of: previousID),
              let selectedIndex = actionIDs.firstIndex(of: selectedID) else {
            return .center
        }
        if selectedIndex > previousIndex {
            return .bottom
        }
        if selectedIndex < previousIndex {
            return .top
        }
        return .center
    }
}

private struct AdaptiveActionPanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency)
    private var systemReducesTransparency
    @Environment(\.yorozuReduceTransparencyOverride)
    private var overrideReducesTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if systemReducesTransparency || overrideReducesTransparency {
            content
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        } else {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}

private struct CommandResultRow: View {
    let result: CommandResult

    var body: some View {
        HStack(spacing: 10) {
            CommandIconView(icon: result.icon, size: 32)

            HStack(spacing: 7) {
                Text(result.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }

                Text("·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(result.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if result.kind == .feature {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launcher.row.\(result.id.rawValue)")
    }

    private var isPinned: Bool {
        result.isPinned
    }
}

private struct CompactCommandResultRow: View {
    let result: CommandResult

    var body: some View {
        HStack(spacing: 10) {
            CommandIconView(icon: result.icon, size: 24)

            Text(result.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if result.kind == .clipboard, result.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launcher.row.\(result.id.rawValue)")
    }
}

private struct AliasCommandResultRow: View {
    let result: CommandResult

    var body: some View {
        HStack(spacing: 10) {
            CommandIconView(icon: result.icon, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if case let .application(application) = result.payload {
                    HStack(spacing: 5) {
                        Text(application.preference.alias ?? "")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("·")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)

                        Text(
                            application.bundleIdentifier
                                ?? application.canonicalURL.path
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launcher.row.\(result.id.rawValue)")
    }
}

private struct CommandIconView: View {
    let icon: CommandIcon
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        switch icon {
        case let .application(url):
            Image(nsImage: ApplicationIconCache.shared.icon(for: url))
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case let .system(name):
            Image(systemName: name)
                .font(size <= 24 ? .body : .title3)
                .symbolRenderingMode(.hierarchical)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

private struct AliasDetailView: View {
    @Bindable var viewModel: LauncherViewModel

    var body: some View {
        aliasDetails
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aliases.detail")
    }

    @ViewBuilder
    private var aliasDetails: some View {
        if let application = viewModel.selectedApplication {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    applicationHeader(application)

                    DetailMetadataSection(title: "Alias") {
                        DetailMetadataRow(
                            label: "Alias",
                            value: application.preference.alias ?? "Not Set"
                        )
                    }

                    DetailMetadataSection(title: "Application") {
                        DetailMetadataRow(
                            label: "Bundle ID",
                            value: application.bundleIdentifier ?? "Not Available"
                        )
                        DetailMetadataRow(
                            label: "Application Path",
                            value: application.canonicalURL.path
                        )
                    }

                    HStack {
                        Button("Edit Alias") {
                            viewModel.beginEditingSelectedAlias()
                        }
                        .accessibilityIdentifier("aliases.edit")

                        Button("Delete Alias", role: .destructive) {
                            viewModel.requestAliasDeletion()
                        }
                        .accessibilityIdentifier("aliases.delete")

                        Spacer()
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView(
                "Select an Alias",
                systemImage: "sidebar.left",
                description: Text("Choose an application to view or edit its alias.")
            )
        }
    }

    private func applicationHeader(
        _ application: LaunchableApplication
    ) -> some View {
        HStack(spacing: 14) {
            CommandIconView(
                icon: .application(application.canonicalURL),
                size: 52
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(application.primaryName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(application.preference.alias ?? "No Alias")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PaletteModalView: View {
    @Bindable var viewModel: LauncherViewModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case snippetName
        case aliasApplicationSearch
        case alias
        case apiKey
        case codexPath
        case cancelConfirmation
    }

    var body: some View {
        Group {
            switch viewModel.paletteModal {
            case .snippetEditor:
                snippetEditor
                    .frame(width: 500, height: 410)
            case .aliasApplicationPicker:
                aliasApplicationPicker
                    .frame(width: 520, height: 410)
            case .aliasEditor:
                aliasEditor
                    .frame(width: 470)
            case .openAIAPIKey:
                openAIAPIKeyEditor
                    .frame(width: 460)
            case .codexExecutablePath:
                codexExecutablePathEditor
                    .frame(width: 500)
            case .confirmation:
                confirmation
                    .frame(width: 420)
            case nil:
                EmptyView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("palette.modal")
        .task(id: viewModel.modalFocusRequest) {
            await Task.yield()
            switch viewModel.paletteModal {
            case .snippetEditor:
                focusedField = .snippetName
            case .aliasApplicationPicker:
                focusedField = .aliasApplicationSearch
            case .aliasEditor:
                focusedField = .alias
            case .openAIAPIKey:
                focusedField = .apiKey
            case .codexExecutablePath:
                focusedField = .codexPath
            case .confirmation:
                focusedField = .cancelConfirmation
            case nil:
                focusedField = nil
            }
        }
    }

    private var snippetEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            modalHeader(viewModel.modalSnippet == nil ? "New Snippet" : "Edit Snippet")
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                TextField("Name", text: $viewModel.snippetNameDraft)
                    .focused($focusedField, equals: .snippetName)
                    .accessibilityIdentifier("modal.snippet.name")
                TextField("Keyword (optional)", text: $viewModel.snippetKeywordDraft)
                    .accessibilityIdentifier("modal.snippet.keyword")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Content")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.snippetContentDraft)
                        .frame(minHeight: 190)
                        .accessibilityIdentifier("modal.snippet.content")
                }
                modalError
                modalButtons(saveTitle: "Save", save: viewModel.saveSnippetFromModal)
            }
            .padding(18)
        }
    }

    private var aliasApplicationPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            modalHeader("Add Alias", subtitle: "Choose an application to add or edit its alias.")
            Divider()
            TextField("Search Applications", text: $viewModel.aliasApplicationQuery)
                .focused($focusedField, equals: .aliasApplicationSearch)
                .padding(14)
                .accessibilityIdentifier("modal.alias.application-search")
            Divider()
            ScrollViewReader { proxy in
                List(
                    viewModel.aliasApplicationCandidates,
                    selection: $viewModel.selectedAliasApplicationID
                ) { application in
                    HStack(spacing: 10) {
                        CommandIconView(icon: .application(application.canonicalURL), size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.primaryName)
                                .lineLimit(1)
                            Text(
                                application.preference.alias
                                    ?? application.bundleIdentifier
                                    ?? application.canonicalURL.path
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                    .tag(application.id)
                    .id(application.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.chooseAliasApplication(application.id)
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            viewModel.selectedAliasApplicationID = application.id
                        }
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "modal.alias.application.\(application.id.rawValue)"
                    )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: viewModel.selectedAliasApplicationID) { _, identity in
                    guard let identity else { return }
                    proxy.scrollTo(identity)
                }
            }
            Divider()
            HStack {
                Spacer()
                cancelButton
                Button("Continue") { viewModel.chooseSelectedAliasApplication() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.selectedAliasApplicationID == nil)
                    .accessibilityIdentifier("modal.alias.continue")
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var aliasEditor: some View {
        if let application = viewModel.aliasEditingApplication {
            VStack(alignment: .leading, spacing: 0) {
                modalHeader("Edit Alias", subtitle: application.primaryName)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        CommandIconView(icon: .application(application.canonicalURL), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.primaryName).font(.headline)
                            Text(application.bundleIdentifier ?? application.canonicalURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    TextField("For example: browser", text: $viewModel.aliasDraft)
                        .focused($focusedField, equals: .alias)
                        .accessibilityIdentifier("modal.alias.value")
                    Text("Use 1–64 characters. Duplicate aliases are allowed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = viewModel.aliasValidationMessage {
                        errorLabel(message)
                    } else {
                        modalError
                    }
                    modalButtons(saveTitle: "Save", save: viewModel.saveAlias)
                }
                .padding(18)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                modalHeader("Application Unavailable")
                Text("Choose another application.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); cancelButton }
                    .padding([.horizontal, .bottom], 18)
            }
        }
    }

    private var openAIAPIKeyEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            modalHeader("OpenAI API Key", subtitle: "The key is stored in macOS Keychain.")
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                SecureField("Paste your OpenAI API key", text: $viewModel.openAIAPIKeyDraft)
                    .focused($focusedField, equals: .apiKey)
                    .textContentType(.password)
                    .accessibilityIdentifier("modal.openai.api-key")
                modalError
                modalButtons(saveTitle: "Save", save: viewModel.saveOpenAIAPIKeyFromModal)
            }
            .padding(18)
        }
    }

    private var codexExecutablePathEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            modalHeader(
                "Codex Executable Path",
                subtitle: "Leave this empty to use automatic detection."
            )
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                TextField("/path/to/codex", text: $viewModel.codexExecutablePathDraft)
                    .focused($focusedField, equals: .codexPath)
                    .accessibilityIdentifier("modal.codex.path")
                modalError
                HStack {
                    Button("Use Automatic Detection") {
                        viewModel.useAutomaticCodexDetection()
                    }
                    .disabled(viewModel.isModalProcessing)
                    Spacer()
                    cancelButton
                    Button("Save") { viewModel.saveCodexExecutablePathFromModal() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.isModalProcessing)
                }
            }
            .padding(18)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 0) {
            modalHeader(viewModel.modalConfirmationTitle)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.modalConfirmationMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                modalError
                HStack {
                    Spacer()
                    Button("Cancel") { viewModel.dismissModal() }
                        .keyboardShortcut(.defaultAction)
                        .focused($focusedField, equals: .cancelConfirmation)
                        .disabled(viewModel.isModalProcessing)
                        .accessibilityIdentifier("modal.cancel")
                    Button(viewModel.modalConfirmationActionTitle, role: .destructive) {
                        viewModel.confirmModalAction()
                    }
                    .disabled(viewModel.isModalProcessing)
                    .accessibilityIdentifier("modal.confirm")
                }
            }
            .padding(18)
        }
    }

    private func modalHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    @ViewBuilder
    private var modalError: some View {
        if let message = viewModel.modalErrorMessage {
            errorLabel(message)
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("modal.error")
    }

    private func modalButtons(saveTitle: String, save: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            cancelButton
            Button(saveTitle, action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isModalProcessing)
                .accessibilityIdentifier("modal.save")
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { viewModel.dismissModal() }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.isModalProcessing)
            .accessibilityIdentifier("modal.cancel")
    }
}

private struct FeatureDetailView: View {
    let content: FeatureDetailContent?
    @ObservedObject var clipboardPreferences: ClipboardPreferences
    @ObservedObject var urlPreviewService: URLPreviewService
    let selectedClipboardImage: CGImage?
    let isClipboardImageLoading: Bool

    var body: some View {
        Group {
            switch content {
            case let .clipboard(item):
                ClipboardDetailView(
                    item: item,
                    preferences: clipboardPreferences,
                    urlPreviewService: urlPreviewService,
                    image: selectedClipboardImage,
                    isImageLoading: isClipboardImageLoading
                )
            case let .snippet(snippet):
                SnippetDetailView(snippet: snippet)
            default:
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "sidebar.left",
                    description: Text("Choose an item from the list to preview it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityIdentifier("launcher.feature-detail")
    }
}

private struct DeferredFeatureDetailView: View {
    var viewModel: LauncherViewModel
    @State private var displayedContent: FeatureDetailContent?

    private var selectionKey: FeatureDetailSelectionKey {
        FeatureDetailSelectionKey(
            result: viewModel.selectedResult,
            clipboardItem: viewModel.selectedClipboardItem,
            snippet: viewModel.selectedSnippet
        )
    }

    private var selectedContent: FeatureDetailContent? {
        if let item = viewModel.selectedClipboardItem {
            return .clipboard(item)
        }
        if let snippet = viewModel.selectedSnippet {
            return .snippet(snippet)
        }
        return nil
    }

    var body: some View {
        FeatureDetailView(
            content: displayedContent,
            clipboardPreferences: viewModel.clipboardPreferences,
            urlPreviewService: viewModel.urlPreviewService,
            selectedClipboardImage: viewModel.selectedClipboardImage,
            isClipboardImageLoading: viewModel.isClipboardImageLoading
        )
        .task(id: selectionKey) {
            do {
                // Let the list selection reach the screen before constructing
                // LinkPresentation or image detail content.
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            displayedContent = selectedContent
        }
    }
}

private enum FeatureDetailContent {
    case clipboard(ClipboardItem)
    case snippet(Snippet)
}

private struct FeatureDetailSelectionKey: Hashable {
    let id: CommandResultID?
    let revision: Revision

    init(
        result: CommandResult?,
        clipboardItem: ClipboardItem?,
        snippet: Snippet?
    ) {
        id = result?.id
        switch result?.payload {
        case let .application(application):
            revision = .application(
                alias: application.preference.alias,
                isPinned: application.preference.isPinned,
                launchCount: application.preference.launchCount,
                lastLaunchedAt: application.preference.lastLaunchedAt
            )
        case .clipboard:
            revision = clipboardItem.map { .dated($0.updatedAt) } ?? .none
        case .snippet:
            revision = snippet.map { .dated($0.updatedAt) } ?? .none
        case let .feature(feature):
            revision = .feature(feature)
        case nil:
            revision = .none
        }
    }

    enum Revision: Hashable {
        case none
        case application(
            alias: String?,
            isPinned: Bool,
            launchCount: Int,
            lastLaunchedAt: Date?
        )
        case dated(Date)
        case feature(FeatureCommand)
    }
}

private struct ClipboardDetailView: View {
    private static let maximumPreviewCharacters = 1_000

    let item: ClipboardItem
    @ObservedObject var preferences: ClipboardPreferences
    @ObservedObject var urlPreviewService: URLPreviewService
    let image: CGImage?
    let isImageLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            metadata
                .frame(height: 168)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            textPreview(item.textContent ?? "")
        case .url:
            URLClipboardPreview(
                rawURL: item.textContent ?? "",
                preferences: preferences,
                service: urlPreviewService
            )
        case .files:
            filePreview
        case .image:
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .accessibilityLabel(item.title)
            } else if isImageLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading Image…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Preview Unavailable", systemImage: "photo")
            }
        }
    }

    private func textPreview(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(text.prefix(Self.maximumPreviewCharacters)))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if text.count > Self.maximumPreviewCharacters {
                    Label(
                        "Preview truncated. Use Copy to get the full content.",
                        systemImage: "ellipsis"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var filePreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(item.filePaths, id: \.self) { path in
                    HStack(spacing: 12) {
                        Image(systemName: "doc")
                            .font(.title2)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                            Text(path)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var metadata: some View {
        DetailMetadataSection(title: "Information") {
            DetailMetadataRow(
                label: "Source",
                value: item.sourceApplicationName ?? "Unknown"
            )
            DetailMetadataRow(label: "Content type", value: item.kindLabel)
            if let imageWidth = item.imageWidth,
               let imageHeight = item.imageHeight {
                DetailMetadataRow(
                    label: "Dimensions",
                    value: "\(imageWidth)×\(imageHeight)"
                )
            }
            DetailMetadataRow(label: "Size", value: formattedSize)
            DetailMetadataRow(
                label: "Copied",
                value: item.copiedAt.formatted(date: .abbreviated, time: .shortened)
            )
        }
    }

    private var formattedSize: String {
        switch item.kind {
        case .text, .url:
            let byteCount = item.textContent?.lengthOfBytes(using: .utf8) ?? 0
            return ByteCountFormatter.string(
                fromByteCount: Int64(byteCount),
                countStyle: .file
            )
        case .files:
            return item.filePaths.count == 1
                ? "1 file"
                : "\(item.filePaths.count) files"
        case .image:
            return ByteCountFormatter.string(
                fromByteCount: Int64(item.imageByteCount ?? 0),
                countStyle: .file
            )
        }
    }
}

private struct URLClipboardPreview: View {
    let rawURL: String
    @ObservedObject var preferences: ClipboardPreferences
    @ObservedObject var service: URLPreviewService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "link")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(rawURL)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .task(id: PreviewRequest(rawURL: rawURL, isEnabled: preferences.loadURLPreviews)) {
            service.load(
                rawURL: rawURL,
                isEnabled: preferences.loadURLPreviews
            )
        }
        .onDisappear {
            service.cancel(resetState: true)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if !preferences.loadURLPreviews {
            ContentUnavailableView {
                Label("URL Preview", systemImage: "link")
            } description: {
                Text("Turn on Load URL Previews in Clipboard Settings to show titles and images.")
            }
        } else {
            switch service.state {
            case .idle:
                EmptyView()
            case let .loading(url):
                if url.absoluteString == previewURL?.absoluteString {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Preview…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case let .ready(url, document):
                if url.absoluteString == previewURL?.absoluteString {
                    RichLinkPreview(document: document)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 250)
                        .accessibilityLabel("Preview of \(url.host() ?? url.absoluteString)")
                }
            case let .unavailable(url, reason):
                if url.absoluteString == previewURL?.absoluteString {
                    ContentUnavailableView {
                        Label(
                            "Preview Unavailable",
                            systemImage: reason == .restrictedAddress
                                ? "hand.raised"
                                : "wifi.exclamationmark"
                        )
                    } description: {
                        Text(
                            reason == .restrictedAddress
                                ? "Local, private, and credentialed URLs aren’t loaded."
                                : "Yorozu couldn’t load metadata for this link."
                        )
                    }
                }
            }
        }
    }

    private var previewURL: URL? {
        URLPreviewPolicy.previewableURL(from: rawURL) ?? URL(string: rawURL)
    }

    private struct PreviewRequest: Hashable {
        let rawURL: String
        let isEnabled: Bool
    }
}

private struct RichLinkPreview: View {
    let document: URLPreviewDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageData = document.imageData,
               let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)
                if let siteName = document.siteName, !siteName.isEmpty {
                    Text(siteName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SnippetDetailView: View {
    private static let maximumPreviewCharacters = 1_000

    let snippet: Snippet

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        String(
                            snippet.content.prefix(Self.maximumPreviewCharacters)
                        )
                    )
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    if snippet.content.count > Self.maximumPreviewCharacters {
                        Label(
                            "Preview truncated. Use Copy to get the full content.",
                            systemImage: "ellipsis"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            DetailMetadataSection(title: "Information") {
                DetailMetadataRow(label: "Name", value: snippet.name)
                DetailMetadataRow(label: "Keyword", value: snippet.keyword ?? "Not Set")
                DetailMetadataRow(label: "Uses", value: "\(snippet.useCount)")
                DetailMetadataRow(
                    label: "Updated",
                    value: snippet.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }
            .frame(height: 150)
        }
    }
}

private struct DetailMetadataSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}

private struct DetailMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
