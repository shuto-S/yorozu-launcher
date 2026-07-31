import AppKit
import SwiftUI

struct AccessibilityDisplayOverrides: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool

    init(arguments: [String]) {
        #if DEBUG
        reduceMotion = arguments.contains("--ui-testing-reduce-motion")
        reduceTransparency = arguments.contains("--ui-testing-reduce-transparency")
        #else
        reduceMotion = false
        reduceTransparency = false
        #endif
    }
}

enum PaletteAnimationPolicy {
    static func behavior(
        systemReducesMotion: Bool,
        overrides: AccessibilityDisplayOverrides
    ) -> NSWindow.AnimationBehavior {
        // Yorozu is opened repeatedly throughout the day. Even the standard
        // utility-window transition makes a warm panel feel slower than the
        // measured presentation time, so the palette always appears directly.
        _ = systemReducesMotion
        _ = overrides
        return .none
    }
}

enum PaletteKeyEventAction: Equatable {
    case passThrough
    case handleCommandShortcut
    case moveSelection(Int)
    case performPrimaryAction
    case escape
}

enum PaletteKeyEventPolicy {
    private static let textCompositionKeyCodes: Set<UInt16> = [
        36,  // Return
        76,  // Keypad Enter
        125, // Down Arrow
        126, // Up Arrow
        53,  // Escape
        48,  // Tab
    ]

    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool,
        route: PaletteRoute,
        isActionPanelPresented: Bool
    ) -> PaletteKeyEventAction {
        let independentModifiers = modifiers.intersection(
            .deviceIndependentFlagsMask
        )

        // Command shortcuts remain app commands even while an input method has
        // marked text. Unmodified composition keys must reach the field editor.
        if independentModifiers.contains(.command), route != .settings {
            return .handleCommandShortcut
        }

        if hasMarkedText,
           !independentModifiers.contains(.command),
           textCompositionKeyCodes.contains(keyCode) {
            return .passThrough
        }

        if route == .settings {
            return keyCode == 53 ? .escape : .passThrough
        }

        switch keyCode {
        case 125:
            return .moveSelection(1)
        case 126:
            return .moveSelection(-1)
        case 36, 76:
            return .performPrimaryAction
        case 53:
            return .escape
        default:
            return .passThrough
        }
    }
}

private struct YorozuReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var yorozuReduceTransparencyOverride: Bool {
        get { self[YorozuReduceTransparencyOverrideKey.self] }
        set { self[YorozuReduceTransparencyOverrideKey.self] = newValue }
    }
}

private struct PaletteAccessibilityHost: View {
    var viewModel: LauncherViewModel
    let overrides: AccessibilityDisplayOverrides

    var body: some View {
        PaletteView(viewModel: viewModel)
            .environment(
                \.yorozuReduceTransparencyOverride,
                overrides.reduceTransparency
            )
    }
}

#if DEBUG
struct PalettePresentationPerformanceReport: Codable, Equatable {
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        sampleCount = sorted.count
        p50Milliseconds = Self.percentile(0.50, in: sorted)
        p95Milliseconds = Self.percentile(0.95, in: sorted)
        maximumMilliseconds = sorted.last ?? 0
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(
            0,
            min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1)
        )
        return sorted[index]
    }
}

struct ClipboardInteractionPerformanceDistribution: Codable, Equatable {
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        sampleCount = sorted.count
        p50Milliseconds = Self.percentile(0.50, in: sorted)
        p95Milliseconds = Self.percentile(0.95, in: sorted)
        maximumMilliseconds = sorted.last ?? 0
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(
            0,
            min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1)
        )
        return sorted[index]
    }
}

struct ClipboardInteractionPerformanceReport: Codable, Equatable {
    let rootToClipboard: ClipboardInteractionPerformanceDistribution
    let selectionMovement: ClipboardInteractionPerformanceDistribution
    let settledDetailPresentation: ClipboardInteractionPerformanceDistribution
}
#endif

