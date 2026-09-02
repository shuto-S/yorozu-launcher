import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

struct WindowControlModifierChord: OptionSet, Codable, Hashable, Sendable {
    private static let supportedMask: UInt64 = 0b1_1111
    let rawValue: UInt64

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let function = Self(rawValue: 1 << 4)

    static let supported: Self = [
        .control,
        .option,
        .shift,
        .command,
        .function,
    ]

    init(rawValue: UInt64) {
        self.rawValue = rawValue & Self.supportedMask
    }

    init(eventFlags: CGEventFlags) {
        var value: Self = []
        if eventFlags.contains(.maskControl) { value.insert(.control) }
        if eventFlags.contains(.maskAlternate) { value.insert(.option) }
        if eventFlags.contains(.maskShift) { value.insert(.shift) }
        if eventFlags.contains(.maskCommand) { value.insert(.command) }
        if eventFlags.contains(.maskSecondaryFn) { value.insert(.function) }
        self = value
    }

    var displayTitle: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        if contains(.function) { parts.append("fn") }
        return parts.isEmpty ? "Not Set" : parts.joined()
    }
}

enum WindowControlOperation: String, CaseIterable, Sendable {
    case move
    case resize

    var title: String {
        switch self {
        case .move:
            "Move Window"
        case .resize:
            "Resize Window"
        }
    }
}

struct WindowControlConfiguration: Equatable, Sendable {
    var moveChord: WindowControlModifierChord?
    var resizeChord: WindowControlModifierChord?

    var isValid: Bool {
        guard let moveChord, !moveChord.isEmpty,
              let resizeChord, !resizeChord.isEmpty else {
            return false
        }
        return moveChord != resizeChord
    }

    func operation(for eventFlags: CGEventFlags) -> WindowControlOperation? {
        guard isValid else { return nil }
        let pressed = WindowControlModifierChord(eventFlags: eventFlags)
        if pressed == moveChord { return .move }
        if pressed == resizeChord { return .resize }
        return nil
    }

    func chord(for operation: WindowControlOperation) -> WindowControlModifierChord? {
        switch operation {
        case .move:
            moveChord
        case .resize:
            resizeChord
        }
    }
}

struct WindowControlTarget: @unchecked Sendable {
    fileprivate let element: AnyObject
    let processIdentifier: pid_t
    let initialPosition: CGPoint
    let initialSize: CGSize

    init(
        element: AnyObject,
        processIdentifier: pid_t,
        initialPosition: CGPoint,
        initialSize: CGSize
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.initialPosition = initialPosition
        self.initialSize = initialSize
    }
}

enum WindowControlGeometry {
    static let minimumSize = CGSize(width: 160, height: 120)

    static func movedPosition(
        initialPosition: CGPoint,
        startPointer: CGPoint,
        currentPointer: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: initialPosition.x + currentPointer.x - startPointer.x,
            y: initialPosition.y + currentPointer.y - startPointer.y
        )
    }

    static func resizedSize(
        initialSize: CGSize,
        startPointer: CGPoint,
        currentPointer: CGPoint
    ) -> CGSize {
        CGSize(
            width: max(
                minimumSize.width,
                initialSize.width + currentPointer.x - startPointer.x
            ),
            height: max(
                minimumSize.height,
                initialSize.height + currentPointer.y - startPointer.y
            )
        )
    }
}

enum WindowControlGestureUpdate {
    case move(WindowControlTarget, CGPoint)
    case resize(WindowControlTarget, CGSize)
}

struct WindowControlGestureSession {
    private struct ActiveGesture {
        let operation: WindowControlOperation
        let target: WindowControlTarget
        let startPointer: CGPoint
    }

    private var activeGesture: ActiveGesture?
    private(set) var isTracking = false

    mutating func begin(
        operation: WindowControlOperation,
        target: WindowControlTarget,
        pointer: CGPoint
    ) {
        activeGesture = ActiveGesture(
            operation: operation,
            target: target,
            startPointer: pointer
        )
        isTracking = true
    }

