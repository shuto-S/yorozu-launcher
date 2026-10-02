import AppKit
import ApplicationServices
import KeyboardShortcuts
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

enum PaletteDeactivationPolicy {
    static func shouldHide(
        automaticallyHides: Bool,
        route: PaletteRoute
    ) -> Bool {
        automaticallyHides && route != .settings
    }
}

enum PaletteKeyEventAction: Equatable {
    case passThrough
    case handleCommandShortcut
    case moveSelection(Int)
    case performPrimaryAction
    case submitModal
    case escape
}

enum PaletteCommandShortcut: Equatable {
    case actions, pin, edit, reveal, newItem, duplicate, delete, copy, search, close

    static func match(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
        isEditingText: Bool
    ) -> Self? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        if modifiers == [.command, .shift], characters?.lowercased() == "f" {
            return .reveal
        }
        guard modifiers == .command else { return nil }
        if keyCode == 51 || keyCode == 117 {
            return isEditingText ? nil : .delete
        }
        if keyCode == 36 || keyCode == 76 { return .copy }
        switch characters?.lowercased() {
        case "k": return .actions
        case "p": return .pin
        case "e": return isEditingText ? nil : .edit
        case "n": return .newItem
        case "d": return .duplicate
        case "f": return .search
        case "w": return .close
        default: return nil
        }
    }
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
        isActionPanelPresented: Bool,
        isModalPresented: Bool = false,
        isAIConversationPage: Bool = false,
        isRecordingModifierShortcut: Bool = false,
        isEditingText: Bool = false,
        isAliasApplicationPicker: Bool = false,
        isTextInputFocused: Bool = false
    ) -> PaletteKeyEventAction {
        // The recorder's local monitor owns Escape/Delete while recording.
        // The palette monitor is installed first, so it must defer explicitly.
        if isRecordingModifierShortcut { return .passThrough }
        let independentModifiers = modifiers.intersection(
            .deviceIndependentFlagsMask
        )

        if isModalPresented {
            if hasMarkedText, textCompositionKeyCodes.contains(keyCode) {
                return .passThrough
            }
            if independentModifiers.intersection([.command, .option, .control, .shift]) == .command,
               keyCode == 36 || keyCode == 76 {
                return .submitModal
            }
            if isAliasApplicationPicker,
               independentModifiers.intersection([.command, .option, .control, .shift]).isEmpty {
                if keyCode == 125 { return .moveSelection(1) }
                if keyCode == 126 { return .moveSelection(-1) }
                if keyCode == 36 || keyCode == 76 { return .submitModal }
            }
            return keyCode == 53 ? .escape : .passThrough
        }

        // Composition commands reach the field editor before app commands.
        // Other Command shortcuts remain available while composing.
        if hasMarkedText, textCompositionKeyCodes.contains(keyCode) {
            return .passThrough
        }
        if independentModifiers.contains(.command) {
            return .handleCommandShortcut
        }

        if route.isAI, isAIConversationPage, !isActionPanelPresented {
            if independentModifiers.contains(.command) {
                return .handleCommandShortcut
            }
            return keyCode == 53 ? .escape : .passThrough
        }

        if route == .settings {
            return keyCode == 53 ? .escape : .passThrough
        }

        if route == .translation, !isActionPanelPresented {
            return keyCode == 53 ? .escape : .passThrough
        }

        guard independentModifiers.intersection([.command, .option, .control, .shift]).isEmpty,
              !isEditingText else {
            return keyCode == 53 && independentModifiers.isEmpty ? .escape : .passThrough
        }

        switch keyCode {
        case 116 where !isTextInputFocused:
            return .moveSelection(-8)
        case 121 where !isTextInputFocused:
            return .moveSelection(8)
        case 115 where !isTextInputFocused:
            return .moveSelection(-Int(Int32.max))
        case 119 where !isTextInputFocused:
            return .moveSelection(Int(Int32.max))
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
    let appUpdateController: AppUpdateController?
    let overrides: AccessibilityDisplayOverrides

    var body: some View {
        PaletteView(
            viewModel: viewModel,
            appUpdateController: appUpdateController
        )
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
final class PaletteWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: LauncherViewModel
    private let pasteCoordinator: PasteCoordinator
    private let automaticallyHides: Bool
    private let accessibilityOverrides: AccessibilityDisplayOverrides
    private var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var keyEventMonitor: Any?

    private var shouldHideWhenInactive: Bool {
        PaletteDeactivationPolicy.shouldHide(
            automaticallyHides: automaticallyHides,
            route: viewModel.route
        )
    }

    init(
        viewModel: LauncherViewModel,
        pasteCoordinator: PasteCoordinator,
        appUpdateController: AppUpdateController? = nil
    ) {
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
        // Route-aware dismissal is handled by the delegate and application
        // notifications below. AppKit's automatic hiding cannot distinguish
        // Settings from the palette's transient routes.
        panel.hidesOnDeactivate = false
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
                appUpdateController: appUpdateController,
                overrides: accessibilityOverrides
            )
                .environment(\.locale, Locale(identifier: "en"))
        )

        super.init(window: panel)
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidate() {
        WindowControlModifierCapture.cancelActiveRecording()
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
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    func toggle(route: PaletteRoute = .root) {
        WindowControlModifierCapture.cancelActiveRecording()
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
        WindowControlModifierCapture.cancelActiveRecording()
        guard let panel = window else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        if !panel.isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            rememberExternalApplication(frontmost)
            previousApplication = externalApplication(frontmost)
                ?? validLastExternalApplication
        }

        position(window: panel)
        let selectedText: String?
        let selectedTextPermissionUnavailable: Bool
        if route == .translation {
            selectedText = accessibilitySelectedText(from: previousApplication)
            selectedTextPermissionUnavailable = previousApplication != nil
                && !AXIsProcessTrusted()
        } else {
            selectedText = nil
            selectedTextPermissionUnavailable = false
        }
        viewModel.prepareForPresentation(
            route: route,
            origin: origin,
            selectedText: selectedText,
            selectedTextPermissionUnavailable: selectedTextPermissionUnavailable
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.viewModel.paletteDidBecomeVisible()
        }
        LauncherPerformanceTrace.duration(
            "panel_ordered_front",
            startedAt: startedAt
        )
    }

    func hide(restorePreviousApplication: Bool) {
        WindowControlModifierCapture.cancelActiveRecording()
        viewModel.dismissActionPanel(restoreSearchFocus: false)
        viewModel.paletteDidHide()
        window?.orderOut(nil)
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

    func windowDidResignKey(_ notification: Notification) {
        WindowControlModifierCapture.cancelActiveRecording()
        guard shouldHideWhenInactive,
              window?.isVisible == true,
              window?.attachedSheet == nil else {
            return
        }
        hide(restorePreviousApplication: false)
    }

    func windowWillClose(_ notification: Notification) {
        WindowControlModifierCapture.cancelActiveRecording()
    }

    @objc
    private func applicationDidResignActive(_ notification: Notification) {
        WindowControlModifierCapture.cancelActiveRecording()
        guard shouldHideWhenInactive, window?.isVisible == true else {
            return
        }
        hide(restorePreviousApplication: false)
    }

    @objc
    private func workspaceApplicationDidActivate(_ notification: Notification) {
        rememberExternalApplication(
            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        )
    }

    private var validLastExternalApplication: NSRunningApplication? {
        guard let lastExternalApplication,
              !lastExternalApplication.isTerminated else {
            return nil
        }
        return lastExternalApplication
    }

    private func externalApplication(
        _ application: NSRunningApplication?
    ) -> NSRunningApplication? {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              !application.isTerminated else {
            return nil
        }
        return application
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application = externalApplication(application) else { return }
        lastExternalApplication = application
    }

    private func bindViewModel() {
        viewModel.selectedTextForTranslation = { [weak self] in
            guard let self else { return nil }
            return self.accessibilitySelectedText(from: self.previousApplication)
        }
        viewModel.selectedTextPermissionUnavailableForTranslation = { [weak self] in
            guard let self else { return false }
            return self.previousApplication != nil && !AXIsProcessTrusted()
        }
        viewModel.dismissForLaunch = { [weak self] in
            self?.hide(restorePreviousApplication: false)
        }
        viewModel.reopenAfterLaunchFailure = { [weak self] in
            self?.show(route: .root)
        }
        viewModel.dismissAndRestorePreviousApplication = { [weak self] in
            self?.hide(restorePreviousApplication: true)
        }
        viewModel.copyContent = { [weak self] content in
            guard let self else { return .writeFailedAndRestoreFailed }
            let result = await self.pasteCoordinator.copy(content)
            if result.wasWritten {
                self.hide(restorePreviousApplication: true)
            }
            return result
        }
        viewModel.translationViewModel.copyText = { [weak self] text in
            guard let self else { return .writeFailedAndRestoreFailed }
            return await self.pasteCoordinator.copy(.text(text))
        }
        for chat in viewModel.aiChatViewModelStore.orderedViewModels {
            chat.copyText = { [weak self] text in
                guard let self else { return .writeFailedAndRestoreFailed }
                return await self.pasteCoordinator.copy(.text(text))
            }
        }
        viewModel.pasteContent = { [weak self] content, completion in
            guard let self else {
                completion(.failed)
                return
            }
            guard !self.pasteCoordinator.isOperationInProgress else {
                completion(.busy)
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

    private func accessibilitySelectedText(
        from application: NSRunningApplication?
    ) -> String? {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted() else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
        let selectedText = selectedValue as? String else {
            return nil
        }
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : selectedText
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
            guard let self else { return event }
            return self.handleMonitoredKeyEvent(event)
        }
    }

    private func handleMonitoredKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard self.window?.isKeyWindow == true else {
            return event
        }

        return handleKeyAction(keyAction(for: event), event: event)
    }

    // Keep responder inspection separate from dispatch: Swift 6.3/6.4's
    // Release optimizer crashes when these borrowed AppKit values are combined.
    @inline(never)
    private func keyAction(for event: NSEvent) -> PaletteKeyEventAction {
        let hasTextEditor = activeTextEditor != nil
        var isRecording = WindowControlModifierCapture.isAnyRecording
        if window?.firstResponder is KeyboardShortcuts.RecorderCocoa { isRecording = true }
        if isRecordingShortcutInFieldEditor { isRecording = true }
        var isConversation = false
        if viewModel.route.isAI { isConversation = !viewModel.aiChatViewModel.isListVisible }
        var isEditing = false
        var isPickingApplication = false
        if hasTextEditor {
            if !isSearchEditor { isEditing = !viewModel.isActionPanelPresented }
            isPickingApplication = viewModel.paletteModal == .aliasApplicationPicker
        }

        return PaletteKeyEventPolicy.action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            hasMarkedText: self.fieldEditorHasMarkedText,
            route: self.viewModel.route,
            isActionPanelPresented: self.viewModel.isActionPanelPresented,
            isModalPresented: self.viewModel.isModalPresented,
            isAIConversationPage: isConversation,
            isRecordingModifierShortcut: isRecording,
            isEditingText: isEditing,
            isAliasApplicationPicker: isPickingApplication,
            isTextInputFocused: hasTextEditor
        )
    }

    @inline(never)
    private var isRecordingShortcutInFieldEditor: Bool {
        guard let editor = activeTextEditor else { return false }
        return editor.delegate is KeyboardShortcuts.RecorderCocoa
    }

    @inline(never)
    private func handleKeyAction(_ action: PaletteKeyEventAction, event: NSEvent) -> NSEvent? {
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
            if self.viewModel.paletteModal == .aliasApplicationPicker {
                self.viewModel.moveAliasApplicationSelection(by: offset)
            } else if self.viewModel.isActionPanelPresented {
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
        case .submitModal:
            self.viewModel.performModalSubmit()
            return nil
        case .escape:
            if self.viewModel.isActionPanelPresented {
                self.viewModel.escapeActionPanel()
            } else {
                self.viewModel.escape()
            }
            return nil
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

    private var activeTextEditor: NSTextView? {
        (window?.firstResponder as? NSTextView)
            ?? (window?.firstResponder as? NSTextField)?.currentEditor() as? NSTextView
    }

    private var isSearchEditor: Bool {
        activeTextEditor?.delegate is NSSearchField
            || window?.firstResponder is NSSearchField
    }

    private func handleCommandShortcut(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard let shortcut = PaletteCommandShortcut.match(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: modifiers, isEditingText: activeTextEditor != nil
        ) else { return false }
        if shortcut == .search {
            viewModel.requestSearchFocus()
            return viewModel.route != .settings
        }
        if shortcut == .close {
            viewModel.dismissAndRestorePreviousApplication?()
            return true
        }
        if viewModel.route == .settings { return false }
        if viewModel.route == .translation, shortcut == .copy {
            viewModel.translationViewModel.translate()
            return true
        }
        let action: LauncherActionID
        switch shortcut {
        case .actions:
            viewModel.showActionMenu()
            return true
        case .pin: action = .togglePin
        case .edit:
            action = viewModel.selectedSnippet != nil ? .editSnippet : .editAlias
        case .reveal: action = .reveal
        case .newItem:
            if viewModel.route.isAI {
                viewModel.aiChatViewModel.beginNewChat()
            } else if viewModel.route == .aliases {
                viewModel.beginAddAlias()
            } else if viewModel.route == .snippets {
                viewModel.newSnippet()
            } else {
                return false
            }
            return true
        case .duplicate: action = .duplicateSnippet
        case .delete:
            if viewModel.route.isAI {
                guard viewModel.actionItems.contains(where: { $0.id == .aiDelete }) else { return false }
                viewModel.requestAIConversationDeletion()
            } else if viewModel.route == .aliases {
                viewModel.requestAliasDeletion()
            } else if viewModel.actionItems.contains(where: { $0.id == .delete }) {
                viewModel.performAction(.delete)
            } else {
                return false
            }
            return true
        case .copy: action = .copy
        case .search, .close:
            return false
        }
        guard viewModel.actionItems.contains(where: { $0.id == action }) else { return false }
        viewModel.performAction(action)
        return true
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
