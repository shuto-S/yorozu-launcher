import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import Combine
import CoreGraphics
import Foundation
import Security

private nonisolated(unsafe) let commandInputModeAccessibilityPromptKey =
    kAXTrustedCheckOptionPrompt.takeUnretainedValue()

enum CommandInputModeAction: Hashable, Sendable {
    case switchToEnglish
    case switchToJapanese

    var title: String {
        switch self {
        case .switchToEnglish:
            "English"
        case .switchToJapanese:
            "Japanese"
        }
    }

    var inputModeKeyCode: CGKeyCode {
        switch self {
        case .switchToEnglish:
            102
        case .switchToJapanese:
            104
        }
    }
}

enum CommandInputModeSwitchResult: Equatable, Sendable {
    case switched(sourceID: String)
    case alreadySelected(sourceID: String)
    case sourceUnavailable(CommandInputModeAction)
    case selectionFailed
    case verificationTimedOut
    case cancelled

    var title: String {
        switch self {
        case .switched:
            "Switched"
        case .alreadySelected:
            "Already Selected"
        case .sourceUnavailable:
            "Input Source Unavailable"
        case .selectionFailed:
            "Selection Failed"
        case .verificationTimedOut:
            "Verification Timed Out"
        case .cancelled:
            "Cancelled"
        }
    }
}

struct CommandInputModeSwitchReport: Equatable, Sendable {
    let action: CommandInputModeAction
    let result: CommandInputModeSwitchResult
    let sourceIDBefore: String?
    let sourceIDAfter: String?
    let completedAt: Date
}

struct CommandInputModeAuthorizationSnapshot: Equatable, Sendable {
    let accessibilityGranted: Bool
    let listenEventGranted: Bool
    let postEventGranted: Bool
}

struct CommandInputSourceCandidate: Equatable, Sendable {
    let id: String
    let languages: [String]
    let isASCIICapable: Bool
    let isEnabled: Bool
    let isSelectCapable: Bool
    let isKeyboardSource: Bool
}

// Text Input Source Services communicates with the per-user text input
// session. Keep every TIS query and mutation on the main actor so a Command
// release cannot race that session from Swift's generic executor.
@MainActor
protocol CommandInputSourceSystem: Sendable {
    func currentSourceID() -> String?
    func candidates() -> [CommandInputSourceCandidate]
    func preferredSourceID(for action: CommandInputModeAction) -> String?
}

@MainActor
protocol CommandInputModeEventPosting: Sendable {
    @discardableResult
    func post(_ action: CommandInputModeAction) -> Bool
}

protocol CommandInputSourceSwitching: Sendable {
    func switchInputMode(
        _ action: CommandInputModeAction
    ) async -> CommandInputModeSwitchReport
}

@MainActor
protocol CommandInputSourceStatusProviding: AnyObject {
    var currentSourceID: String? { get }
    var currentSourceDidChange: (() -> Void)? { get set }

    func start()
    func stop()
    func refresh()
}

enum CommandInputSourceResolver {
    private static let appleABCSourceID = "com.apple.keylayout.ABC"
    private static let appleJapaneseSourceID =
        "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"

    static func sourceID(
        for action: CommandInputModeAction,
        candidates: [CommandInputSourceCandidate],
        preferredSourceID: String?
    ) -> String? {
        let selectable = candidates.filter {
            $0.isEnabled && $0.isSelectCapable && $0.isKeyboardSource
        }
        let matching: [CommandInputSourceCandidate]
        let appleFallbackID: String
        switch action {
        case .switchToEnglish:
            matching = selectable.filter(\.isASCIICapable)
            appleFallbackID = appleABCSourceID
        case .switchToJapanese:
            matching = selectable.filter { candidate in
                candidate.languages.contains(where: isJapaneseLanguage)
            }
            appleFallbackID = appleJapaneseSourceID
        }

        if let preferredSourceID,
           matching.contains(where: { $0.id == preferredSourceID }) {
            return preferredSourceID
        }
        if matching.contains(where: { $0.id == appleFallbackID }) {
            return appleFallbackID
        }
        return matching.map(\.id).sorted().first
    }

    static func sourceID(
        _ sourceID: String?,
        matches action: CommandInputModeAction,
        candidates: [CommandInputSourceCandidate]
    ) -> Bool {
        guard let sourceID,
              let candidate = candidates.first(where: { $0.id == sourceID }),
              candidate.isEnabled,
              candidate.isSelectCapable,
              candidate.isKeyboardSource
        else {
            return false
        }
        switch action {
        case .switchToEnglish:
            return candidate.isASCIICapable
        case .switchToJapanese:
            return candidate.languages.contains(where: isJapaneseLanguage)
        }
    }

    private static func isJapaneseLanguage(_ language: String) -> Bool {
        let normalized = language.lowercased()
        return normalized == "ja"
            || normalized.hasPrefix("ja-")
            || normalized.hasPrefix("ja_")
    }
}

@MainActor
final class SystemCommandInputSourceSwitcher: CommandInputSourceSwitching {
    private let system: any CommandInputSourceSystem
    private let eventPoster: any CommandInputModeEventPosting

    init(
        system: any CommandInputSourceSystem = SystemCommandInputSourceSystem(),
        eventPoster: any CommandInputModeEventPosting =
            SystemCommandInputModeEventPoster()
    ) {
        self.system = system
        self.eventPoster = eventPoster
    }