@MainActor
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PaletteWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {
    private let viewModel: LauncherViewModel
    private let pasteCoordinator: PasteCoordinator
    private let automaticallyHides: Bool
    private let accessibilityOverrides: AccessibilityDisplayOverrides
    private var previousApplication: NSRunningApplication?
    private var keyEventMonitor: Any?
    private var activePopover: NSPopover?

    init(viewModel: LauncherViewModel, pasteCoordinator: PasteCoordinator) {
        self.viewModel = viewModel
        self.pasteCoordinator = pasteCoordinator
        let arguments = ProcessInfo.processInfo.arguments
        automaticallyHides = !arguments.contains(
            "--ui-testing-sticky"
        )
        accessibilityOverrides = AccessibilityDisplayOverrides(arguments: arguments)

        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = automaticallyHides
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = PaletteAnimationPolicy.behavior(
            systemReducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            overrides: accessibilityOverrides
        )
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(
            rootView: PaletteAccessibilityHost(
                viewModel: viewModel,
                overrides: accessibilityOverrides
            )
                .environment(\.locale, Locale(identifier: "en"))
        )

        super.init(window: panel)
        panel.delegate = self
        bindViewModel()
        installKeyMonitor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidate() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    func toggle(route: PaletteRoute = .root) {
        guard let panel = window else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        if panel.isVisible, viewModel.route == route {
            hide(restorePreviousApplication: true)
        } else if panel.isVisible {
            viewModel.switchRouteFromShortcut(route)
            panel.makeKeyAndOrderFront(nil)
            LauncherPerformanceTrace.duration(
                "shortcut_to_panel",
                startedAt: startedAt
            )
        } else {
            show(route: route, origin: .direct)
            LauncherPerformanceTrace.duration(
                "shortcut_to_panel",
                startedAt: startedAt
            )
        }
    }

    func show(
        route: PaletteRoute = .root,
        origin: PalettePresentationOrigin = .direct
    ) {
        guard let panel = window else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        if !panel.isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApplication = frontmost
            }
        }

        position(window: panel)
        viewModel.prepareForPresentation(route: route, origin: origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        LauncherPerformanceTrace.duration(
            "panel_ordered_front",
            startedAt: startedAt
        )
    }

    func hide(restorePreviousApplication: Bool) {
        viewModel.dismissActionPanel(restoreSearchFocus: false)
        viewModel.paletteDidHide()
        window?.orderOut(nil)
        activePopover?.close()
        if restorePreviousApplication {
            previousApplication?.activate(options: [])
        }
        previousApplication = nil
    }

    #if DEBUG
    func runPresentationStressTest(
        iterations: Int,
        route: PaletteRoute = .root
    ) async -> PalettePresentationPerformanceReport {
        guard iterations > 0, let panel = window else {
            return PalettePresentationPerformanceReport(samples: [])
        }

        // Warm the persistent panel, hosting view, icon cache, and search path before sampling.
        show(route: route)
        panel.displayIfNeeded()
        hide(restorePreviousApplication: false)
        try? await Task.sleep(for: .milliseconds(50))

        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let startedAt = ProcessInfo.processInfo.systemUptime
            show(route: route)
            panel.displayIfNeeded()
            samples.append(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
            await Task.yield()
            hide(restorePreviousApplication: false)
            await Task.yield()
        }

        return PalettePresentationPerformanceReport(samples: samples)
    }

    func runClipboardInteractionStressTest(
        routeIterations: Int = 30,
        selectionIterations: Int = 100,
        settledDetailIterations: Int = 20
    ) async -> ClipboardInteractionPerformanceReport {
        guard let panel = window else {
            return ClipboardInteractionPerformanceReport(
                rootToClipboard: ClipboardInteractionPerformanceDistribution(samples: []),
                selectionMovement: ClipboardInteractionPerformanceDistribution(samples: []),
                settledDetailPresentation:
                    ClipboardInteractionPerformanceDistribution(samples: [])
            )
        }

        show(route: .root)
        await flushRenderedContent(in: panel)

        var routeSamples: [Double] = []
        routeSamples.reserveCapacity(max(0, routeIterations))
        for _ in 0..<max(0, routeIterations) {
            if viewModel.route != .root {
                viewModel.returnToRoot()
                await flushRenderedContent(in: panel)
            }

            let startedAt = ProcessInfo.processInfo.systemUptime
            viewModel.openFeature(.clipboardHistory)
            await flushRenderedContent(in: panel)
            routeSamples.append(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
        }

        if viewModel.route != .clipboard {
            viewModel.openFeature(.clipboardHistory)
            await flushRenderedContent(in: panel)
        }

        var selectionSamples: [Double] = []
        selectionSamples.reserveCapacity(max(0, selectionIterations))
        if viewModel.results.count > 1 {
            var direction = 1
            for _ in 0..<max(0, selectionIterations) {
                guard let selectedID = viewModel.selectedID,
                      let selectedIndex = viewModel.results.firstIndex(
                          where: { $0.id == selectedID }
                      ) else {
                    break
                }
                if selectedIndex == viewModel.results.count - 1 {
                    direction = -1
                } else if selectedIndex == 0 {
                    direction = 1
                }

                let startedAt = ProcessInfo.processInfo.systemUptime
                viewModel.moveSelection(by: direction)
                await flushRenderedContent(in: panel)
                selectionSamples.append(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                )
            }
        }

        var settledDetailSamples: [Double] = []
        settledDetailSamples.reserveCapacity(max(0, settledDetailIterations))
        if viewModel.results.count > 1 {
            var direction = 1
            for _ in 0..<max(0, settledDetailIterations) {
                guard let selectedID = viewModel.selectedID,
                      let selectedIndex = viewModel.results.firstIndex(
                          where: { $0.id == selectedID }
                      ) else {
                    break
                }
                if selectedIndex == viewModel.results.count - 1 {
                    direction = -1
                } else if selectedIndex == 0 {
                    direction = 1
                }

                let startedAt = ProcessInfo.processInfo.systemUptime
                viewModel.moveSelection(by: direction)
                // The detail pane intentionally follows a stable selection so
                // rapid arrow movement never blocks the list highlight.
                try? await Task.sleep(for: .milliseconds(50))
                await flushRenderedContent(in: panel)
                settledDetailSamples.append(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                )
            }
        }

        hide(restorePreviousApplication: false)
        return ClipboardInteractionPerformanceReport(
            rootToClipboard: ClipboardInteractionPerformanceDistribution(
                samples: routeSamples
            ),
            selectionMovement: ClipboardInteractionPerformanceDistribution(
                samples: selectionSamples
            ),
            settledDetailPresentation:
                ClipboardInteractionPerformanceDistribution(
                    samples: settledDetailSamples
                )
        )
    }

    private func flushRenderedContent(in panel: NSWindow) async {
        // SwiftUI observes the route or selection change asynchronously. Yield
        // before forcing AppKit layout/display so the sample includes the
        // resulting two-pane hierarchy rather than only the model mutation.
        await Task.yield()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        await Task.yield()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }
    #endif

    func popoverDidClose(_ notification: Notification) {
        activePopover = nil
        viewModel.focusRequestForPopoverDismissal()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard automaticallyHides,
              window?.isVisible == true,
              activePopover?.isShown != true,
              window?.attachedSheet == nil else {
            return
        }
        hide(restorePreviousApplication: false)
    }

    @objc
    private func applicationDidResignActive(_ notification: Notification) {
        guard automaticallyHides, window?.isVisible == true else { return }
        hide(restorePreviousApplication: false)
    }

    private func bindViewModel() {
        viewModel.dismissForLaunch = { [weak self] in
            self?.hide(restorePreviousApplication: false)
        }
        viewModel.reopenAfterLaunchFailure = { [weak self] in
            self?.show(route: .root)
        }
        viewModel.dismissAndRestorePreviousApplication = { [weak self] in
            self?.hide(restorePreviousApplication: true)
        }
        viewModel.presentSnippetEditor = { [weak self] snippet in
            self?.showSnippetEditor(snippet)
        }
        viewModel.confirmDelete = { [weak self] result in
            self?.confirmDeletion(of: result)
        }
        viewModel.copyContent = { [weak self] content in
            guard let self else { return .writeFailedAndRestoreFailed }
            let result = await self.pasteCoordinator.copy(content)
            if result.wasWritten {
                self.hide(restorePreviousApplication: true)
            }
            return result
        }
        viewModel.pasteContent = { [weak self] content, completion in
            guard let self else {
                completion(.failed)
                return
            }
            let targetApplication = self.previousApplication
            let route = self.viewModel.route
            let origin = self.viewModel.presentationOrigin
            let selection = self.viewModel.selectedID
            self.hide(restorePreviousApplication: false)
            self.pasteCoordinator.paste(
                content,
                into: targetApplication,
                completion: { [weak self] result in
                    guard let self else {
                        completion(result)
                        return
                    }
                    if result != .pasted {
                        self.show(route: route, origin: origin)
                        self.viewModel.restoreSelectionAfterOperation(selection)
                    }
                    completion(result)
                }
            )
        }
    }

    @objc
    private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        window?.animationBehavior = PaletteAnimationPolicy.behavior(
            systemReducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            overrides: accessibilityOverrides
        )
    }

    private func installKeyMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.window?.isKeyWindow == true,
                  self.activePopover?.isShown != true else {
                return event
            }

            let action = PaletteKeyEventPolicy.action(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                hasMarkedText: self.fieldEditorHasMarkedText,
                route: self.viewModel.route,
                isActionPanelPresented: self.viewModel.isActionPanelPresented
            )

            switch action {
            case .passThrough:
                return event
            case .handleCommandShortcut:
                let modifiers = event.modifierFlags.intersection(
                    .deviceIndependentFlagsMask
                )
                if self.handleCommandShortcut(event, modifiers: modifiers) {
                    return nil
                }
                return event
            case let .moveSelection(offset):
                if self.viewModel.isActionPanelPresented {
                    self.viewModel.moveActionSelection(by: offset)
                } else {
                    self.viewModel.moveSelection(by: offset)
                }
                return nil
            case .performPrimaryAction:
                if self.viewModel.isActionPanelPresented {
                    self.viewModel.performSelectedAction()
                } else {
                    self.viewModel.performPrimaryAction()
                }
                return nil
            case .escape:
                if self.viewModel.isActionPanelPresented {
                    self.viewModel.dismissActionPanel()
                } else {
                    self.viewModel.escape()
                }
                return nil
            }
        }
    }

    private var fieldEditorHasMarkedText: Bool {
        if let fieldEditor = window?.firstResponder as? NSTextView {
            return fieldEditor.hasMarkedText()
        }

        if let textField = window?.firstResponder as? NSTextField,
           let fieldEditor = textField.currentEditor() as? NSTextView {
            return fieldEditor.hasMarkedText()
        }

        return false
    }

    private func handleCommandShortcut(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        switch event.keyCode {
        case 40:
            viewModel.showActionMenu()
        case 35:
            viewModel.performAction(.togglePin)
        case 14:
            if viewModel.selectedSnippet != nil {
                viewModel.performAction(.editSnippet)
            } else {
                viewModel.performAction(.editAlias)
            }
        case 3 where modifiers.contains(.shift):
            viewModel.performAction(.reveal)
        case 45:
            if viewModel.route == .aliases {
                viewModel.beginAddAlias()
            } else {
                viewModel.newSnippet()
            }
        case 2:
            viewModel.performAction(.duplicateSnippet)
        case 51, 117:
            if viewModel.route == .aliases {
                viewModel.requestAliasDeletion()
            } else {
                viewModel.performAction(.delete)
            }
        case 36, 76:
            guard viewModel.selectedClipboardItem != nil
                    || viewModel.selectedSnippet != nil else {
                return false
            }
            viewModel.performAction(.copy)
        default:
            return false
        }
        return true
    }

    private func showSnippetEditor(_ snippet: Snippet?) {
        guard let contentView = window?.contentView else { return }
        let editor = SnippetEditorView(
            snippet: snippet,
            onCancel: { [weak self] in
                self?.activePopover?.close()
            },
            onSave: { [weak self] name, keyword, content, completion in
                self?.viewModel.saveSnippet(
                    existing: snippet,
                    name: name,
                    keyword: keyword,
                    content: content,
                    completion: completion
                )
            }
        )
        let controller = NSHostingController(
            rootView: editor.environment(\.locale, Locale(identifier: "en"))
        )
        let popover = makePopover(
            contentSize: NSSize(width: 480, height: 390),
            contentViewController: controller
        )
        show(popover: popover, relativeTo: contentView, verticalOffset: 72)
    }

    private func makePopover(
        contentSize: NSSize,
        contentViewController: NSViewController
    ) -> NSPopover {
        activePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = contentSize
        popover.contentViewController = contentViewController
        popover.delegate = self
        activePopover = popover
        return popover
    }

    private func show(
        popover: NSPopover,
        relativeTo contentView: NSView,
        verticalOffset: CGFloat
    ) {
        let anchor = NSRect(
            x: contentView.bounds.midX - 1,
            y: contentView.bounds.maxY - verticalOffset,
            width: 2,
            height: 2
        )
        popover.show(relativeTo: anchor, of: contentView, preferredEdge: .maxY)
    }

    private func confirmDeletion(of result: CommandResult) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch result.kind {
        case .clipboard:
            alert.messageText = "Delete Clipboard Item?"
            alert.informativeText = "This item will be permanently removed from clipboard history."
        case .snippet:
            alert.messageText = "Delete Snippet?"
            alert.informativeText = "“\(result.title)” will be permanently deleted."
        case .application, .feature:
            return
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.viewModel.deleteConfirmed(result)
            }
        }
    }

    private func position(window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let originX = visibleFrame.midX - window.frame.width / 2
        let originY = visibleFrame.maxY - visibleFrame.height * 0.18 - window.frame.height
        window.setFrameOrigin(NSPoint(x: originX, y: max(originY, visibleFrame.minY)))
    }
}

