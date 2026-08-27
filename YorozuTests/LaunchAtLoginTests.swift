import XCTest
@testable import Yorozu

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testEnabledStatusIsReflectedWithoutRegisteringAgain() {
        let service = TestLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testEnablingRegistersMainAppAndRefreshesStatus() {
        let service = TestLaunchAtLoginService(
            status: .notRegistered,
            statusAfterRegister: .enabled
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testApprovalRequiredRemainsEnabledAndCanOpenSystemSettings() {
        let service = TestLaunchAtLoginService(
            status: .notRegistered,
            statusAfterRegister: .requiresApproval
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        controller.openSystemSettings()

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.openSystemSettingsCallCount, 1)
    }

    func testDisablingUnregistersMainApp() {
        let service = TestLaunchAtLoginService(
            status: .enabled,
            statusAfterUnregister: .notRegistered
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
    }

    func testRegistrationFailureKeepsPreviousStateAndShowsRecoverableError() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.operationFailed
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(
            controller.errorMessage,
            "Yorozu couldn’t be added to Login Items."
        )
    }

    func testRefreshReadsExternalSystemSettingsChange() {
        let service = TestLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        service.status = .enabled
        controller.refresh()

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
    }
}

@MainActor
private final class TestLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var statusAfterRegister: LaunchAtLoginStatus
    var statusAfterUnregister: LaunchAtLoginStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    init(
        status: LaunchAtLoginStatus,
        statusAfterRegister: LaunchAtLoginStatus = .enabled,
        statusAfterUnregister: LaunchAtLoginStatus = .notRegistered
    ) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
        self.statusAfterUnregister = statusAfterUnregister
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = statusAfterUnregister
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

private enum TestError: Error {
    case operationFailed
}