    func switchInputMode(
        _ action: CommandInputModeAction
    ) async -> CommandInputModeSwitchReport {
        guard !Task.isCancelled else {
            return report(action: action, result: .cancelled, before: nil, after: nil)
        }
        let sourceIDBefore = system.currentSourceID()
        let candidates = system.candidates()
        let targetSourceID = CommandInputSourceResolver.sourceID(
            for: action,
            candidates: candidates,
            preferredSourceID: system.preferredSourceID(for: action)
        )
        guard let targetSourceID else {
            return report(
                action: action,
                result: .sourceUnavailable(action),
                before: sourceIDBefore,
                after: system.currentSourceID()
            )
        }
        if CommandInputSourceResolver.sourceID(
            sourceIDBefore,
            matches: action,
            candidates: candidates
        ) {
            return report(
                action: action,
                result: .alreadySelected(sourceID: sourceIDBefore ?? targetSourceID),
                before: sourceIDBefore,
                after: sourceIDBefore
            )
        }
        // A stopped tap may cancel a switch queued for the main actor. Never
        // send its key pair after monitoring has been suspended.
        guard !Task.isCancelled else {
            return report(
                action: action, result: .cancelled,
                before: sourceIDBefore, after: sourceIDBefore
            )
        }
        guard eventPoster.post(action) else {
            return report(
                action: action,
                result: .selectionFailed,
                before: sourceIDBefore,
                after: system.currentSourceID()
            )
        }

        // A real Eisu/Kana key event updates the active application's text
        // input context. This is the same mechanism used by dedicated input
        // switching utilities and avoids TIS state drifting from the focused
        // application's effective input mode.
        for attempt in 0 ..< 8 {
            guard !Task.isCancelled else {
                return report(
                    action: action,
                    result: .cancelled,
                    before: sourceIDBefore,
                    after: system.currentSourceID()
                )
            }
            let sourceIDAfter = system.currentSourceID()
            if CommandInputSourceResolver.sourceID(
                sourceIDAfter,
                matches: action,
                candidates: candidates
            ) {
                return report(
                    action: action,
                    result: .switched(sourceID: sourceIDAfter ?? targetSourceID),
                    before: sourceIDBefore,
                    after: sourceIDAfter
                )
            }
            if attempt < 7 {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return report(
                        action: action,
                        result: .cancelled,
                        before: sourceIDBefore,
                        after: system.currentSourceID()
                    )
                }
            }
        }
        return report(
            action: action,
            result: .verificationTimedOut,
            before: sourceIDBefore,
            after: system.currentSourceID()
        )
    }

    private func report(
        action: CommandInputModeAction,
        result: CommandInputModeSwitchResult,
        before: String?,
        after: String?
    ) -> CommandInputModeSwitchReport {
        CommandInputModeSwitchReport(
            action: action,
            result: result,
            sourceIDBefore: before,
            sourceIDAfter: after,
            completedAt: Date()
        )
    }
}

@MainActor
final class SystemCommandInputModeEventPoster: CommandInputModeEventPosting {
    func post(_ action: CommandInputModeAction) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: action.inputModeKeyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: action.inputModeKeyCode,
                keyDown: false
              ) else {
            return false
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
final class SystemCommandInputSourceSystem: CommandInputSourceSystem {
    func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?
            .takeRetainedValue() else {
            return nil
        }
        return sourceID(of: source)
    }

    func candidates() -> [CommandInputSourceCandidate] {
        guard let rawSources = TISCreateInputSourceList(nil, false)?
            .takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return rawSources.compactMap { source in
            guard let id = sourceID(of: source) else { return nil }
            return CommandInputSourceCandidate(
                id: id,
                languages: languages(of: source),
                isASCIICapable: booleanProperty(
                    kTISPropertyInputSourceIsASCIICapable,
                    of: source
                ),
                isEnabled: booleanProperty(
                    kTISPropertyInputSourceIsEnabled,
                    of: source
                ),
                isSelectCapable: booleanProperty(
                    kTISPropertyInputSourceIsSelectCapable,
                    of: source
                ),
                isKeyboardSource: isKeyboardSource(source)
            )
        }
    }

    func preferredSourceID(for action: CommandInputModeAction) -> String? {
        let source: TISInputSource?
        switch action {
        case .switchToEnglish:
            source = TISCopyCurrentASCIICapableKeyboardInputSource()?
                .takeRetainedValue()
        case .switchToJapanese:
            source = TISCopyInputSourceForLanguage("ja" as CFString)?
                .takeRetainedValue()
        }
        guard let source else { return nil }
        return sourceID(of: source)
    }

    private func sourceID(of source: TISInputSource) -> String? {
        stringProperty(kTISPropertyInputSourceID, of: source)
    }

    private func languages(of source: TISInputSource) -> [String] {
        guard let value = property(
            kTISPropertyInputSourceLanguages,
            of: source
        ), CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        return value as? [String] ?? []
    }

    private func booleanProperty(
        _ key: CFString,
        of source: TISInputSource
    ) -> Bool {
        guard let value = property(key, of: source),
              CFGetTypeID(value) == CFBooleanGetTypeID(),
              let boolean = value as? Bool else {
            return false
        }
        return boolean
    }

    private func isKeyboardSource(_ source: TISInputSource) -> Bool {
        guard stringProperty(
            kTISPropertyInputSourceCategory,
            of: source
        ) == kTISCategoryKeyboardInputSource as String else {
            return false
        }
        let sourceType = stringProperty(
            kTISPropertyInputSourceType,
            of: source
        )
        return sourceType == kTISTypeKeyboardLayout as String
            || sourceType == kTISTypeKeyboardInputMode as String
    }

    private func stringProperty(
        _ key: CFString,
        of source: TISInputSource
    ) -> String? {
        guard let value = property(key, of: source),
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private func property(
        _ key: CFString,
        of source: TISInputSource
    ) -> CFTypeRef? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer)
            .takeUnretainedValue()
    }
}