private struct SnippetEditorView: View {
    let snippet: Snippet?
    let onCancel: () -> Void
    let onSave: (
        _ name: String,
        _ keyword: String,
        _ content: String,
        _ completion: @escaping @MainActor (Bool, String?) -> Void
    ) -> Void

    @State private var name: String
    @State private var keyword: String
    @State private var content: String
    @State private var validationMessage: String?
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case keyword
        case content
    }

    init(
        snippet: Snippet?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (
            _ name: String,
            _ keyword: String,
            _ content: String,
            _ completion: @escaping @MainActor (Bool, String?) -> Void
        ) -> Void
    ) {
        self.snippet = snippet
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: snippet?.name ?? "")
        _keyword = State(initialValue: snippet?.keyword ?? "")
        _content = State(initialValue: snippet?.content ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet == nil ? "New Snippet" : "Edit Snippet")
                .font(.headline)

            TextField("Name", text: $name)
                .focused($focusedField, equals: .name)

            TextField("Keyword (optional)", text: $keyword)
                .focused($focusedField, equals: .keyword)

            VStack(alignment: .leading, spacing: 6) {
                Text("Content")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $content)
                    .focused($focusedField, equals: .content)
                    .frame(minHeight: 180)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(18)
        .onAppear {
            focusedField = .name
        }
    }

    private func save() {
        validationMessage = nil
        isSaving = true
        onSave(name, keyword, content) { success, message in
            isSaving = false
            if success {
                onCancel()
            } else {
                validationMessage = message
            }
        }
    }
}