    mutating func update(
        operation: WindowControlOperation,
        pointer: CGPoint
    ) -> WindowControlGestureUpdate? {
        guard let gesture = activeGesture,
              gesture.operation == operation else { return nil }

        switch gesture.operation {
        case .move:
            return .move(
                gesture.target,
                WindowControlGeometry.movedPosition(
                    initialPosition: gesture.target.initialPosition,
                    startPointer: gesture.startPointer,
                    currentPointer: pointer
                )
            )
        case .resize:
            return .resize(
                gesture.target,
                WindowControlGeometry.resizedSize(
                    initialSize: gesture.target.initialSize,
                    startPointer: gesture.startPointer,
                    currentPointer: pointer
                )
            )
        }
    }

    mutating func reset() {
        activeGesture = nil
        isTracking = false
    }
}

enum WindowControlActivity: Equatable, Sendable {
    case listening
    case tracking(WindowControlOperation)
    case targetUnavailable
    case updateRejected(WindowControlOperation)
    case monitorRecovered

    var message: String {
        switch self {
        case .listening:
            "Hold a configured key combination and move the pointer."
        case .tracking(.move):
            "Moving the window under the pointer."
        case .tracking(.resize):
            "Resizing the window under the pointer."
        case .targetUnavailable:
            "No movable or resizable window was found under the pointer."
        case .updateRejected:
            "The target application did not allow Yorozu to update this window."
        case .monitorRecovered:
            "Pointer monitoring resumed after macOS paused it."
        }
    }
}

protocol WindowAccessing: AnyObject, Sendable {
    func target(
        at point: CGPoint,
        operation: WindowControlOperation
    ) -> WindowControlTarget?
    func raiseAndActivate(_ target: WindowControlTarget)
    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool
    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool
}

final class SystemWindowAccessor: WindowAccessing, @unchecked Sendable {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    func target(
        at point: CGPoint,
        operation: WindowControlOperation
    ) -> WindowControlTarget? {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success, let hitElement,
              let window = resolveWindow(from: hitElement) else {
            return nil
        }

        // Some Electron and IDE windows need longer than the event-tap callback
        // budget to answer AX requests. These calls run on the dedicated AX queue.
        AXUIElementSetMessagingTimeout(window, 0.5)

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              pid != ownProcessIdentifier,
              pid > 0,
              boolAttribute(window, kAXMinimizedAttribute as CFString) != true,
              boolAttribute(window, "AXFullScreen" as CFString) != true,
              let position = pointAttribute(
                window,
                kAXPositionAttribute as CFString
              ),
              let size = sizeAttribute(window, kAXSizeAttribute as CFString)
        else {
            return nil
        }

        let writableAttribute = switch operation {
        case .move:
            kAXPositionAttribute as CFString
        case .resize:
            kAXSizeAttribute as CFString
        }
        guard isSettable(window, writableAttribute) else {
            return nil
        }

        return WindowControlTarget(
            element: window,
            processIdentifier: pid,
            initialPosition: position,
            initialSize: size
        )
    }

    func raiseAndActivate(_ target: WindowControlTarget) {
        guard let window = axElement(from: target) else { return }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let pid = target.processIdentifier
        DispatchQueue.main.async {
            _ = NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool {
        guard let window = axElement(from: target) else { return false }
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool {
        guard let window = axElement(from: target) else { return false }
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            value
        ) == .success
    }

    private func resolveWindow(from element: AXUIElement) -> AXUIElement? {
        var candidate = element
        for _ in 0..<8 {
            if stringAttribute(candidate, kAXRoleAttribute as CFString)
                == kAXWindowRole as String {
                return candidate
            }
            if let window = elementAttribute(
                candidate,
                kAXWindowAttribute as CFString
            ) ?? elementAttribute(
                candidate,
                kAXTopLevelUIElementAttribute as CFString
            ) {
                return window
            }
            guard let parent = elementAttribute(
                candidate,
                kAXParentAttribute as CFString
            ), !CFEqual(parent, candidate) else { return nil }
            candidate = parent
        }
        return nil
    }

    private func axElement(from target: WindowControlTarget) -> AXUIElement? {
        guard CFGetTypeID(target.element) == AXUIElementGetTypeID() else {
            return nil
        }
        return (target.element as! AXUIElement)
    }

    private func elementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func stringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func pointAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func isSettable(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute,
            &settable
        ) == .success && settable.boolValue
    }
}

struct WindowControlPointerSample: Equatable, Sendable {
    let operation: WindowControlOperation
    let location: CGPoint
}

final class WindowControlPointerCoordinator: @unchecked Sendable {
    private let windowAccessor: any WindowAccessing
    private var gestureSession = WindowControlGestureSession()