@MainActor
final class SystemCommandInputSourceStatusProvider:
    CommandInputSourceStatusProviding {
    private let system: any CommandInputSourceSystem
    private var notificationToken: (any NSObjectProtocol)?
    private(set) var currentSourceID: String?
    var currentSourceDidChange: (() -> Void)?

    init(system: any CommandInputSourceSystem = SystemCommandInputSourceSystem()) {
        self.system = system
    }

    func start() {
        guard notificationToken == nil else {
            refresh()
            return
        }
        notificationToken = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
            self.notificationToken = nil
        }
    }

    func refresh() {
        let nextSourceID = system.currentSourceID()
        guard nextSourceID != currentSourceID else { return }
        currentSourceID = nextSourceID
        currentSourceDidChange?()
    }
}

enum CommandInputModeMonitorStatus: Equatable, Sendable {
    case stopped
    case running
    case temporarilyDisabled
    case creationFailed

    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .running:
            "Running"
        case .temporarilyDisabled:
            "Recovering"
        case .creationFailed:
            "Could Not Start"
        }
    }
}

enum CommandInputModeCodeSigningStatus: Equatable, Sendable {
    case stable
    case adHoc
    case unknown

    var title: String {
        switch self {
        case .stable:
            "Stable"
        case .adHoc:
            "Ad Hoc"
        case .unknown:
            "Unknown"
        }
    }
}

struct CommandInputModeStateMachine: Sendable {
    enum CommandSide: Hashable, Sendable {
        case left
        case right

        var action: CommandInputModeAction {
            switch self {
            case .left:
                .switchToEnglish
            case .right:
                .switchToJapanese
            }
        }
    }

    private(set) var pressedCommands: Set<CommandSide> = []
    private(set) var candidate: CommandSide?

    mutating func handleFlagsChanged(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> CommandInputModeAction? {
        guard let side = Self.commandSide(for: keyCode) else {
            // Any modifier activity means Command was not pressed alone. This
            // includes releasing a modifier that was already held when the
            // event tap started.
            cancelCandidate()
            return nil
        }

        if pressedCommands.contains(side) {
            pressedCommands.remove(side)
            let action = candidate == side && pressedCommands.isEmpty
                ? side.action
                : nil
            candidate = nil
            return action
        }

        // flagsChanged has no separate key-down/key-up event type. Track each
        // Command key's transitions from the event sequence itself. Querying
        // CGEventSource.keyState here can observe the source state table before
        // this head-insert event has advanced it.
        guard flags.contains(.maskCommand) else { return nil }

        pressedCommands.insert(side)
        if candidate == nil,
           pressedCommands.count == 1,
           !Self.containsOtherModifier(flags) {
            candidate = side
        } else {
            cancelCandidate()
        }
        return nil
    }

    mutating func synchronizePressedCommands(_ commands: Set<CommandSide>) {
        pressedCommands = commands
        candidate = nil
    }

    mutating func handleKeyboardActivity() {
        cancelCandidate()
    }

    mutating func handleMouseActivity() {
        cancelCandidate()
    }

    mutating func reset() {
        pressedCommands.removeAll(keepingCapacity: true)
        candidate = nil
    }

    private mutating func cancelCandidate() {
        candidate = nil
    }

    private static func commandSide(for keyCode: CGKeyCode) -> CommandSide? {
        switch keyCode {
        case 55:
            .left
        case 54:
            .right
        default:
            nil
        }
    }

    private static func containsOtherModifier(_ flags: CGEventFlags) -> Bool {
        let otherModifierFlags: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskSecondaryFn,
            .maskAlphaShift,
        ]
        return flags.intersection(otherModifierFlags).isEmpty == false
    }
}

@MainActor
protocol CommandInputModeMonitoring: AnyObject {
    var isRunning: Bool { get }
    var status: CommandInputModeMonitorStatus { get }
    var lastCommandEventAt: Date? { get }
    var lastAction: CommandInputModeAction? { get }
    var lastActionAt: Date? { get }
    var lastSwitchReport: CommandInputModeSwitchReport? { get }
    var diagnosticsDidChange: (() -> Void)? { get set }

    func start() -> Bool
    func stop()
    func recover(recreate: Bool) async -> Bool
    func switchForTesting(_ action: CommandInputModeAction)
}

@MainActor
protocol CommandInputModePermissionProviding: AnyObject {
    var isAccessibilityGranted: Bool { get }
    var authorizationSnapshot: CommandInputModeAuthorizationSnapshot { get }
    var isSystemSettingsActive: Bool { get }

    func requestAccessibilityAccess()
    func openAccessibilitySettings()
    func requestInputMonitoringAccess()
    func openInputMonitoringSettings()
    func revealCurrentBuild()
}

extension CommandInputModePermissionProviding {
    var isSystemSettingsActive: Bool { false }

    var authorizationSnapshot: CommandInputModeAuthorizationSnapshot {
        CommandInputModeAuthorizationSnapshot(
            accessibilityGranted: isAccessibilityGranted,
            listenEventGranted: false,
            postEventGranted: false
        )
    }

    func requestInputMonitoringAccess() {}
    func openInputMonitoringSettings() {}
}

@MainActor
protocol CommandInputModeCodeSigningStatusProviding: AnyObject {
    var status: CommandInputModeCodeSigningStatus { get }
}

@MainActor
protocol CommandInputModeBackgroundActivityManaging: AnyObject {
    var isActive: Bool { get }

    func begin()
    func end()
}

