import AppKit
import Foundation

@MainActor
final class WorkspaceApplicationLauncher: ApplicationLaunching {
    func launch(_ application: LaunchableApplication) async throws {
        guard FileManager.default.fileExists(atPath: application.canonicalURL.path) else {
            throw LauncherError.applicationUnavailable(application.primaryName)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: application.canonicalURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func revealInFinder(_ application: LaunchableApplication) {
        NSWorkspace.shared.activateFileViewerSelecting([application.canonicalURL])
    }
}
