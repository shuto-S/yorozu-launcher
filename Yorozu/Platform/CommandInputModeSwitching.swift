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

protocol CommandInputSourceSystem: Sendable {
    func currentSourceID() -> String?
    func candidates() -> [CommandInputSourceCandidate]
    func preferredSourceID(for action: CommandInputModeAction) -> String?
    func selectSource(id: String) -> Bool
}

protocol CommandInputSourceSwitching: Sendable {
    func switchInputMode(
        _ action: CommandInputModeAction
    ) async -> CommandInputModeSwitchReport
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

    private static func isJapaneseLanguage(_ language: String) -> Bool {
        let normalized = language.lowercased()
        return normalized == "ja"
            || normalized.hasPrefix("ja-")
            || normalized.hasPrefix("ja_")
    }
}

actor SystemCommandInputSourceSwitcher: CommandInputSourceSwitching {
    private let system: any CommandInputSourceSystem

    init(system: any CommandInputSourceSystem = SystemCommandInputSourceSystem()) {
        self.system = system
    }

    func switchInputMode(
        _ action: CommandInputModeAction
    ) async -> CommandInputModeSwitchReport {
        let sourceIDBefore = system.currentSourceID()
        let targetSourceID = CommandInputSourceResolver.sourceID(
            for: action,
            candidates: system.candidates(),
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
        if sourceIDBefore == targetSourceID {
            return report(
                action: action,
                result: .alreadySelected(sourceID: targetSourceID),
                before: sourceIDBefore,
                after: sourceIDBefore
            )
        }
        guard system.selectSource(id: targetSourceID) else {
            return report(
                action: action,
                result: .selectionFailed,
                before: sourceIDBefore,
                after: system.currentSourceID()
            )
        }

        for attempt in 0 ..< 3 {
            guard !Task.isCancelled else {
                return report(
                    action: action,
                    result: .cancelled,
                    before: sourceIDBefore,
                    after: system.currentSourceID()
                )
            }
            let sourceIDAfter = system.currentSourceID()
            if sourceIDAfter == targetSourceID {
                return report(
                    action: action,
                    result: .switched(sourceID: targetSourceID),
                    before: sourceIDBefore,
                    after: sourceIDAfter
                )
            }
            if attempt < 2 {
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

final class SystemCommandInputSourceSystem:
    CommandInputSourceSystem, @unchecked Sendable {
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

    func selectSource(id: String) -> Bool {
        let properties = [
            kTISPropertyInputSourceID as String: id,
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(properties, false)?
            .takeRetainedValue() as? [TISInputSource],
            let source = sources.first(where: { sourceID(of: $0) == id }) else {
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    private func sourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private func languages(of source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceLanguages
        ) else {
            return []
        }
        return Unmanaged<CFArray>.fromOpaque(pointer)
            .takeUnretainedValue() as? [String] ?? []
    }

    private func booleanProperty(
        _ key: CFString,
        of source: TISInputSource
    ) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return false
        }
        return CFBooleanGetValue(
            Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()
        )
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
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer)
            .takeUnretainedValue() as String
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
    func switchForTesting(_ action: CommandInputModeAction)
}

@MainActor
protocol CommandInputModePermissionProviding: AnyObject {
    var isAccessibilityGranted: Bool { get }
    var authorizationSnapshot: CommandInputModeAuthorizationSnapshot { get }

    func requestAccessibilityAccess()
    func openAccessibilitySettings()
    func requestInputMonitoringAccess()
    func openInputMonitoringSettings()
    func revealCurrentBuild()
}

extension CommandInputModePermissionProviding {
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

private struct CommandInputModeMonitorDiagnostics: Sendable {
    let sequence: UInt64
    let status: CommandInputModeMonitorStatus
    let lastCommandEventAt: Date?
    let lastAction: CommandInputModeAction?
    let lastActionAt: Date?
    let lastSwitchReport: CommandInputModeSwitchReport?
}

private final class CommandInputModeEventTapWorker: @unchecked Sendable {
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
        defer { lock.unlock() }
        return running
    }

    var diagnostics: CommandInputModeMonitorDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return makeDiagnosticsLocked()
    }

    func start() -> Bool {
        lock.lock()
        if running {
            lock.unlock()
            return true
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
        lock.unlock()

        switchTask?.cancel()
        diagnosticsHandler(diagnostics)
        if let runLoop {
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
            options: .listenOnly,
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
        CGEvent.tapEnable(tap: eventTap, enable: true)
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

    private func handle(type: CGEventType, event: CGEvent) {
        lock.lock()
        let shouldIgnore = stopRequested
        let currentEventTap = eventTap
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
            publishDiagnostics {
                status = .temporarilyDisabled
            }
            if let currentEventTap {
                CGEvent.tapEnable(tap: currentEventTap, enable: true)
                let recovered = CGEvent.tapIsEnabled(tap: currentEventTap)
                lock.lock()
                running = recovered
                lock.unlock()
                publishDiagnostics {
                    status = recovered ? .running : .temporarilyDisabled
                }
            }
            stateMachine.synchronizePressedCommands(
                Self.currentlyPressedCommandSides()
            )
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

        // TIS selection is intentionally deferred until the event-tap callback
        // returns. Performing input-source work inside the callback can delay
        // the tap and cause macOS to disable it.
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
        worker.stop()
        apply(worker.diagnostics)
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
        case permissionRequired
        case unavailable

        var title: String {
            switch self {
            case .off:
                "Off"
            case .active:
                "Active"
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

    private let defaults: UserDefaults
    private let monitor: any CommandInputModeMonitoring
    private let permissionProvider: any CommandInputModePermissionProviding
    private let codeSigningStatusProvider: any CommandInputModeCodeSigningStatusProviding
    private let backgroundActivityManager:
        any CommandInputModeBackgroundActivityManaging
    private var hasStarted = false
    private var monitoringHealthTask: Task<Void, Never>?

    init(
        defaults: UserDefaults,
        monitor: any CommandInputModeMonitoring,
        permissionProvider: any CommandInputModePermissionProviding,
        codeSigningStatusProvider: any CommandInputModeCodeSigningStatusProviding =
            FixedCommandInputModeCodeSigningStatusProvider(status: .stable),
        backgroundActivityManager:
            any CommandInputModeBackgroundActivityManaging =
            NoOpCommandInputModeBackgroundActivityManager()
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.permissionProvider = permissionProvider
        self.codeSigningStatusProvider = codeSigningStatusProvider
        self.backgroundActivityManager = backgroundActivityManager
        self.codeSigningStatus = codeSigningStatusProvider.status
        self.isEnabled = defaults.bool(forKey: DefaultsKey.isEnabled)
        self.monitor.diagnosticsDidChange = { [weak self] in
            self?.refreshDiagnostics()
        }
    }

    static func live(defaults: UserDefaults) -> CommandInputModeController {
        CommandInputModeController(
            defaults: defaults,
            monitor: CommandInputModeMonitor(),
            permissionProvider: SystemCommandInputModePermissionProvider(),
            codeSigningStatusProvider: SystemCommandInputModeCodeSigningStatusProvider(),
            backgroundActivityManager:
                SystemCommandInputModeBackgroundActivityManager()
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
        refreshAuthorization()
    }

    func stop() {
        monitor.stop()
        stopMonitoringHealthChecks()
        backgroundActivityManager.end()
        hasStarted = false
        runtimeStatus = .off
        refreshDiagnostics()
    }

    func refreshAuthorization() {
        let authorization = permissionProvider.authorizationSnapshot
        isAccessibilityGranted = authorization.accessibilityGranted
        isInputMonitoringGranted = authorization.listenEventGranted
        isEventPostingGranted = authorization.postEventGranted
        codeSigningStatus = codeSigningStatusProvider.status
        reconcile()
        refreshDiagnostics()
    }

    func requestInputMonitoringAccess() {
        permissionProvider.requestInputMonitoringAccess()
        refreshAuthorization()
    }

    func openInputMonitoringSettings() {
        permissionProvider.openInputMonitoringSettings()
    }

    func revealCurrentBuild() {
        permissionProvider.revealCurrentBuild()
    }

    func testSwitch(_ action: CommandInputModeAction) {
        guard isEnabled, isInputMonitoringGranted else { return }
        monitor.switchForTesting(action)
        refreshDiagnostics()
    }

    func recoverMonitoringIfNeeded() {
        guard hasStarted, isEnabled, isInputMonitoringGranted else { return }
        guard !monitor.isRunning else {
            runtimeStatus = .active
            refreshDiagnostics()
            return
        }
        runtimeStatus = monitor.start() ? .active : .unavailable
        refreshDiagnostics()
    }

    private func reconcile() {
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
        // This listen-only event tap is governed by Input Monitoring. TIS
        // selects the source directly, so Accessibility and event-posting
        // access are diagnostics rather than runtime gates.
        guard isInputMonitoringGranted else {
            monitor.stop()
            stopMonitoringHealthChecks()
            backgroundActivityManager.end()
            runtimeStatus = .permissionRequired
            return
        }
        backgroundActivityManager.begin()
        if monitor.isRunning {
            runtimeStatus = .active
        } else {
            runtimeStatus = monitor.start() ? .active : .unavailable
        }
        startMonitoringHealthChecks()
    }

    private func startMonitoringHealthChecks() {
        guard monitoringHealthTask == nil else { return }
        monitoringHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                self?.recoverMonitoringIfNeeded()
            }
        }
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

    func switchForTesting(_ action: CommandInputModeAction) {}
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