@MainActor
final class SystemCommandInputModeBackgroundActivityManager:
    CommandInputModeBackgroundActivityManaging {
    private static let reason =
        "Listening for user-enabled Command input mode shortcuts"
    static let activityOptions: ProcessInfo.ActivityOptions = [
        .userInitiatedAllowingIdleSystemSleep,
        .automaticTerminationDisabled,
    ]

    private let processInfo: ProcessInfo
    private var activity: (any NSObjectProtocol)?

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    var isActive: Bool {
        activity != nil
    }

    func begin() {
        guard activity == nil else { return }
        // This monitor exists only because the user explicitly enabled a
        // global shortcut service. Classifying it as discretionary background
        // work makes the process eligible for App Nap as soon as Yorozu is no
        // longer frontmost, delaying the event tap and the subsequent TIS
        // selection. Keep the user-requested activity responsive without
        // blocking idle system sleep.
        activity = processInfo.beginActivity(
            options: Self.activityOptions,
            reason: Self.reason
        )
    }

    func end() {
        guard let activity else { return }
        processInfo.endActivity(activity)
        self.activity = nil
    }
}

@MainActor
final class NoOpCommandInputModeBackgroundActivityManager:
    CommandInputModeBackgroundActivityManaging {
    private(set) var isActive = false

    func begin() {
        isActive = true
    }

    func end() {
        isActive = false
    }
}

