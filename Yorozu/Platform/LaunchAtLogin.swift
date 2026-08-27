import AppKit
import Observation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable

    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }

    var title: String {
        switch self {
        case .notRegistered:
            "Off"
        case .enabled:
            "On"
        case .requiresApproval:
            "Approval Required"
        case .unavailable:
            "Unavailable"
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class InMemoryLaunchAtLoginService: LaunchAtLoginServicing {
    private(set) var status: LaunchAtLoginStatus

    init(status: LaunchAtLoginStatus = .notRegistered) {
        self.status = status
    }

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .notRegistered
    }

    func openSystemSettings() {}
}

@MainActor
@Observable
final class LaunchAtLoginController {
    private let service: any LaunchAtLoginServicing

    private(set) var status: LaunchAtLoginStatus
    private(set) var isUpdating = false
    private(set) var errorMessage: String?

    var isEnabled: Bool { status.isRequested }

    init(
        service: any LaunchAtLoginServicing,
        initialStatus: LaunchAtLoginStatus? = nil
    ) {
        self.service = service
        status = initialStatus ?? service.status
    }

    static func disabled() -> LaunchAtLoginController {
        LaunchAtLoginController(service: InMemoryLaunchAtLoginService())
    }

    func setEnabled(_ isEnabled: Bool) {
        guard !isUpdating, isEnabled != status.isRequested else { return }

        isUpdating = true
        errorMessage = nil
        defer {
            status = service.status
            isUpdating = false
        }

        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = isEnabled
                ? "Yorozu couldn’t be added to Login Items."
                : "Yorozu couldn’t be removed from Login Items."
        }
    }

    func refresh() {
        status = service.status
        if status != .unavailable {
            errorMessage = nil
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
