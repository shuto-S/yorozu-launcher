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
    let supportsResizing: Bool

    init(
        element: AnyObject,
        processIdentifier: pid_t,
        initialPosition: CGPoint,
        initialSize: CGSize,
        supportsResizing: Bool = true
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.initialPosition = initialPosition
        self.initialSize = initialSize
        self.supportsResizing = supportsResizing
    }
}

enum WindowControlGeometry {
    static let minimumSize = CGSize(width: 160, height: 120)
    static let snapEdgeThreshold: CGFloat = 10

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

enum WindowControlSnapZone: Equatable, Sendable {
    case maximize
    case leftHalf
    case rightHalf
}

struct WindowControlScreen: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
}

struct WindowControlSnapDestination: Equatable, Sendable {
    let zone: WindowControlSnapZone
    let frame: CGRect
}

enum WindowControlSnapGeometry {
    static func destination(
        at pointer: CGPoint,
        on screen: WindowControlScreen,
        edgeThreshold: CGFloat = WindowControlGeometry.snapEdgeThreshold
    ) -> WindowControlSnapDestination? {
        guard screen.frame.containsInclusive(pointer),
              edgeThreshold >= 0 else { return nil }

        let zone: WindowControlSnapZone?
        if pointer.y <= screen.frame.minY + edgeThreshold {
            zone = .maximize
        } else if pointer.x <= screen.frame.minX + edgeThreshold {
            zone = .leftHalf
        } else if pointer.x >= screen.frame.maxX - edgeThreshold {
            zone = .rightHalf
        } else {
            zone = nil
        }

        guard let zone else { return nil }
        return WindowControlSnapDestination(
            zone: zone,
            frame: frame(for: zone, visibleFrame: screen.visibleFrame)
        )
    }

    static func accessibilityFrame(
        from appKitFrame: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: appKitFrame.minX,
            y: primaryScreenMaxY - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    static func appKitFrame(
        from accessibilityFrame: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: accessibilityFrame.minX,
            y: primaryScreenMaxY - accessibilityFrame.maxY,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }

    private static func frame(
        for zone: WindowControlSnapZone,
        visibleFrame: CGRect
    ) -> CGRect {
        switch zone {
        case .maximize:
            return visibleFrame
        case .leftHalf:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .rightHalf:
            let halfWidth = visibleFrame.width / 2
            return CGRect(
                x: visibleFrame.minX + halfWidth,
                y: visibleFrame.minY,
                width: visibleFrame.width - halfWidth,
                height: visibleFrame.height
            )
        }
    }
}

private extension CGRect {
    func containsInclusive(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX
            && point.y >= minY && point.y <= maxY
    }
}

protocol WindowControlScreenProviding: AnyObject, Sendable {
    func screen(containing point: CGPoint) -> WindowControlScreen?
}

final class SystemWindowControlScreenProvider:
    WindowControlScreenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var screens: [WindowControlScreen] = []

    @MainActor
    func refresh() {
        let appKitScreens = NSScreen.screens
        guard let primaryScreenMaxY = appKitScreens.first?.frame.maxY else {
            replaceScreens([])
            return
        }
        replaceScreens(
            appKitScreens.map { screen in
                WindowControlScreen(
                    frame: WindowControlSnapGeometry.accessibilityFrame(
                        from: screen.frame,
                        primaryScreenMaxY: primaryScreenMaxY
                    ),
                    visibleFrame: WindowControlSnapGeometry.accessibilityFrame(
                        from: screen.visibleFrame,
                        primaryScreenMaxY: primaryScreenMaxY
                    )
                )
            }
        )
    }

    func screen(containing point: CGPoint) -> WindowControlScreen? {
        lock.lock()
        let currentScreens = screens
        lock.unlock()
        return currentScreens.first { $0.frame.containsInclusive(point) }
    }

    private func replaceScreens(_ screens: [WindowControlScreen]) {
        lock.lock()
        self.screens = screens
        lock.unlock()
    }
}