@MainActor
final class SystemCommandInputModePermissionProvider: CommandInputModePermissionProviding {
    var isSystemSettingsActive: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
    }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var authorizationSnapshot: CommandInputModeAuthorizationSnapshot {
        CommandInputModeAuthorizationSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            listenEventGranted: CGPreflightListenEventAccess(),
            postEventGranted: CGPreflightPostEventAccess()
        )
    }

    func requestAccessibilityAccess() {
        let promptKey = commandInputModeAccessibilityPromptKey as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.openAccessibilitySettings()
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func requestInputMonitoringAccess() {
        _ = CGRequestListenEventAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.openInputMonitoringSettings()
        }
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealCurrentBuild() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

@MainActor
final class SystemCommandInputModeCodeSigningStatusProvider:
    CommandInputModeCodeSigningStatusProviding {
    let status: CommandInputModeCodeSigningStatus

    init() {
        status = Self.readStatus()
    }

    private static func readStatus() -> CommandInputModeCodeSigningStatus {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode else {
            return .unknown
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            dynamicCode,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess, let staticCode else {
            return .unknown
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess, let signingInformation else {
            return .unknown
        }

        let information = signingInformation as NSDictionary
        return classifySigningInformation(
            teamIdentifier: information[kSecCodeInfoTeamIdentifier] as? String,
            certificateCount: (
                information[kSecCodeInfoCertificates] as? NSArray
            )?.count ?? 0,
            hasIdentifier: information[kSecCodeInfoIdentifier] != nil
        )
    }

    static func classifySigningInformation(
        teamIdentifier: String?,
        certificateCount: Int,
        hasIdentifier: Bool
    ) -> CommandInputModeCodeSigningStatus {
        if teamIdentifier?.isEmpty == false || certificateCount > 0 {
            return .stable
        }
        if hasIdentifier {
            return .adHoc
        }
        return .unknown
    }
}

struct CommandInputModeMonitorDiagnostics: Sendable {
    let sequence: UInt64
    let status: CommandInputModeMonitorStatus
    let lastCommandEventAt: Date?
    let lastAction: CommandInputModeAction?
    let lastActionAt: Date?
    let lastSwitchReport: CommandInputModeSwitchReport?
}

final class CommandInputModeEventTapWorker: @unchecked Sendable {
    private final class StartResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?

        func complete(_ result: Bool) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func read() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.flagsChanged,
        .keyDown,
        .keyUp,
        .leftMouseDown,
        .leftMouseUp,
        .leftMouseDragged,
        .rightMouseDown,
        .rightMouseUp,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        .scrollWheel,
    ].reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
    }

    private let lock = NSLock()
    private let inputSourceSwitcher: any CommandInputSourceSwitching
    private let diagnosticsHandler: @Sendable (
        CommandInputModeMonitorDiagnostics
    ) -> Void
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var thread: Thread?
    private var running = false
    private var stopRequested = false
    private var status: CommandInputModeMonitorStatus = .stopped
    private var diagnosticsSequence: UInt64 = 0
    private var lastCommandEventAt: Date?
    private var lastAction: CommandInputModeAction?
    private var lastActionAt: Date?
    private var lastSwitchReport: CommandInputModeSwitchReport?
    private var switchGeneration: UInt64 = 0
    private var switchTask: Task<Void, Never>?
    private var stateMachine = CommandInputModeStateMachine()

    init(
        inputSourceSwitcher: any CommandInputSourceSwitching,
        diagnosticsHandler: @escaping @Sendable (
            CommandInputModeMonitorDiagnostics
        ) -> Void
    ) {
        self.inputSourceSwitcher = inputSourceSwitcher
        self.diagnosticsHandler = diagnosticsHandler
    }

    var isRunning: Bool {
        lock.lock()
        let running = running
        let eventTap = eventTap
        lock.unlock()
        guard running, let eventTap else { return false }
        return CFMachPortIsValid(eventTap)
            && CGEvent.tapIsEnabled(tap: eventTap)
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return thread == nil
    }

    var diagnostics: CommandInputModeMonitorDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return makeDiagnosticsLocked()
    }

    func start() -> Bool {
        lock.lock()
        if running {
            let eventTap = eventTap
            lock.unlock()
            guard let eventTap else { return false }
            return CFMachPortIsValid(eventTap)
                && CGEvent.tapIsEnabled(tap: eventTap)
        }
        guard thread == nil else {
            lock.unlock()
            return false
        }
        stopRequested = false
        let semaphore = DispatchSemaphore(value: 0)
        let result = StartResult()
        let thread = Thread { [weak self] in
            autoreleasepool {
                self?.runEventTap(result: result, semaphore: semaphore)
            }
        }
        thread.name = "com.yorozu.app.input-mode-switching"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        lock.unlock()

        thread.start()
        guard semaphore.wait(timeout: .now() + 1) == .success else {
            stop()
            return false
        }
        return result.read() == true
    }

    func stop() {
        lock.lock()
        stopRequested = true
        switchGeneration &+= 1
        let switchTask = switchTask
        self.switchTask = nil
        running = false
        status = .stopped
        diagnosticsSequence &+= 1
        let diagnostics = makeDiagnosticsLocked()
        let runLoop = runLoop
        let eventTap = eventTap
        lock.unlock()

        switchTask?.cancel()
        // Detach from the system input path even if the worker run loop is busy.
        // Invalidation also prevents a racing startup from enabling this port again.
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        diagnosticsHandler(diagnostics)
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    func switchForTesting(_ action: CommandInputModeAction) {
        beginSwitch(action)
    }

    private func runEventTap(
        result: StartResult,
        semaphore: DispatchSemaphore
    ) {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let worker = Unmanaged<CommandInputModeEventTapWorker>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                worker.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            completeStart(
                false,
                status: .creationFailed,
                result: result,
                semaphore: semaphore
            )
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            completeStart(
                false,
                status: .creationFailed,
                result: result,
                semaphore: semaphore
            )
            return
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            CFMachPortInvalidate(eventTap)
            completeStart(
                false,
                status: .stopped,
                result: result,
                semaphore: semaphore
            )
            return
        }
        runLoop = currentRunLoop
        self.eventTap = eventTap
        lock.unlock()

        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        // tapCreate enables the port. Do not re-enable it if stop invalidated
        // the port while this run-loop source was being installed.
        stateMachine.synchronizePressedCommands(
            Self.currentlyPressedCommandSides()
        )

        lock.lock()
        let started = !stopRequested
            && CFMachPortIsValid(eventTap)
            && CGEvent.tapIsEnabled(tap: eventTap)
        running = started
        status = started ? .running : .creationFailed
        diagnosticsSequence &+= 1
        let diagnostics = makeDiagnosticsLocked()
        lock.unlock()

        diagnosticsHandler(diagnostics)
        result.complete(started)
        semaphore.signal()
        if started {
            CFRunLoopRun()
        }

        stateMachine.reset()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        CFMachPortInvalidate(eventTap)

        lock.lock()
        running = false
        status = stopRequested ? .stopped : .temporarilyDisabled
        runLoop = nil
        self.eventTap = nil
        thread = nil
        diagnosticsSequence &+= 1
        let stoppedDiagnostics = makeDiagnosticsLocked()
        lock.unlock()
        diagnosticsHandler(stoppedDiagnostics)
    }

    private func completeStart(
        _ started: Bool,
        status: CommandInputModeMonitorStatus,
        result: StartResult,
        semaphore: DispatchSemaphore
    ) {
        lock.lock()
        running = false
        self.status = stopRequested ? .stopped : status
        thread = nil
        diagnosticsSequence &+= 1
        let diagnostics = makeDiagnosticsLocked()
        lock.unlock()
        diagnosticsHandler(diagnostics)
        result.complete(started)
        semaphore.signal()
    }

    func handle(type: CGEventType, event: CGEvent) {
        lock.lock()
        let shouldIgnore = stopRequested
        lock.unlock()
        guard !shouldIgnore else { return }

        switch type {
        case .flagsChanged:
            let keyCode = CGKeyCode(
                event.getIntegerValueField(.keyboardEventKeycode)
            )
            if keyCode == 55 || keyCode == 54 {
                publishDiagnostics {
                    lastCommandEventAt = Date()
                }
            }
            if let action = stateMachine.handleFlagsChanged(
                keyCode: keyCode,
                flags: event.flags
            ) {
                enqueueSwitchAfterCallback(action)
            }
        case .keyDown, .keyUp:
            stateMachine.handleKeyboardActivity()
        case .leftMouseDown, .leftMouseUp,
             .leftMouseDragged, .rightMouseDown, .rightMouseUp,
             .rightMouseDragged, .otherMouseDown, .otherMouseUp,
             .otherMouseDragged, .scrollWheel:
            stateMachine.handleMouseActivity()
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            stateMachine.reset()
            // Permission may have been revoked. Only the controller may recover,
            // after a fresh authorization check outside the input callback.
            stop()
        default:
            stateMachine.reset()
        }
    }

    private func enqueueSwitchAfterCallback(_ action: CommandInputModeAction) {
        lock.lock()
        let runLoop = runLoop
        let shouldIgnore = stopRequested
        lock.unlock()
        guard let runLoop, !shouldIgnore else { return }

        // Posting the synthetic Eisu/Kana event is intentionally deferred
        // until this callback returns. Work inside the callback can delay the
        // tap long enough for macOS to disable it.
        CFRunLoopPerformBlock(
            runLoop,
            CFRunLoopMode.commonModes.rawValue as CFString
        ) { [weak self] in
            self?.beginSwitch(action)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func beginSwitch(_ action: CommandInputModeAction) {
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            return
        }
        switchGeneration &+= 1
        let generation = switchGeneration
        let previousTask = switchTask
        lock.unlock()

        previousTask?.cancel()
        publishDiagnostics {
            lastAction = action
            lastActionAt = Date()
        }

        let inputSourceSwitcher = inputSourceSwitcher
        let task = Task { [weak self] in
            let report = await inputSourceSwitcher.switchInputMode(action)
            self?.finishSwitch(report, generation: generation)
        }
        lock.lock()
        if generation == switchGeneration, !stopRequested {
            switchTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func finishSwitch(
        _ report: CommandInputModeSwitchReport,
        generation: UInt64
    ) {
        lock.lock()
        guard generation == switchGeneration, !stopRequested else {
            lock.unlock()
            return
        }
        switchTask = nil
        lastSwitchReport = report
        diagnosticsSequence &+= 1
        let diagnostics = makeDiagnosticsLocked()
        lock.unlock()
        diagnosticsHandler(diagnostics)
    }

    private func publishDiagnostics(_ update: () -> Void) {
        lock.lock()
        update()
        diagnosticsSequence &+= 1
        let diagnostics = makeDiagnosticsLocked()
        lock.unlock()
        diagnosticsHandler(diagnostics)
    }

    private func makeDiagnosticsLocked() -> CommandInputModeMonitorDiagnostics {
        CommandInputModeMonitorDiagnostics(
            sequence: diagnosticsSequence,
            status: status,
            lastCommandEventAt: lastCommandEventAt,
            lastAction: lastAction,
            lastActionAt: lastActionAt,
            lastSwitchReport: lastSwitchReport
        )
    }

    private static func currentlyPressedCommandSides() -> Set<
        CommandInputModeStateMachine.CommandSide
    > {
        var sides: Set<CommandInputModeStateMachine.CommandSide> = []
        if CGEventSource.keyState(.combinedSessionState, key: 55) {
            sides.insert(.left)
        }
        if CGEventSource.keyState(.combinedSessionState, key: 54) {
            sides.insert(.right)
        }
        return sides
    }
}

@MainActor
final class CommandInputModeMonitor: CommandInputModeMonitoring {
    private var monitoringRevision: UInt64 = 0
    private let inputSourceSwitcher: any CommandInputSourceSwitching
    private lazy var worker = CommandInputModeEventTapWorker(
        inputSourceSwitcher: inputSourceSwitcher
    ) { [weak self] diagnostics in
        Task { @MainActor [weak self] in
            self?.apply(diagnostics)
        }
    }
    private var lastDiagnosticsSequence: UInt64?
    var diagnosticsDidChange: (() -> Void)?
    private(set) var status: CommandInputModeMonitorStatus = .stopped
    private(set) var lastCommandEventAt: Date?
    private(set) var lastAction: CommandInputModeAction?
    private(set) var lastActionAt: Date?
    private(set) var lastSwitchReport: CommandInputModeSwitchReport?

    init(
        inputSourceSwitcher: any CommandInputSourceSwitching =
            SystemCommandInputSourceSwitcher()
    ) {
        self.inputSourceSwitcher = inputSourceSwitcher
    }

    var isRunning: Bool { worker.isRunning }

    func start() -> Bool {
        let started = worker.start()
        apply(worker.diagnostics)
        return started
    }

    func stop() {
        monitoringRevision &+= 1
        worker.stop()
        apply(worker.diagnostics)
    }

    func recover(recreate: Bool) async -> Bool {
        if !recreate, worker.isRunning {
            return true
        }

        stop()
        let revision = monitoringRevision
        for _ in 0 ..< 50 {
            guard !worker.isStopped else { break }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                apply(worker.diagnostics)
                return false
            }
        }
        guard worker.isStopped, monitoringRevision == revision, !Task.isCancelled else {
            apply(worker.diagnostics)
            return false
        }
        let started = worker.start()
        apply(worker.diagnostics)
        return started
    }

    func switchForTesting(_ action: CommandInputModeAction) {
        worker.switchForTesting(action)
        apply(worker.diagnostics)
    }

    private func apply(_ diagnostics: CommandInputModeMonitorDiagnostics) {
        if let lastDiagnosticsSequence,
           diagnostics.sequence <= lastDiagnosticsSequence {
            return
        }
        lastDiagnosticsSequence = diagnostics.sequence
        status = diagnostics.status
        lastCommandEventAt = diagnostics.lastCommandEventAt
        lastAction = diagnostics.lastAction
        lastActionAt = diagnostics.lastActionAt
        lastSwitchReport = diagnostics.lastSwitchReport
        diagnosticsDidChange?()
    }
}

@MainActor
final class CommandInputModeController: ObservableObject {
    enum RuntimeStatus: Equatable {
        case off
        case active
        case pausedForSystemSettings
        case permissionRequired
        case unavailable

        var title: String {
            switch self {
            case .off:
                "Off"
            case .active:
                "Active"
            case .pausedForSystemSettings:
                "Paused in System Settings"
            case .permissionRequired:
                "Permission Required"
            case .unavailable:
                "Unavailable"
            }
        }
    }

    private enum DefaultsKey {
        static let isEnabled = "inputModeSwitching.isEnabled"
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
            reconcile()
            refreshDiagnostics()
        }
    }
    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var isInputMonitoringGranted = false
    @Published private(set) var isEventPostingGranted = false
    @Published private(set) var runtimeStatus: RuntimeStatus = .off
    @Published private(set) var monitorStatus: CommandInputModeMonitorStatus = .stopped
    @Published private(set) var codeSigningStatus: CommandInputModeCodeSigningStatus
    @Published private(set) var lastCommandEventAt: Date?
    @Published private(set) var lastAction: CommandInputModeAction?
    @Published private(set) var lastActionAt: Date?
    @Published private(set) var lastSwitchReport: CommandInputModeSwitchReport?
    @Published private(set) var currentInputSourceID: String?
    @Published private(set) var currentInputSourceName: String?

    private let defaults: UserDefaults
    private let monitor: any CommandInputModeMonitoring
    private let permissionProvider: any CommandInputModePermissionProviding
    private let codeSigningStatusProvider: any CommandInputModeCodeSigningStatusProviding
    private let backgroundActivityManager:
        any CommandInputModeBackgroundActivityManaging
    private let inputSourceStatusProvider:
        any CommandInputSourceStatusProviding
    private let workspaceNotificationCenter: NotificationCenter?
    private let monitoringHealthInterval: Duration
    private var hasStarted = false
    private var monitoringHealthTask: Task<Void, Never>?
    private var workspaceRecoveryTokens: [any NSObjectProtocol] = []
    private var isRecoveringMonitor = false
    private var systemSettingsActivationPending = false

    private var shouldSuspendForSystemSettings: Bool {
        systemSettingsActivationPending || permissionProvider.isSystemSettingsActive
    }

    init(
        defaults: UserDefaults,
        monitor: any CommandInputModeMonitoring,
        permissionProvider: any CommandInputModePermissionProviding,
        codeSigningStatusProvider: any CommandInputModeCodeSigningStatusProviding =
            FixedCommandInputModeCodeSigningStatusProvider(status: .stable),
        backgroundActivityManager:
            any CommandInputModeBackgroundActivityManaging =
            NoOpCommandInputModeBackgroundActivityManager(),
        inputSourceStatusProvider:
            any CommandInputSourceStatusProviding =
            DisabledCommandInputSourceStatusProvider(),
        workspaceNotificationCenter: NotificationCenter? = nil,
        monitoringHealthInterval: Duration = .seconds(5)
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.permissionProvider = permissionProvider
        self.codeSigningStatusProvider = codeSigningStatusProvider
        self.backgroundActivityManager = backgroundActivityManager
        self.inputSourceStatusProvider = inputSourceStatusProvider
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.monitoringHealthInterval = monitoringHealthInterval
        self.codeSigningStatus = codeSigningStatusProvider.status
        self.isEnabled = defaults.bool(forKey: DefaultsKey.isEnabled)
        self.monitor.diagnosticsDidChange = { [weak self] in
            self?.refreshDiagnostics()
        }
        self.inputSourceStatusProvider.currentSourceDidChange = { [weak self] in
            self?.refreshInputSourceStatus()
        }
    }

    static func live(defaults: UserDefaults) -> CommandInputModeController {
        CommandInputModeController(
            defaults: defaults,
            monitor: CommandInputModeMonitor(),
            permissionProvider: SystemCommandInputModePermissionProvider(),
            codeSigningStatusProvider: SystemCommandInputModeCodeSigningStatusProvider(),
            backgroundActivityManager:
                SystemCommandInputModeBackgroundActivityManager(),
            inputSourceStatusProvider: SystemCommandInputSourceStatusProvider(),
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter
        )
    }

    static func disabled(defaults: UserDefaults) -> CommandInputModeController {
        CommandInputModeController(
            defaults: defaults,
            monitor: DisabledCommandInputModeMonitor(),
            permissionProvider: DisabledCommandInputModePermissionProvider(),
            codeSigningStatusProvider: FixedCommandInputModeCodeSigningStatusProvider(
                status: .stable
            ),
            backgroundActivityManager:
                NoOpCommandInputModeBackgroundActivityManager()
        )
    }

    func start() {
        guard !hasStarted else {
            refreshAuthorization()
            return
        }
        hasStarted = true
        inputSourceStatusProvider.start()
        startWorkspaceRecoveryObservers()
        refreshAuthorization()
    }

    func stop() {
        monitor.stop()
        stopMonitoringHealthChecks()
        stopWorkspaceRecoveryObservers()
        inputSourceStatusProvider.stop()
        backgroundActivityManager.end()
        hasStarted = false
        runtimeStatus = .off
        refreshDiagnostics()
    }

    func refreshAuthorization() {
        codeSigningStatus = codeSigningStatusProvider.status
        inputSourceStatusProvider.refresh()
        reconcile()
        refreshDiagnostics()
    }

    func requestInputMonitoringAccess() {
        permissionProvider.requestInputMonitoringAccess()
        refreshAuthorization()
    }

    func requestAccessibilityAccess() {
        permissionProvider.requestAccessibilityAccess()
        refreshAuthorization()
    }

    func openAccessibilitySettings() {
        permissionProvider.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        permissionProvider.openInputMonitoringSettings()
    }

    func revealCurrentBuild() {
        permissionProvider.revealCurrentBuild()
    }

    func testSwitch(_ action: CommandInputModeAction) {
        updateAuthorizationSnapshot()
        guard isEnabled, hasRequiredEventAccess,
              !shouldSuspendForSystemSettings else { return }
        monitor.switchForTesting(action)
        refreshDiagnostics()
    }

    func recoverMonitoringIfNeeded(recreate: Bool = false) async {
        guard hasStarted, isEnabled else { return }
        updateAuthorizationSnapshot()
        guard hasRequiredEventAccess, !shouldSuspendForSystemSettings else {
            reconcile()
            refreshDiagnostics()
            return
        }
        backgroundActivityManager.begin()
        guard !isRecoveringMonitor else { return }
        guard recreate || !monitor.isRunning else {
            runtimeStatus = .active
            refreshDiagnostics()
            return
        }
        isRecoveringMonitor = true
        let recovered = await monitor.recover(recreate: recreate)
        isRecoveringMonitor = false
        updateAuthorizationSnapshot()
        guard hasStarted, isEnabled, hasRequiredEventAccess,
              !shouldSuspendForSystemSettings else {
            monitor.stop()
            reconcile()
            refreshDiagnostics()
            return
        }
        runtimeStatus = recovered ? .active : .unavailable
        refreshDiagnostics()
    }

    private func reconcile() {
        updateAuthorizationSnapshot()
        guard hasStarted else {
            stopMonitoringHealthChecks()
            backgroundActivityManager.end()
            runtimeStatus = isEnabled ? .permissionRequired : .off
            return
        }
        guard isEnabled else {
            monitor.stop()
            stopMonitoringHealthChecks()
            backgroundActivityManager.end()
            runtimeStatus = .off
            return
        }
        // Keep checking while enabled so a re-grant can recover in the background.
        startMonitoringHealthChecks()
        // macOS can stall system input when an active filtering tap loses access.
        // Remove the tap before the user can revoke access in System Settings.
        if shouldSuspendForSystemSettings {
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .pausedForSystemSettings
            return
        }
        // The active event tap and the Eisu/Kana key pair are both governed by
        // Accessibility. Unlike direct TIS selection, the posted key updates
        // the focused application's own text input context.
        guard hasRequiredEventAccess else {
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .permissionRequired
            return
        }
        backgroundActivityManager.begin()
        guard !isRecoveringMonitor else { return }
        if monitor.isRunning {
            runtimeStatus = .active
        } else {
            runtimeStatus = monitor.start() ? .active : .unavailable
        }
    }

    private func updateAuthorizationSnapshot() {
        let authorization = permissionProvider.authorizationSnapshot
        isAccessibilityGranted = authorization.accessibilityGranted
        isInputMonitoringGranted = authorization.listenEventGranted
        isEventPostingGranted = authorization.postEventGranted
    }

    private func startMonitoringHealthChecks() {
        guard monitoringHealthTask == nil else { return }
        let interval = monitoringHealthInterval
        monitoringHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await self?.recoverMonitoringIfNeeded()
            }
        }
    }

    private var hasRequiredEventAccess: Bool {
        isAccessibilityGranted && isEventPostingGranted
    }

    private func stopMonitoringHealthChecks() {
        monitoringHealthTask?.cancel()
        monitoringHealthTask = nil
    }

    private func refreshDiagnostics() {
        monitorStatus = monitor.status
        lastCommandEventAt = monitor.lastCommandEventAt
        lastAction = monitor.lastAction
        lastActionAt = monitor.lastActionAt
        lastSwitchReport = monitor.lastSwitchReport
        inputSourceStatusProvider.refresh()
        refreshInputSourceStatus()
    }

    private func refreshInputSourceStatus() {
        currentInputSourceID = inputSourceStatusProvider.currentSourceID
        currentInputSourceName = currentInputSourceID.flatMap {
            NSTextInputContext.localizedName(forInputSource: $0)
        }
    }

    private func startWorkspaceRecoveryObservers() {
        guard workspaceRecoveryTokens.isEmpty,
              let workspaceNotificationCenter else { return }
        let names = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        workspaceRecoveryTokens = names.map { name in
            workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.inputSourceStatusProvider.refresh()
                    await self?.recoverMonitoringIfNeeded(recreate: true)
                }
            }
        }
        workspaceRecoveryTokens.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let isSystemSettings = application?.bundleIdentifier == "com.apple.systempreferences"
            // The observer runs on the main queue: stop synchronously, before
            // another user action can remove the Accessibility entry.
            MainActor.assumeIsolated {
                self?.systemSettingsActivationPending = isSystemSettings
                self?.refreshAuthorization()
            }
            Task { @MainActor [weak self] in
                await self?.recoverMonitoringIfNeeded()
            }
        })
    }

    private func stopWorkspaceRecoveryObservers() {
        systemSettingsActivationPending = false
        guard let workspaceNotificationCenter else { return }
        workspaceRecoveryTokens.forEach {
            workspaceNotificationCenter.removeObserver($0)
        }
        workspaceRecoveryTokens.removeAll(keepingCapacity: true)
    }
}