    init(windowAccessor: any WindowAccessing) {
        self.windowAccessor = windowAccessor
    }

    func process(_ sample: WindowControlPointerSample) -> WindowControlActivity {
        if !gestureSession.isTracking {
            guard let target = windowAccessor.target(
                at: sample.location,
                operation: sample.operation
            ) else {
                return .targetUnavailable
            }
            gestureSession.begin(
                operation: sample.operation,
                target: target,
                pointer: sample.location
            )
            windowAccessor.raiseAndActivate(target)
            return .tracking(sample.operation)
        }

        guard let update = gestureSession.update(
            operation: sample.operation,
            pointer: sample.location
        ) else {
            gestureSession.reset()
            return process(sample)
        }

        let succeeded = switch update {
        case let .move(target, position):
            windowAccessor.move(target, to: position)
        case let .resize(target, size):
            windowAccessor.resize(target, to: size)
        }
        guard succeeded else {
            gestureSession.reset()
            return .updateRejected(sample.operation)
        }
        return .tracking(sample.operation)
    }

    func reset() {
        gestureSession.reset()
    }
}

private final class WindowControlPointerProcessor: @unchecked Sendable {
    private struct PendingSample {
        let generation: UInt64
        let value: WindowControlPointerSample
    }

    private static let updateInterval = DispatchTimeInterval.milliseconds(8)
    private static let retryInterval = DispatchTimeInterval.milliseconds(50)

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.yorozu.app.window-control.ax",
        qos: .userInteractive
    )
    private let coordinator: WindowControlPointerCoordinator
    private let activityHandler: @MainActor @Sendable (WindowControlActivity) -> Void
    private var pendingSample: PendingSample?
    private var generation: UInt64 = 0
    private var isScheduled = false
    private var isGestureActive = false
    private var lastActivity: WindowControlActivity?

    init(
        windowAccessor: any WindowAccessing,
        activityHandler: @escaping @MainActor @Sendable (WindowControlActivity) -> Void
    ) {
        coordinator = WindowControlPointerCoordinator(windowAccessor: windowAccessor)
        self.activityHandler = activityHandler
    }

    func submit(_ sample: WindowControlPointerSample) {
        lock.lock()
        isGestureActive = true
        pendingSample = PendingSample(generation: generation, value: sample)
        let shouldSchedule = !isScheduled
        if shouldSchedule { isScheduled = true }
        lock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in
                self?.processPendingSample()
            }
        }
    }

    func report(_ activity: WindowControlActivity) {
        queue.async { [weak self] in
            self?.publish(activity)
        }
    }

    func reset() {
        lock.lock()
        guard isGestureActive || pendingSample != nil else {
            lock.unlock()
            return
        }
        isGestureActive = false
        generation &+= 1
        pendingSample = nil
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            coordinator.reset()
            publish(.listening)
        }
    }

    private func processPendingSample() {
        lock.lock()
        guard let sample = pendingSample else {
            isScheduled = false
            lock.unlock()
            return
        }
        pendingSample = nil
        let isCurrent = sample.generation == generation
        lock.unlock()

        let delay: DispatchTimeInterval
        if isCurrent {
            let activity = coordinator.process(sample.value)
            publish(activity)
            delay = switch activity {
            case .targetUnavailable, .updateRejected:
                Self.retryInterval
            case .listening, .tracking, .monitorRecovered:
                Self.updateInterval
            }
        } else {
            delay = Self.updateInterval
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.processPendingSample()
        }
    }

    private func publish(_ activity: WindowControlActivity) {
        guard lastActivity != activity else { return }
        lastActivity = activity
        Task { @MainActor [activityHandler] in
            activityHandler(activity)
        }
    }
}

@MainActor
protocol WindowControlMonitoring: AnyObject {
    var isRunning: Bool { get }