private final class WindowControlScreenParametersObserver:
    @unchecked Sendable {
    private var token: (any NSObjectProtocol)?

    @MainActor
    init(screenProvider: SystemWindowControlScreenProvider?) {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak screenProvider] _ in
            Task { @MainActor in
                screenProvider?.refresh()
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

@MainActor
protocol WindowControlSnapPreviewPresenting: AnyObject {
    func show(_ destination: WindowControlSnapDestination)
    func hide()
}

@MainActor
final class SystemWindowControlSnapPreviewPresenter:
    WindowControlSnapPreviewPresenting {
    private var panel: NSPanel?
    private var visibleDestination: WindowControlSnapDestination?

    func show(_ destination: WindowControlSnapDestination) {
        guard destination != visibleDestination,
              let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY else {
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        visibleDestination = destination
        panel.setFrame(
            WindowControlSnapGeometry.appKitFrame(
                from: destination.frame,
                primaryScreenMaxY: primaryScreenMaxY
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        guard visibleDestination != nil else { return }
        visibleDestination = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none

        let glassView = NSGlassEffectView(frame: panel.contentView?.bounds ?? .zero)
        glassView.autoresizingMask = [.width, .height]
        glassView.style = .regular
        glassView.cornerRadius = 18
        glassView.setAccessibilityElement(false)
        panel.contentView = glassView
        return panel
    }
}

@MainActor
final class EmptyWindowControlSnapPreviewPresenter:
    WindowControlSnapPreviewPresenting {
    func show(_ destination: WindowControlSnapDestination) {}
    func hide() {}
}

final class EmptyWindowControlScreenProvider:
    WindowControlScreenProviding, @unchecked Sendable {
    func screen(containing point: CGPoint) -> WindowControlScreen? { nil }
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
            "Hold a configured key combination and drag with the primary button."
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
    func raiseAndActivate(_ target: WindowControlTarget, isCancelled: @escaping @Sendable () -> Bool)
    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool
    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool
    func setFrame(_ target: WindowControlTarget, to frame: CGRect) -> Bool
    func setFrame(_ target: WindowControlTarget, to frame: CGRect, isCancelled: @escaping @Sendable () -> Bool) -> Bool
}

extension WindowAccessing {
    func raiseAndActivate(_ target: WindowControlTarget, isCancelled: @escaping @Sendable () -> Bool) {
        guard !isCancelled() else { return }
        raiseAndActivate(target)
    }

    func setFrame(_ target: WindowControlTarget, to frame: CGRect, isCancelled: @escaping @Sendable () -> Bool) -> Bool {
        guard !isCancelled() else { return false }
        return setFrame(target, to: frame)
    }
}

struct WindowControlWindowRecord: Equatable, Sendable {
    let processIdentifier: pid_t
    let frame: CGRect

    func acceptsHitTest(frame candidate: CGRect, at point: CGPoint) -> Bool {
        // AX hit testing already resolves z-order within this owner. Window
        // Server bounds can lag AX immediately after a move or during animation;
        // comparing those two frames would reject the next gesture.
        Self.isValid(frame: candidate) && point.x.isFinite && point.y.isFinite
            && frame.contains(point) && candidate.contains(point)
    }

    func matches(frame candidate: CGRect) -> Bool {
        guard Self.isValid(frame: frame), Self.isValid(frame: candidate) else { return false }
        // On macOS 26, a standard titled NSWindow's Window Server bounds can
        // sit 3 pt horizontally / 2 pt vertically inside its AX frame. Compare
        // edges with a small allowance, not widths (which double the inset).
        // The fallback still scans every candidate and rejects ambiguous matches.
        let edgeTolerance: CGFloat = 4
        return abs(frame.minX - candidate.minX) <= edgeTolerance
            && abs(frame.minY - candidate.minY) <= edgeTolerance
            && abs(frame.maxX - candidate.maxX) <= edgeTolerance
            && abs(frame.maxY - candidate.maxY) <= edgeTolerance
    }

    static func isValid(frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    func uniquelyMatchingWindow<Element>(
        in windows: [Element],
        canContinue: () -> Bool,
        frame: (Element) -> CGRect?
    ) -> Element? {
        guard windows.count <= 64 else { return nil }
        var match: Element?
        for window in windows {
            guard canContinue(), let candidate = frame(window),
                  Self.isValid(frame: candidate) else { return nil }
            if matches(frame: candidate) {
                // Public bounds cannot identify the frontmost of identical windows.
                guard match == nil else { return nil }
                match = window
            }
        }
        // A partial scan cannot prove the candidate is unique.
        return canContinue() ? match : nil
    }
}

struct WindowControlAXLookupBudget {
    private let deadline: TimeInterval
    private let now: () -> TimeInterval

    init(
        timeout: TimeInterval = 1,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.now = now
        deadline = now() + timeout
    }

    var requestTimeout: Float? {
        let remaining = deadline - now()
        // AX interprets zero as resetting its timeout rather than canceling a call.
        guard remaining.isFinite, remaining >= 0.001 else { return nil }
        return Float(min(0.2, remaining))
    }
}

enum WindowControlFrameWriter {
    static func apply(
        frame: CGRect,
        isCancelled: () -> Bool,
        resize: (CGSize) -> Bool,
        move: (CGPoint) -> Bool
    ) -> Bool {
        // A completed AX call cannot be undone, but cancellation must stop the
        // remaining writes in a cross-display resize/move/resize sequence.
        guard WindowControlWindowRecord.isValid(frame: frame),
              !isCancelled(), resize(frame.size),
              !isCancelled(), move(frame.origin),
              !isCancelled(), resize(frame.size),
              !isCancelled() else { return false }
        return true
    }
}

struct WindowControlWindowResolver<Element> {
    let isWindow: (Element) -> Bool
    let relatedElement: (Element, String) -> Element?
    let isEqual: (Element, Element) -> Bool

    func resolve(_ element: Element, canContinue: () -> Bool = { true }) -> Element? {
        var pending = [element]
        var visited: [Element] = []
        while !pending.isEmpty, visited.count < 32 {
            guard canContinue() else { return nil }
            let candidate = pending.removeFirst()
            guard !visited.contains(where: { isEqual($0, candidate) }) else { continue }
            visited.append(candidate)
            if isWindow(candidate) { return canContinue() ? candidate : nil }
            // AXTopLevelUIElement may be a sheet or group, not an AXWindow.
            // Traverse it instead of rejecting an otherwise movable application.
            for attribute in [kAXWindowAttribute, kAXTopLevelUIElementAttribute, kAXParentAttribute] {
                guard canContinue() else { return nil }
                if let related = relatedElement(candidate, attribute) {
                    pending.append(related)
                }
            }
        }
        return nil
    }
}

final class SystemWindowAccessor: WindowAccessing, @unchecked Sendable {
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    func target(
        at point: CGPoint,
        operation: WindowControlOperation
    ) -> WindowControlTarget? {
        let budget = WindowControlAXLookupBudget()
        guard point.x.isFinite, point.y.isFinite,
              Float(point.x).isFinite, Float(point.y).isFinite,
              let record = windowRecord(at: point),
              record.processIdentifier > 0,
              record.processIdentifier != ownProcessIdentifier else { return nil }
        let application = AXUIElementCreateApplication(record.processIdentifier)
        guard prepare(application, budget: budget) else { return nil }

        // A system-wide AX timeout changes other features' AX calls as well.
        // Restrict hit testing to the topmost window's app for a local timeout.
        var hitElement: AXUIElement?
        if AXUIElementCopyElementAtPosition(
            application, Float(point.x), Float(point.y), &hitElement
        ) == .success, let hitElement,
           let window = resolveWindow(from: hitElement, budget: budget) {
            return target(
                window: window, record: record, operation: operation, budget: budget,
                hitTestPoint: point
            )
        }

        // Some apps expose AXWindows before their content hit-test tree. Scan
        // all bounded candidates so identical overlapping windows remain ambiguous.
        guard let windows = attribute(
            application, kAXWindowsAttribute as CFString, budget: budget
        ) as? [AXUIElement] else { return nil }
        let matchedWindow = record.uniquelyMatchingWindow(
            in: windows,
            canContinue: { budget.requestTimeout != nil }
        ) { window in
            guard stringAttribute(window, kAXRoleAttribute as CFString, budget: budget)
                    == kAXWindowRole as String,
                  let position = pointAttribute(window, kAXPositionAttribute as CFString, budget: budget),
                  let size = sizeAttribute(window, kAXSizeAttribute as CFString, budget: budget) else {
                return nil
            }
            return CGRect(origin: position, size: size)
        }
        return matchedWindow.flatMap {
            target(window: $0, record: record, operation: operation, budget: budget)
        }
    }

    private func windowRecord(at point: CGPoint) -> WindowControlWindowRecord? {
        guard let records = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for record in records {
            guard let pid = record[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = record[kCGWindowLayer as String] as? NSNumber,
                  let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  WindowControlWindowRecord.isValid(frame: frame),
                  frame.contains(point),
                  (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else {
                continue
            }
            // A menu or overlay above the pointer blocks the windows below it.
            guard layer.intValue >= 0, layer.intValue < 21 else { return nil }
            return WindowControlWindowRecord(
                processIdentifier: pid.int32Value, frame: frame
            )
        }
        return nil
    }

    private func target(
        window: AXUIElement,
        record: WindowControlWindowRecord,
        operation: WindowControlOperation,
        budget: WindowControlAXLookupBudget,
        hitTestPoint: CGPoint? = nil
    ) -> WindowControlTarget? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              pid == record.processIdentifier,
              pid != ownProcessIdentifier,
              pid > 0,
              boolAttribute(window, kAXMinimizedAttribute as CFString, budget: budget) != true,
              boolAttribute(window, "AXFullScreen" as CFString, budget: budget) != true,
              let position = pointAttribute(window, kAXPositionAttribute as CFString, budget: budget),
              let size = sizeAttribute(window, kAXSizeAttribute as CFString, budget: budget) else {
            return nil
        }
        let frame = CGRect(origin: position, size: size)
        let matchesTarget = hitTestPoint.map { record.acceptsHitTest(frame: frame, at: $0) }
            ?? record.matches(frame: frame)
        guard matchesTarget else { return nil }

        let positionIsSettable = isSettable(
            window, kAXPositionAttribute as CFString, budget: budget
        )
        let sizeIsSettable = isSettable(
            window, kAXSizeAttribute as CFString, budget: budget
        )
        let supportsOperation = switch operation {
        case .move: positionIsSettable
        case .resize: sizeIsSettable
        }
        guard supportsOperation, budget.requestTimeout != nil else { return nil }

        AXUIElementSetMessagingTimeout(window, 0.2)
        return WindowControlTarget(
            element: window,
            processIdentifier: pid,
            initialPosition: position,
            initialSize: size,
            supportsResizing: sizeIsSettable
        )
    }

    func raiseAndActivate(_ target: WindowControlTarget) {
        raiseAndActivate(target, isCancelled: { false })
    }

    func raiseAndActivate(
        _ target: WindowControlTarget,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        guard !isCancelled(), let window = axElement(from: target) else { return }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let pid = target.processIdentifier
        DispatchQueue.main.async {
            guard !isCancelled() else { return }
            _ = NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    func move(_ target: WindowControlTarget, to position: CGPoint) -> Bool {
        guard position.x.isFinite, position.y.isFinite,
              let window = axElement(from: target) else { return false }
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, value
        ) == .success
    }

    func resize(_ target: WindowControlTarget, to size: CGSize) -> Bool {
        guard target.supportsResizing,
              WindowControlWindowRecord.isValid(frame: CGRect(origin: .zero, size: size)),
              let window = axElement(from: target) else { return false }
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, value
        ) == .success
    }

    func setFrame(_ target: WindowControlTarget, to frame: CGRect) -> Bool {
        setFrame(target, to: frame, isCancelled: { false })
    }

    func setFrame(
        _ target: WindowControlTarget,
        to frame: CGRect,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard target.supportsResizing else { return false }
        return WindowControlFrameWriter.apply(
            frame: frame,
            isCancelled: isCancelled,
            resize: { self.resize(target, to: $0) },
            move: { self.move(target, to: $0) }
        )
    }

    private func resolveWindow(
        from element: AXUIElement,
        budget: WindowControlAXLookupBudget
    ) -> AXUIElement? {
        WindowControlWindowResolver<AXUIElement>(
            isWindow: { self.stringAttribute($0, kAXRoleAttribute as CFString, budget: budget)
                == kAXWindowRole as String },
            relatedElement: { self.elementAttribute($0, $1 as CFString, budget: budget) },
            isEqual: { CFEqual($0, $1) }
        ).resolve(element, canContinue: { budget.requestTimeout != nil })
    }

    private func axElement(from target: WindowControlTarget) -> AXUIElement? {
        guard target.processIdentifier > 0,
              target.processIdentifier != ownProcessIdentifier,
              CFGetTypeID(target.element) == AXUIElementGetTypeID() else { return nil }
        let element = target.element as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == target.processIdentifier else { return nil }
        return element
    }

    private func prepare(
        _ element: AXUIElement,
        budget: WindowControlAXLookupBudget
    ) -> Bool {
        guard let timeout = budget.requestTimeout else { return false }
        return AXUIElementSetMessagingTimeout(element, timeout) == .success
    }

    private func attribute(
        _ element: AXUIElement,
        _ name: CFString,
        budget: WindowControlAXLookupBudget
    ) -> CFTypeRef? {
        guard prepare(element, budget: budget) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              budget.requestTimeout != nil else { return nil }
        return value
    }

    private func elementAttribute(
        _ element: AXUIElement,
        _ name: CFString,
        budget: WindowControlAXLookupBudget
    ) -> AXUIElement? {
        guard let value = attribute(element, name, budget: budget),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return .some(value as! AXUIElement)
    }

    private func stringAttribute(
        _ element: AXUIElement,
        _ name: CFString,
        budget: WindowControlAXLookupBudget
    ) -> String? {
        attribute(element, name, budget: budget) as? String
    }

    private func boolAttribute(
        _ element: AXUIElement,
        _ name: CFString,
        budget: WindowControlAXLookupBudget
    ) -> Bool? {
        (attribute(element, name, budget: budget) as? NSNumber)?.boolValue
    }

    private func pointAttribute(
        _ element: AXUIElement,
        _ name: CFString,
        budget: WindowControlAXLookupBudget
    ) -> CGPoint? {
        guard let value = attribute(element, name, budget: budget),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point),
              point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private func sizeAttribute(
        _ element: AXUIElement,
        _ name: CFString,
        budget: WindowControlAXLookupBudget
    ) -> CGSize? {
        guard let value = attribute(element, name, budget: budget),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size),
              WindowControlWindowRecord.isValid(frame: CGRect(origin: .zero, size: size)) else {
            return nil
        }
        return size
    }

    private func isSettable(
        _ element: AXUIElement,
        _ name: CFString,
        budget: WindowControlAXLookupBudget
    ) -> Bool {
        guard prepare(element, budget: budget) else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name, &settable) == .success
            && settable.boolValue && budget.requestTimeout != nil
    }
}

struct WindowControlPointerSample: Equatable, Sendable {
    let operation: WindowControlOperation
    let location: CGPoint
}

final class WindowControlPointerCoordinator: @unchecked Sendable {
    private let windowAccessor: any WindowAccessing
    private let screenProvider: any WindowControlScreenProviding
    private let previewHandler:
        @Sendable (WindowControlSnapDestination?) -> Void
    private var gestureSession = WindowControlGestureSession()
    private var activeSnapDestination: WindowControlSnapDestination?
    private var activeSnapTarget: WindowControlTarget?
    private var gestureFailure: WindowControlActivity?

    init(
        windowAccessor: any WindowAccessing,
        screenProvider: any WindowControlScreenProviding =
            EmptyWindowControlScreenProvider(),
        previewHandler: @escaping @Sendable (
            WindowControlSnapDestination?
        ) -> Void = { _ in }
    ) {
        self.windowAccessor = windowAccessor
        self.screenProvider = screenProvider
        self.previewHandler = previewHandler
    }

    func process(
        _ sample: WindowControlPointerSample,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> WindowControlActivity {
        guard !isCancelled() else { return .listening }
        if let gestureFailure { return gestureFailure }
        if !gestureSession.isTracking {
            let target = windowAccessor.target(
                at: sample.location,
                operation: sample.operation
            )
            // AX can reply after the user releases the chord or disables the
            // feature. Do not raise or mutate that abandoned gesture's target.
            guard !isCancelled() else { return .listening }
            guard let target else {
                gestureFailure = .targetUnavailable
                return .targetUnavailable
            }
            gestureSession.begin(
                operation: sample.operation,
                target: target,
                pointer: sample.location
            )
            windowAccessor.raiseAndActivate(target, isCancelled: isCancelled)
            return .tracking(sample.operation)
        }

        guard let update = gestureSession.update(
            operation: sample.operation,
            pointer: sample.location
        ) else {
            reset()
            return process(sample, isCancelled: isCancelled)
        }

        let succeeded: Bool
        switch update {
        case let .move(target, position):
            succeeded = processMove(
                target: target,
                position: position,
                pointer: sample.location,
                isCancelled: isCancelled
            )
        case let .resize(target, size):
            clearSnapPreview()
            guard !isCancelled() else { return .listening }
            succeeded = windowAccessor.resize(target, to: size)
        }
        guard !isCancelled() else { return .listening }
        guard succeeded else {
            reset()
            gestureFailure = .updateRejected(sample.operation)
            return .updateRejected(sample.operation)
        }
        return .tracking(sample.operation)
    }

    func reset() {
        gestureFailure = nil
        gestureSession.reset()
        clearSnapPreview()
    }

    func finish(
        commitSnap: Bool,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> WindowControlActivity {
        guard !isCancelled() else {
            reset()
            return .listening
        }
        let activity: WindowControlActivity
        if let gestureFailure {
            activity = gestureFailure
        } else if commitSnap,
           let activeSnapDestination,
           let activeSnapTarget,
           !windowAccessor.setFrame(
               activeSnapTarget,
               to: activeSnapDestination.frame,
               isCancelled: isCancelled
           ) {
            activity = .updateRejected(.move)
        } else {
            activity = .listening
        }
        reset()
        return activity
    }

    private func clearSnapPreview() {
        guard activeSnapDestination != nil || activeSnapTarget != nil else {
            return
        }
        activeSnapDestination = nil
        activeSnapTarget = nil
        previewHandler(nil)
    }

    private func processMove(
        target: WindowControlTarget,
        position: CGPoint,
        pointer: CGPoint,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        let destination = target.supportsResizing
            ? screenProvider.screen(containing: pointer).flatMap {
                WindowControlSnapGeometry.destination(
                    at: pointer,
                    on: $0
                )
            }
            : nil

        guard !isCancelled() else { return false }

        if let destination {
            guard windowAccessor.move(target, to: position) else {
                return false
            }
            guard !isCancelled() else { return false }
            if destination != activeSnapDestination {
                activeSnapDestination = destination
                activeSnapTarget = target
                previewHandler(destination)
            }
            return true
        }

        clearSnapPreview()
        return windowAccessor.move(target, to: position)
    }
}

final class WindowControlPointerProcessor: @unchecked Sendable {
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
    private var initialSample: PendingSample?
    private var pendingSample: PendingSample?
    private var generation: UInt64 = 0
    private var cancellationRevision: UInt64 = 0
    private var isScheduled = false
    private var isGestureActive = false
    private var lastActivity: WindowControlActivity?

    init(
        windowAccessor: any WindowAccessing,
        screenProvider: any WindowControlScreenProviding,
        previewHandler: @escaping @MainActor @Sendable (
            WindowControlSnapDestination?
        ) -> Void,
        activityHandler: @escaping @MainActor @Sendable (WindowControlActivity) -> Void
    ) {
        coordinator = WindowControlPointerCoordinator(
            windowAccessor: windowAccessor,
            screenProvider: screenProvider,
            previewHandler: { destination in
                Task { @MainActor in
                    previewHandler(destination)
                }
            }
        )
        self.activityHandler = activityHandler
    }

    func begin(_ sample: WindowControlPointerSample) {
        lock.lock()
        isGestureActive = true
        initialSample = PendingSample(generation: generation, value: sample)
        pendingSample = nil
        let shouldSchedule = !isScheduled
        if shouldSchedule { isScheduled = true }
        lock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in
                self?.processPendingSample()
            }
        }
    }

    func submit(_ sample: WindowControlPointerSample) {
        lock.lock()
        guard isGestureActive else {
            lock.unlock()
            return
        }
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

    func finish(
        applyPendingUpdate: Bool,
        commitSnap: Bool
    ) {
        lock.lock()
        guard isGestureActive || initialSample != nil || pendingSample != nil else {
            lock.unlock()
            return
        }
        let initialSample = applyPendingUpdate
            ? self.initialSample?.value
            : nil
        let finalSample = applyPendingUpdate
            ? pendingSample?.value
            : nil
        let completionRevision = cancellationRevision
        isGestureActive = false
        generation &+= 1
        self.initialSample = nil
        pendingSample = nil
        lock.unlock()
        queue.async { [weak self] in
            guard let self, isCompletionCurrent(completionRevision) else { return }
            let isCancelled: @Sendable () -> Bool = { [weak self] in
                self?.isCompletionCurrent(completionRevision) != true
            }
            if let initialSample {
                _ = coordinator.process(initialSample, isCancelled: isCancelled)
            }
            guard isCompletionCurrent(completionRevision) else { return }
            if let finalSample {
                _ = coordinator.process(finalSample, isCancelled: isCancelled)
            }
            guard isCompletionCurrent(completionRevision) else { return }
            let activity = coordinator.finish(commitSnap: commitSnap, isCancelled: isCancelled)
            guard !isCancelled() else { return }
            publish(activity)
        }
    }

    func reset() {
        lock.lock()
        // Mouse-up may already have queued its final update. Cancellation must
        // invalidate that completion even after isGestureActive became false.
        cancellationRevision &+= 1
        generation &+= 1
        isGestureActive = false
        initialSample = nil
        pendingSample = nil
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            coordinator.reset()
            publish(.listening)
        }
    }

    private func isCompletionCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRevision == revision
    }

    private func processPendingSample() {
        lock.lock()
        guard let sample = initialSample ?? pendingSample else {
            isScheduled = false
            lock.unlock()
            return
        }
        if initialSample != nil {
            initialSample = nil
        } else {
            pendingSample = nil
        }
        let isCurrent = sample.generation == generation
        let revision = cancellationRevision
        lock.unlock()

        let delay: DispatchTimeInterval
        if isCurrent {
            let isCancelled: @Sendable () -> Bool = { [weak self] in
                self?.isCompletionCurrent(revision) != true
            }
            let activity = coordinator.process(sample.value, isCancelled: isCancelled)
            if !isCancelled() { publish(activity) }
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

enum WindowControlEventTapConfiguration {
    // HID event taps require a root process. The session tap is the earliest
    // supported filtering point for a regular Accessibility-authorized app.
    static let location: CGEventTapLocation = .cgSessionEventTap
    static let placement: CGEventTapPlacement = .tailAppendEventTap
    static let eventMask: CGEventMask = [
        CGEventType.flagsChanged,
        .leftMouseDown,
        .leftMouseDragged,
        .mouseMoved,
        .leftMouseUp,
    ].reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
    }
}

struct WindowControlPrimaryDragSession: Equatable, Sendable {
    struct Completion: Equatable, Sendable {
        let shouldApplyPendingUpdate: Bool
        let shouldCommitSnap: Bool
    }

    private(set) var operation: WindowControlOperation?
    private(set) var isConsuming = false
    private(set) var isCancelled = false

    mutating func begin(operation: WindowControlOperation) {
        self.operation = operation
        isConsuming = true
        isCancelled = false
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard isConsuming, !isCancelled else { return false }
        operation = nil
        isCancelled = true
        return true
    }

    mutating func finish() -> Completion? {
        guard isConsuming else { return nil }
        let completion = Completion(
            shouldApplyPendingUpdate: !isCancelled,
            shouldCommitSnap: !isCancelled && operation == .move
        )
        reset()
        return completion
    }

    mutating func reset() {
        operation = nil
        isConsuming = false
        isCancelled = false
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
    func recover(configuration: WindowControlConfiguration, recreate: Bool) async -> Bool
    func stop()
}

final class WindowControlEventTapWorker: @unchecked Sendable {
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
    private let isPrimaryButtonPressed: @Sendable () -> Bool
    private var configuration: WindowControlConfiguration
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var thread: Thread?
    private var running = false
    private var stopRequested = false
    private var dragSession = WindowControlPrimaryDragSession()

    init(
        configuration: WindowControlConfiguration,
        windowAccessor: any WindowAccessing,
        screenProvider: any WindowControlScreenProviding,
        isPrimaryButtonPressed: @escaping @Sendable () -> Bool = {
            CGEventSource.buttonState(.combinedSessionState, button: .left)
                || CGEventSource.buttonState(.hidSystemState, button: .left)
        },
        previewHandler: @escaping @MainActor @Sendable (
            WindowControlSnapDestination?
        ) -> Void,
        activityHandler: @escaping @MainActor @Sendable (WindowControlActivity) -> Void
    ) {
        self.configuration = configuration
        self.isPrimaryButtonPressed = isPrimaryButtonPressed
        pointerProcessor = WindowControlPointerProcessor(
            windowAccessor: windowAccessor,
            screenProvider: screenProvider,
            previewHandler: previewHandler,
            activityHandler: activityHandler
        )
    }

    var isRunning: Bool {
        lock.lock()
        let running = running
        let eventTap = eventTap
        lock.unlock()
        guard running, let eventTap else { return false }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return thread == nil
    }

    func start() -> Bool {
        if isRunning { return true }

        lock.lock()
        guard thread == nil else {
            lock.unlock()
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = StartResult()
        let thread = Thread { [self] in
            autoreleasepool {
                runEventTap(result: result, semaphore: semaphore)
            }
        }
        thread.name = "com.yorozu.app.window-control"
        thread.qualityOfService = .userInteractive

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
        guard self.configuration != configuration else {
            lock.unlock()
            return
        }
        self.configuration = configuration
        // A new binding must not reinterpret a gesture already in progress.
        // Keep consuming its matching mouse-up, but discard queued geometry.
        dragSession.cancel()
        pointerProcessor.reset()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopRequested = true
        running = false
        let runLoop = runLoop
        let eventTap = eventTap
        dragSession.reset()
        pointerProcessor.reset()
        lock.unlock()
        if let eventTap {
            // Remove the tap from the input path before waiting for its worker.
            // Invalidation also prevents startup from re-enabling a stopped tap.
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoop {
            // A stop can race with startup just before CFRunLoopRun. Keep a
            // queued stop as well so a newly entered run-loop cannot survive it.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runEventTap(
        result: StartResult,
        semaphore: DispatchSemaphore
    ) {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: WindowControlEventTapConfiguration.location,
            // Command-alone input switching observes mouse activity at the head
            // of the chain. Let it cancel its candidate before we consume a drag.
            place: WindowControlEventTapConfiguration.placement,
            options: .defaultTap,
            eventsOfInterest: WindowControlEventTapConfiguration.eventMask,
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
            lock.lock()
            thread = nil
            lock.unlock()
            result.complete(false)
            semaphore.signal()
            return
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        lock.lock()
        guard !stopRequested else {
            thread = nil
            lock.unlock()
            CFMachPortInvalidate(eventTap)
            result.complete(false)
            semaphore.signal()
            return
        }
        runLoop = currentRunLoop
        self.eventTap = eventTap
        lock.unlock()

        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        // A newly created tap is already enabled. Do not re-enable it here:
        // stop() may have invalidated it after it was published above.
        let enabled = CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
        lock.lock()
        let shouldRun = !stopRequested && enabled
        running = shouldRun
        lock.unlock()
        result.complete(shouldRun)
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

    func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Recovery must first recheck authorization and the foreground app.
            // stop() takes this lock itself, so handle disabled taps before it.
            stop()
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        // Only bounded state changes and queue submissions happen under this
        // lock. This serializes event admission with stop/configuration changes;
        // Accessibility requests continue to run on the separate AX queue.
        guard !stopRequested else { return false }
        switch type {
        case .leftMouseDown:
            // A duplicate down cannot replace the original target or starting
            // pointer while its matching mouse-up is still outstanding.
            guard !dragSession.isConsuming else { return true }
            guard let operation = configuration.operation(for: event.flags) else {
                return false
            }
            dragSession.begin(operation: operation)
            pointerProcessor.begin(
                WindowControlPointerSample(
                    operation: operation,
                    location: event.location
                )
            )
            return true

        case .leftMouseDragged, .mouseMoved:
            guard dragSession.isConsuming else { return false }
            // Some virtual pointing devices deliver button-held motion as
            // mouseMoved. Admit it only after our own matching mouse-down and
            // while a button is still held. A missed release must not turn
            // ordinary pointer motion into window movement or commit a snap.
            if type == .mouseMoved, !isPrimaryButtonPressed() {
                dragSession.reset()
                pointerProcessor.reset()
                return false
            }
            guard !dragSession.isCancelled,
                  let operation = dragSession.operation,
                  configuration.operation(for: event.flags) == operation else {
                cancelActiveDragIfNeeded()
                return true
            }
            pointerProcessor.submit(
                WindowControlPointerSample(
                    operation: operation,
                    location: event.location
                )
            )
            return true

        case .leftMouseUp:
            let operation = dragSession.operation
            guard let completion = dragSession.finish() else { return false }
            if completion.shouldApplyPendingUpdate, let operation {
                pointerProcessor.submit(
                    WindowControlPointerSample(operation: operation, location: event.location)
                )
            }
            pointerProcessor.finish(
                applyPendingUpdate: completion.shouldApplyPendingUpdate,
                commitSnap: completion.shouldCommitSnap
            )
            return true

        case .flagsChanged:
            if dragSession.isConsuming,
               let operation = dragSession.operation,
               configuration.operation(for: event.flags) != operation {
                cancelActiveDragIfNeeded()
            }
            return false

        default:
            return false
        }
    }

    private func cancelActiveDragIfNeeded() {
        guard dragSession.cancel() else { return }
        pointerProcessor.reset()
    }

}

@MainActor
final class WindowControlMonitor: WindowControlMonitoring {
    private let windowAccessor: any WindowAccessing
    private let screenProvider: any WindowControlScreenProviding
    private let snapPreviewPresenter: any WindowControlSnapPreviewPresenting
    private let screenParametersObserver: WindowControlScreenParametersObserver
    private var worker: WindowControlEventTapWorker?
    private var workerRevision: UInt64 = 0
    private var activityHandler:
        (@MainActor @Sendable (WindowControlActivity) -> Void)?

    init(
        windowAccessor: any WindowAccessing = SystemWindowAccessor(),
        screenProvider: (any WindowControlScreenProviding)? = nil,
        snapPreviewPresenter: (
            any WindowControlSnapPreviewPresenting
        )? = nil
    ) {
        self.windowAccessor = windowAccessor
        let resolvedScreenProvider = screenProvider
            ?? SystemWindowControlScreenProvider()
        self.screenProvider = resolvedScreenProvider
        self.snapPreviewPresenter = snapPreviewPresenter
            ?? SystemWindowControlSnapPreviewPresenter()
        let systemScreenProvider = resolvedScreenProvider
            as? SystemWindowControlScreenProvider
        systemScreenProvider?.refresh()
        screenParametersObserver = WindowControlScreenParametersObserver(
            screenProvider: systemScreenProvider
        )
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
        if let worker {
            stop()
            guard worker.isStopped else { return false }
        }
        workerRevision &+= 1
        let revision = workerRevision
        let activityHandler = activityHandler ?? { _ in }
        let worker = WindowControlEventTapWorker(
            configuration: configuration,
            windowAccessor: windowAccessor,
            screenProvider: screenProvider,
            previewHandler: { [weak self] destination in
                guard let self, self.workerRevision == revision else { return }
                if let destination {
                    self.snapPreviewPresenter.show(destination)
                } else {
                    self.snapPreviewPresenter.hide()
                }
            },
            activityHandler: { [weak self] activity in
                guard let self, self.workerRevision == revision else { return }
                activityHandler(activity)
            }
        )
        self.worker = worker
        let started = worker.start()
        return started
    }

    func update(configuration: WindowControlConfiguration) {
        worker?.update(configuration: configuration)
    }

    func recover(configuration: WindowControlConfiguration, recreate: Bool) async -> Bool {
        if !recreate, isRunning {
            update(configuration: configuration)
            return true
        }
        let previousWorker = worker
        stop()
        let revision = workerRevision
        // Wait for the old run-loop to release its tap before installing another.
        // The main actor remains available to cancellation and settings changes.
        for _ in 0..<50 {
            if previousWorker?.isStopped != false { break }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        guard workerRevision == revision,
              previousWorker?.isStopped != false,
              !Task.isCancelled else { return false }
        return start(configuration: configuration)
    }

    func stop() {
        workerRevision &+= 1
        worker?.stop()
        snapPreviewPresenter.hide()
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
        case pausedForSystemSettings
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
            case .pausedForSystemSettings:
                "Paused in System Settings"
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
    private let workspaceNotificationCenter: NotificationCenter?
    private let monitoringHealthInterval: Duration
    private var hasStarted = false
    private var isRecoveringMonitor = false
    private var monitoringHealthTask: Task<Void, Never>?
    private var workspaceRecoveryTokens: [any NSObjectProtocol] = []
    private var systemSettingsActivationPending = false

    init(
        defaults: UserDefaults,
        monitor: any WindowControlMonitoring,
        permissionProvider: any CommandInputModePermissionProviding,
        codeSigningStatusProvider: any CommandInputModeCodeSigningStatusProviding =
            FixedCommandInputModeCodeSigningStatusProvider(status: .stable),
        backgroundActivityManager: any WindowControlBackgroundActivityManaging =
            NoOpWindowControlBackgroundActivityManager(),
        workspaceNotificationCenter: NotificationCenter? = nil,
        monitoringHealthInterval: Duration = .seconds(5)
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.permissionProvider = permissionProvider
        self.codeSigningStatusProvider = codeSigningStatusProvider
        self.backgroundActivityManager = backgroundActivityManager
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.monitoringHealthInterval = monitoringHealthInterval
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
            backgroundActivityManager: SystemWindowControlBackgroundActivityManager(),
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter
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
        startWorkspaceRecoveryObservers()
        refreshAuthorization()
    }

    func stop() {
        stopMonitoringHealthChecks()
        stopWorkspaceRecoveryObservers()
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
        codeSigningStatus = codeSigningStatusProvider.status
        reconcile()
    }

    func recoverMonitoringIfNeeded(recreate: Bool = false) async {
        guard hasStarted, isEnabled, configuration.isValid else { return }
        isAccessibilityGranted = permissionProvider.isAccessibilityGranted
        guard isAccessibilityGranted, !shouldSuspendForSystemSettings else {
            reconcile()
            return
        }
        backgroundActivityManager.begin()
        guard !isRecoveringMonitor else { return }
        guard recreate || !monitor.isRunning else {
            runtimeStatus = .active
            return
        }
        isRecoveringMonitor = true
        let recovered = await monitor.recover(configuration: configuration, recreate: recreate)
        isRecoveringMonitor = false
        // A permission or configuration change may arrive while the old tap stops.
        isAccessibilityGranted = permissionProvider.isAccessibilityGranted
        guard hasStarted, isEnabled, configuration.isValid, isAccessibilityGranted,
              !shouldSuspendForSystemSettings else {
            monitor.stop()
            reconcile()
            return
        }
        monitor.update(configuration: configuration)
        runtimeStatus = recovered && monitor.isRunning ? .active : .unavailable
        if runtimeStatus == .active { lastActivity = .monitorRecovered }
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
        isAccessibilityGranted = permissionProvider.isAccessibilityGranted
        guard hasStarted else {
            stopMonitoringHealthChecks()
            runtimeStatus = isEnabled ? preflightStatus : .off
            return
        }
        guard isEnabled else {
            stopMonitoringHealthChecks()
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .off
            lastActivity = nil
            return
        }
        guard configuration.isValid else {
            stopMonitoringHealthChecks()
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .needsConfiguration
            lastActivity = nil
            return
        }
        // Keep the existing health check while this feature is enabled, so a
        // permission re-grant can recover without bringing Yorozu to the front.
        startMonitoringHealthChecks()
        guard !shouldSuspendForSystemSettings else {
            monitor.stop()
            backgroundActivityManager.end()
            runtimeStatus = .pausedForSystemSettings
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
        guard !isRecoveringMonitor else { return }
        if monitor.isRunning {
            monitor.update(configuration: configuration)
            runtimeStatus = .active
        } else {
            runtimeStatus = monitor.start(configuration: configuration)
                ? .active
                : .unavailable
        }
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
                guard let self else { return }
                await self.recoverMonitoringIfNeeded()
            }
        }
    }

    private func stopMonitoringHealthChecks() {
        monitoringHealthTask?.cancel()
        monitoringHealthTask = nil
    }

    private func startWorkspaceRecoveryObservers() {
        guard workspaceRecoveryTokens.isEmpty, let workspaceNotificationCenter else { return }
        workspaceRecoveryTokens = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ].map { name in
            workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.recoverMonitoringIfNeeded(recreate: true)
                }
            }
        }
        workspaceRecoveryTokens.append(
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Pause synchronously when System Settings comes forward, before
                // a user can revoke Accessibility access from an active tap.
                let activatedApplication = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication
                let isSystemSettings = activatedApplication?.bundleIdentifier
                    == "com.apple.systempreferences"
                MainActor.assumeIsolated {
                    self?.systemSettingsActivationPending = isSystemSettings
                    self?.refreshAuthorization()
                }
                Task { @MainActor [weak self] in
                    await self?.recoverMonitoringIfNeeded()
                }
            }
        )
    }

    private func stopWorkspaceRecoveryObservers() {
        systemSettingsActivationPending = false
        guard let workspaceNotificationCenter else { return }
        workspaceRecoveryTokens.forEach { workspaceNotificationCenter.removeObserver($0) }
        workspaceRecoveryTokens.removeAll()
    }

    private var preflightStatus: RuntimeStatus {
        if !configuration.isValid { return .needsConfiguration }
        if shouldSuspendForSystemSettings { return .pausedForSystemSettings }
        if !isAccessibilityGranted { return .permissionRequired }
        return .off
    }

    private var shouldSuspendForSystemSettings: Bool {
        systemSettingsActivationPending || permissionProvider.isSystemSettingsActive
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
    func recover(configuration: WindowControlConfiguration, recreate: Bool) async -> Bool { false }
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
