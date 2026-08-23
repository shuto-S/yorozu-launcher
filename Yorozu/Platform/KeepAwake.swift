import AppKit
import Foundation
import Observation

enum KeepAwakeDuration: Hashable, Sendable {
    case untilTurnedOff
    case minutes(Int)

    static let defaultValue: Self = .minutes(30)
    static let choices: [Self] = [.untilTurnedOff]
        + stride(from: 5, through: 240, by: 5).map(Self.minutes)

    init(storedValue: Int) {
        if storedValue == 0 {
            self = .untilTurnedOff
        } else if storedValue >= 5, storedValue <= 240, storedValue.isMultiple(of: 5) {
            self = .minutes(storedValue)
        } else {
            self = .defaultValue
        }
    }

    var storedValue: Int {
        switch self {
        case .untilTurnedOff: 0
        case let .minutes(value): value
        }
    }

    var title: String {
        switch self {
        case .untilTurnedOff:
            "Until Turned Off"
        case let .minutes(value) where value < 60:
            String(value) + " Minutes"
        case let .minutes(value) where value.isMultiple(of: 60):
            value == 60 ? "1 Hour" : String(value / 60) + " Hours"
        case let .minutes(value):
            String(value / 60) + " hr " + String(value % 60) + " min"
        }
    }
}

@MainActor
protocol SleepActivityManaging: AnyObject {
    func beginPreventingIdleSleep(reason: String) -> NSObjectProtocol
    func endPreventingIdleSleep(_ token: NSObjectProtocol)
}

@MainActor
final class ProcessInfoSleepActivityManager: SleepActivityManaging {
    private let processInfo: ProcessInfo

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    func beginPreventingIdleSleep(reason: String) -> NSObjectProtocol {
        processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleDisplaySleepDisabled,
                .idleSystemSleepDisabled,
            ],
            reason: reason
        )
    }

    func endPreventingIdleSleep(_ token: NSObjectProtocol) {
        processInfo.endActivity(token)
    }
}

@MainActor
final class NoOpSleepActivityManager: SleepActivityManaging {
    private final class Token: NSObject {}

    func beginPreventingIdleSleep(reason: String) -> NSObjectProtocol { Token() }
    func endPreventingIdleSleep(_ token: NSObjectProtocol) {}
}

@MainActor
@Observable
final class KeepAwakeController {
    private enum DefaultsKey {
        static let defaultDuration = "keepAwake.defaultDurationMinutes"
        static let showsSeparateMenuBarIcon = "keepAwake.showsSeparateMenuBarIcon"
    }

    private let defaults: UserDefaults
    private let activityManager: any SleepActivityManaging
    private let now: () -> Date
    @ObservationIgnored private var activityToken: NSObjectProtocol?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    private(set) var activeDuration: KeepAwakeDuration?
    private(set) var expirationDate: Date?

    var defaultDuration: KeepAwakeDuration {
        didSet {
            guard defaultDuration != oldValue else { return }
            defaults.set(defaultDuration.storedValue, forKey: DefaultsKey.defaultDuration)
            notifyObservers()
        }
    }

    var showsSeparateMenuBarIcon: Bool {
        didSet {
            guard showsSeparateMenuBarIcon != oldValue else { return }
            defaults.set(showsSeparateMenuBarIcon, forKey: DefaultsKey.showsSeparateMenuBarIcon)
            notifyObservers()
        }
    }

    var isActive: Bool { activityToken != nil }

    var statusSubtitle: String {
        guard isActive, let activeDuration else { return "Off" }
        switch activeDuration {
        case .untilTurnedOff:
            return "On until turned off"
        case .minutes:
            guard let expirationDate else { return "On" }
            return "On until " + expirationDate.formatted(date: .omitted, time: .shortened)
        }
    }

    init(
        defaults: UserDefaults,
        activityManager: any SleepActivityManaging,
        now: @escaping () -> Date = Date.init,
        observesSystemNotifications: Bool = true
    ) {
        self.defaults = defaults
        self.activityManager = activityManager
        self.now = now
        if defaults.object(forKey: DefaultsKey.defaultDuration) == nil {
            defaultDuration = .defaultValue
        } else {
            defaultDuration = KeepAwakeDuration(
                storedValue: defaults.integer(forKey: DefaultsKey.defaultDuration)
            )
        }
        showsSeparateMenuBarIcon = defaults.bool(forKey: DefaultsKey.showsSeparateMenuBarIcon)

        if observesSystemNotifications {
            installSystemObservers()
        }
    }

    func invalidate() {
        stop()
        expirationTask?.cancel()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
        observers.removeAll()
    }

    @discardableResult
    func addObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            start(for: defaultDuration)
        }
    }

    func start(for duration: KeepAwakeDuration) {
        stop(notifying: false)
        activityToken = activityManager.beginPreventingIdleSleep(
            reason: "Keep Awake is enabled in Yorozu"
        )
        activeDuration = duration
        switch duration {
        case .untilTurnedOff:
            expirationDate = nil
        case let .minutes(value):
            let deadline = now().addingTimeInterval(TimeInterval(value * 60))
            expirationDate = deadline
            scheduleExpiration(at: deadline)
        }
        notifyObservers()
    }

    func stop() {
        stop(notifying: true)
    }

    func reconcileExpiration() {
        guard let expirationDate else { return }
        if expirationDate <= now() {
            stop()
        } else {
            scheduleExpiration(at: expirationDate)
        }
    }

    private func stop(notifying: Bool) {
        expirationTask?.cancel()
        expirationTask = nil
        if let activityToken {
            activityManager.endPreventingIdleSleep(activityToken)
        }
        let changed = activityToken != nil || activeDuration != nil || expirationDate != nil
        activityToken = nil
        activeDuration = nil
        expirationDate = nil
        if notifying, changed {
            notifyObservers()
        }
    }

    private func scheduleExpiration(at deadline: Date) {
        expirationTask?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        expirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.reconcileExpiration()
        }
    }

    private func installSystemObservers() {
        let wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcileExpiration() }
        }
        notificationTokens.append(wakeToken)

        let clockToken = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcileExpiration() }
        }
        notificationTokens.append(clockToken)
    }

    private func notifyObservers() {
        for observer in observers.values {
            observer()
        }
    }
}