    func setActivityHandler(
        _ handler: (@MainActor @Sendable (WindowControlActivity) -> Void)?
    )
    func start(configuration: WindowControlConfiguration) -> Bool
    func update(configuration: WindowControlConfiguration)
    func stop()
}

private final class WindowControlEventTapWorker: @unchecked Sendable {
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

    private let lock = NSLock()
    private let pointerProcessor: WindowControlPointerProcessor
    private var configuration: WindowControlConfiguration
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var thread: Thread?
    private var running = false
    private var stopRequested = false
    private var isPointerTracking = false

    init(
        configuration: WindowControlConfiguration,
        windowAccessor: any WindowAccessing,
        activityHandler: @escaping @MainActor @Sendable (WindowControlActivity) -> Void
    ) {
        self.configuration = configuration
        pointerProcessor = WindowControlPointerProcessor(
            windowAccessor: windowAccessor,
            activityHandler: activityHandler
        )
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start() -> Bool {
        if isRunning { return true }

        let semaphore = DispatchSemaphore(value: 0)
        let result = StartResult()
        let thread = Thread { [self] in
            runEventTap(result: result, semaphore: semaphore)
        }
        thread.name = "com.yorozu.app.window-control"
        thread.qualityOfService = .userInteractive

        lock.lock()
        stopRequested = false
        self.thread = thread
        lock.unlock()
        thread.start()

        guard semaphore.wait(timeout: .now() + 1) == .success else {
            stop()
            return false
        }
        return result.read() == true
    }

    func update(configuration: WindowControlConfiguration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopRequested = true
        let runLoop = runLoop
        lock.unlock()
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runEventTap(
        result: StartResult,
        semaphore: DispatchSemaphore
    ) {
        let eventTypes: [CGEventType] = [
            .flagsChanged,
            .mouseMoved,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let worker = Unmanaged<WindowControlEventTapWorker>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return worker.handle(type: type, event: event)
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ), let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            result.complete(false)
            semaphore.signal()
            return
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            CFMachPortInvalidate(eventTap)
            result.complete(false)
            semaphore.signal()
            return
        }
        runLoop = currentRunLoop
        self.eventTap = eventTap
        running = true
        lock.unlock()

        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        lock.lock()
        let shouldRun = !stopRequested
        lock.unlock()
        result.complete(shouldRun && CGEvent.tapIsEnabled(tap: eventTap))
        semaphore.signal()
        if shouldRun {
            pointerProcessor.report(.listening)
            CFRunLoopRun()
        }

        pointerProcessor.reset()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        CFMachPortInvalidate(eventTap)

        lock.lock()
        running = false
        runLoop = nil
        self.eventTap = nil
        thread = nil
        lock.unlock()
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            isPointerTracking = false
            pointerProcessor.reset()
            pointerProcessor.report(.monitorRecovered)
            lock.lock()
            let eventTap = eventTap
            lock.unlock()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        let configuration = currentConfiguration()
        switch type {
        case .mouseMoved:
            guard let operation = configuration.operation(for: event.flags) else {
                resetPointerTrackingIfNeeded()
                return false
            }
            isPointerTracking = true
            pointerProcessor.submit(
                WindowControlPointerSample(
                    operation: operation,
                    location: event.location
                )
            )
            return false

        case .flagsChanged:
            if configuration.operation(for: event.flags) == nil {
                resetPointerTrackingIfNeeded()
            }
            return false

        default:
            return false
        }
    }

    private func resetPointerTrackingIfNeeded() {
        guard isPointerTracking else { return }
        isPointerTracking = false
        pointerProcessor.reset()
    }

    private func currentConfiguration() -> WindowControlConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }
}

@MainActor
final class WindowControlMonitor: WindowControlMonitoring {
    private let windowAccessor: any WindowAccessing
    private var worker: WindowControlEventTapWorker?
    private var activityHandler:
        (@MainActor @Sendable (WindowControlActivity) -> Void)?

    init(windowAccessor: any WindowAccessing = SystemWindowAccessor()) {
        self.windowAccessor = windowAccessor
    }

    var isRunning: Bool {
        worker?.isRunning == true
    }

    func setActivityHandler(
        _ handler: (@MainActor @Sendable (WindowControlActivity) -> Void)?
    ) {
        activityHandler = handler
    }

