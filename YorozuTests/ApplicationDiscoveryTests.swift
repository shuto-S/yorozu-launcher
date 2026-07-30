import XCTest
@testable import Yorozu

final class ApplicationDiscoveryTests: XCTestCase {
    func testPreferredLaunchServicesURLWinsDuplicateResolution() {
        let system = discovered(path: "/System/Applications/Example.app", priority: 2)
        let user = discovered(path: "/Users/test/Applications/Example.app", priority: 0)

        let selected = FileSystemApplicationDiscoverer.selectCandidate(
            [system, user],
            preferredURL: system.canonicalURL
        )

        XCTAssertEqual(selected?.canonicalURL, system.canonicalURL)
    }

    func testUserApplicationsWinsWhenNoPreferredURLExists() {
        let system = discovered(path: "/System/Applications/Example.app", priority: 2)
        let user = discovered(path: "/Users/test/Applications/Example.app", priority: 0)

        let selected = FileSystemApplicationDiscoverer.selectCandidate(
            [system, user],
            preferredURL: nil
        )

        XCTAssertEqual(selected?.canonicalURL, user.canonicalURL)
    }

    func testRecursiveScanIncludesValidAppsAndExcludesOwnHiddenAndBrokenApps() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Utilities", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        try makeApplicationFixture(
            at: root.appendingPathComponent("Utilities/Valid.app", isDirectory: true),
            bundleIdentifier: "com.example.valid"
        )
        try makeApplicationFixture(
            at: root.appendingPathComponent("Yorozu.app", isDirectory: true),
            bundleIdentifier: "com.yorozu.app"
        )
        try makeApplicationFixture(
            at: root.appendingPathComponent(".Hidden.app", isDirectory: true),
            bundleIdentifier: "com.example.hidden"
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Broken.app/Contents", isDirectory: true),
            withIntermediateDirectories: true
        )

        let discoverer = FileSystemApplicationDiscoverer(
            ownBundleIdentifier: "com.yorozu.app",
            roots: [(root, 0)]
        )
        let applications = try await discoverer.discoverApplications()

        XCTAssertEqual(applications.map(\.bundleIdentifier), ["com.example.valid"])
    }

    private func discovered(path: String, priority: Int) -> DiscoveredApplication {
        DiscoveredApplication(
            id: ApplicationIdentity(rawValue: "bundle:test.example"),
            bundleIdentifier: "test.example",
            canonicalURL: URL(fileURLWithPath: path),
            displayName: "Example",
            localizedName: nil,
            version: "1.0",
            normalizedSearchText: "example test.example",
            rootPriority: priority
        )
    }

    private func makeApplicationFixture(
        at applicationURL: URL,
        bundleIdentifier: String
    ) throws {
        let contents = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executables,
            withIntermediateDirectories: true
        )

        let executableName = "Fixture"
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": applicationURL.deletingPathExtension().lastPathComponent,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = executables.appendingPathComponent(executableName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }
}