@MainActor
private final class DisabledCommandInputModeMonitor: CommandInputModeMonitoring {
    var isRunning = false
    var status: CommandInputModeMonitorStatus = .stopped
    var lastCommandEventAt: Date?
    var lastAction: CommandInputModeAction?
    var lastActionAt: Date?
    var lastSwitchReport: CommandInputModeSwitchReport?
    var diagnosticsDidChange: (() -> Void)?

    func start() -> Bool {
        false
    }

    func stop() {
        isRunning = false
        status = .stopped
    }

    func recover(recreate: Bool) async -> Bool { false }
    func switchForTesting(_ action: CommandInputModeAction) {}
}

@MainActor
private final class DisabledCommandInputSourceStatusProvider:
    CommandInputSourceStatusProviding {
    var currentSourceID: String?
    var currentSourceDidChange: (() -> Void)?

    func start() {}
    func stop() {}
    func refresh() {}
}

@MainActor
private final class DisabledCommandInputModePermissionProvider: CommandInputModePermissionProviding {
    var isAccessibilityGranted = false
    var authorizationSnapshot = CommandInputModeAuthorizationSnapshot(
        accessibilityGranted: false,
        listenEventGranted: false,
        postEventGranted: false
    )

    func requestAccessibilityAccess() {}
    func openAccessibilitySettings() {}
    func requestInputMonitoringAccess() {}
    func openInputMonitoringSettings() {}
    func revealCurrentBuild() {}
}

@MainActor
final class FixedCommandInputModeCodeSigningStatusProvider:
    CommandInputModeCodeSigningStatusProviding {
    let status: CommandInputModeCodeSigningStatus

    init(status: CommandInputModeCodeSigningStatus) {
        self.status = status
    }
}