    func start(configuration: WindowControlConfiguration) -> Bool {
        if let worker, worker.isRunning {
            worker.update(configuration: configuration)
            return true
        }
        let activityHandler = activityHandler ?? { _ in }
        let worker = WindowControlEventTapWorker(
            configuration: configuration,
            windowAccessor: windowAccessor,
            activityHandler: activityHandler
        )
        self.worker = worker
        let started = worker.start()
        if !started {
            self.worker = nil
        }
        return started
    }

    func update(configuration: WindowControlConfiguration) {
        worker?.update(configuration: configuration)
    }

    func stop() {
        worker?.stop()
        worker = nil
    }
}

@MainActor
protocol WindowControlBackgroundActivityManaging: AnyObject {
    var isActive: Bool { get }
    func begin()
    func end()
}

@MainActor
final class SystemWindowControlBackgroundActivityManager:
    WindowControlBackgroundActivityManaging {
    static let activityOptions: ProcessInfo.ActivityOptions = [
        .userInitiatedAllowingIdleSystemSleep,
        .automaticTerminationDisabled,
    ]

    private var activity: (any NSObjectProtocol)?

    var isActive: Bool { activity != nil }

    func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: Self.activityOptions,
            reason: "Listening for user-enabled window control gestures"
        )
    }

    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

@MainActor
final class NoOpWindowControlBackgroundActivityManager:
    WindowControlBackgroundActivityManaging {
    private(set) var isActive = false

    func begin() { isActive = true }
    func end() { isActive = false }
}

@MainActor
final class WindowControlController: ObservableObject {
    enum RuntimeStatus: Equatable {
        case off
        case needsConfiguration
        case permissionRequired
        case active
        case unavailable

        var title: String {
            switch self {
            case .off:
                "Off"
            case .needsConfiguration:
                "Set Both Key Combinations"
            case .permissionRequired:
                "Permission Required"
            case .active:
                "Active"
            case .unavailable:
                "Could Not Start"
            }
        }
    }

