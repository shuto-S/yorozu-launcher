import XCTest
@testable import Yorozu

final class ApplicationDiscoveryTests: XCTestCase {
    func testStandardRootsIncludeCryptexApplications() {
        let expected = URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications")
            .resolvingSymlinksInPath().standardizedFileURL
        XCTAssertTrue(FileSystemApplicationDiscoverer.standardRoots().contains {
            $0.url.resolvingSymlinksInPath().standardizedFileURL == expected
        })
    }

    func testHiddenApplicationLinkCanBeFoundThroughVisibleTargetRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applications = root.appendingPathComponent("Applications")
        let system = root.appendingPathComponent("Cryptex/Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let target = system.appendingPathComponent("Browser.app")
        try makeApplicationFixture(at: target, bundleIdentifier: "test.cryptex.browser")
        try makeApplicationFixture(at: system.appendingPathComponent(".Hidden.app"), bundleIdentifier: "test.hidden")
        try FileManager.default.createSymbolicLink(at: applications.appendingPathComponent(".Browser.app"), withDestinationURL: target)
        let discoverer = FileSystemApplicationDiscoverer(roots: [(applications, 1), (system, 3)])
        let found = try await discoverer.discoverApplications()
        XCTAssertEqual(found.map(\.bundleIdentifier), ["test.cryptex.browser"])
    }

    func testPreferredLaunchServicesURLWinsDuplicateResolution() {
        let system = discovered(path: "/System/Applications/Example.app", priority: 2)
        let user = discovered(path: "/Users/test/Applications/Example.app", priority: 0)

        let selected = FileSystemApplicationDiscoverer.selectCandidate(
            [system, user],
            preferredURL: system.canonicalURL
        )

        XCTAssertEqual(selected?.canonicalURL, system.canonicalURL)
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

    func testApplicationDirectoryMonitorReportsApplicationChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let reportedChange = expectation(description: "Application directory changed")
        let oneShot = OneShotExpectation(reportedChange)
        let monitor = ApplicationDirectoryMonitor(
            roots: [root],
            latency: 0.05
        ) {
            oneShot.fulfill()
        }
        XCTAssertTrue(monitor.start())
        defer { monitor.stop() }

        try makeApplicationFixture(
            at: root.appendingPathComponent("New.app", isDirectory: true),
            bundleIdentifier: "com.example.new"
        )

        wait(for: [reportedChange], timeout: 3)
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

private final class OneShotExpectation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var hasFulfilled = false

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFulfilled else { return }
        hasFulfilled = true
        expectation.fulfill()
    }
}