    private enum DefaultsKey {
        static let isEnabled = "windowControl.isEnabled"
        static let moveChord = "windowControl.moveChord"
        static let resizeChord = "windowControl.resizeChord"
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
            reconcile()
        }
    }
    @Published private(set) var moveChord: WindowControlModifierChord?
    @Published private(set) var resizeChord: WindowControlModifierChord?
    @Published private(set) var validationMessage: String?
    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var runtimeStatus: RuntimeStatus = .off
    @Published private(set) var codeSigningStatus: CommandInputModeCodeSigningStatus
    @Published private(set) var lastActivity: WindowControlActivity?

    private let defaults: UserDefaults
    private let monitor: any WindowControlMonitoring
    private let permissionProvider: any CommandInputModePermissionProviding
    private let codeSigningStatusProvider: any CommandInputModeCodeSigningStatusProviding
    private let backgroundActivityManager: any WindowControlBackgroundActivityManaging
    private var hasStarted = false

    init(
        defaults: UserDefaults,
        monitor: any WindowControlMonitoring,
        permissionProvider: any CommandInputModePermissionProviding,
        codeSigningStatusProvider: any CommandInputModeCodeSigningStatusProviding =
            FixedCommandInputModeCodeSigningStatusProvider(status: .stable),
        backgroundActivityManager: any WindowControlBackgroundActivityManaging =
            NoOpWindowControlBackgroundActivityManager()
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.permissionProvider = permissionProvider
        self.codeSigningStatusProvider = codeSigningStatusProvider
        self.backgroundActivityManager = backgroundActivityManager
        isEnabled = defaults.bool(forKey: DefaultsKey.isEnabled)
        moveChord = Self.loadChord(defaults, key: DefaultsKey.moveChord)
        resizeChord = Self.loadChord(defaults, key: DefaultsKey.resizeChord)
        codeSigningStatus = codeSigningStatusProvider.status
        monitor.setActivityHandler { [weak self] activity in
            self?.lastActivity = activity
        }
    }

    static func live(defaults: UserDefaults) -> WindowControlController {
        WindowControlController(
            defaults: defaults,
            monitor: WindowControlMonitor(),
            permissionProvider: SystemCommandInputModePermissionProvider(),
            codeSigningStatusProvider: SystemCommandInputModeCodeSigningStatusProvider(),
            backgroundActivityManager: SystemWindowControlBackgroundActivityManager()
        )
    }

    static func disabled(defaults: UserDefaults) -> WindowControlController {
        WindowControlController(
            defaults: defaults,
            monitor: DisabledWindowControlMonitor(),
            permissionProvider: DisabledWindowControlPermissionProvider(),
            backgroundActivityManager: NoOpWindowControlBackgroundActivityManager()
        )
    }

    var configuration: WindowControlConfiguration {
        WindowControlConfiguration(
            moveChord: moveChord,
            resizeChord: resizeChord
        )
    }

    var isConfigurationValid: Bool { configuration.isValid }

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
        backgroundActivityManager.end()
        hasStarted = false
        runtimeStatus = .off
        lastActivity = nil
    }

    @discardableResult
    func setChord(
        _ chord: WindowControlModifierChord?,
        for operation: WindowControlOperation
    ) -> Bool {
        let normalized = chord.flatMap { $0.isEmpty ? nil : $0 }
        let other = operation == .move ? resizeChord : moveChord
        if let normalized, normalized == other {
            validationMessage = "This key combination is already used by \(operation == .move ? "Resize Window" : "Move Window")."
            return false
        }

        validationMessage = nil
        switch operation {
        case .move:
            moveChord = normalized
            saveChord(normalized, key: DefaultsKey.moveChord)
        case .resize:
            resizeChord = normalized
            saveChord(normalized, key: DefaultsKey.resizeChord)
        }
        reconcile()
        return true
    }

    func refreshAuthorization() {
        isAccessibilityGranted = permissionProvider.isAccessibilityGranted
        codeSigningStatus = codeSigningStatusProvider.status
        reconcile()
    }

    func requestAccessibilityAccess() {
        permissionProvider.requestAccessibilityAccess()
        refreshAuthorization()
    }

    func openAccessibilitySettings() {
        permissionProvider.openAccessibilitySettings()
    }

    func revealCurrentBuild() {
        permissionProvider.revealCurrentBuild()
    }

    private func reconcile() {
        guard hasStarted else {
            runtimeStatus = isEnabled ? preflightStatus : .off
            return
        }
        guard isEnabled else {
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .off
            lastActivity = nil
            return
        }
        guard configuration.isValid else {
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .needsConfiguration
            lastActivity = nil
            return
        }
        guard isAccessibilityGranted else {
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .permissionRequired
            lastActivity = nil
            return
        }

        backgroundActivityManager.begin()
        if monitor.isRunning {
            monitor.update(configuration: configuration)
            runtimeStatus = .active
        } else {
            runtimeStatus = monitor.start(configuration: configuration)
                ? .active
                : .unavailable
            if runtimeStatus == .unavailable {
                backgroundActivityManager.end()
            }
        }
    }

    private var preflightStatus: RuntimeStatus {
        if !configuration.isValid { return .needsConfiguration }
        if !isAccessibilityGranted { return .permissionRequired }
        return .off
    }

    private func saveChord(
        _ chord: WindowControlModifierChord?,
        key: String
    ) {
        if let chord {
            defaults.set(NSNumber(value: chord.rawValue), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func loadChord(
        _ defaults: UserDefaults,
        key: String
    ) -> WindowControlModifierChord? {
        guard let value = defaults.object(forKey: key) as? NSNumber else {
            return nil
        }
        let chord = WindowControlModifierChord(rawValue: value.uint64Value)
        return chord.isEmpty ? nil : chord
    }
}

@MainActor
private final class DisabledWindowControlMonitor: WindowControlMonitoring {
    var isRunning = false
    func setActivityHandler(
        _ handler: (@MainActor @Sendable (WindowControlActivity) -> Void)?
    ) {}
    func start(configuration: WindowControlConfiguration) -> Bool { false }
    func update(configuration: WindowControlConfiguration) {}
    func stop() { isRunning = false }
}

@MainActor
private final class DisabledWindowControlPermissionProvider:
    CommandInputModePermissionProviding {
    var isAccessibilityGranted = false
    func requestAccessibilityAccess() {}
    func openAccessibilitySettings() {}
    func revealCurrentBuild() {}
}
