import XCTest
@testable import Yorozu

final class SearchScorerTests: XCTestCase {
    func testNormalizationHandlesWidthCaseDiacriticsAndWhitespace() {
        XCTAssertEqual("  ＣＡＦÉ   App  ".launcherNormalized, "cafe app")
        XCTAssertEqual("ば".launcherNormalized, "は\u{3099}".launcherNormalized)
    }

    func testExactPrefixTokenAcronymSubstringAndFuzzyMatches() {
        let visualStudioCode = application(name: "Visual Studio Code")
        let code = application(name: "Code")
        let codeRunner = application(name: "Code Runner")
        let applications = [visualStudioCode, codeRunner, code]

        XCTAssertEqual(
            SearchScorer.rank(applications: applications, query: "code").first?.id,
            code.id
        )
        XCTAssertEqual(
            SearchScorer.rank(applications: [codeRunner], query: "code r").first?.id,
            codeRunner.id
        )
        XCTAssertEqual(
            SearchScorer.rank(applications: [visualStudioCode], query: "vis cod").first?.id,
            visualStudioCode.id
        )
        XCTAssertEqual(
            SearchScorer.rank(applications: [visualStudioCode], query: "vsc").first?.id,
            visualStudioCode.id
        )
        XCTAssertEqual(
            SearchScorer.rank(applications: [visualStudioCode], query: "studio").first?.id,
            visualStudioCode.id
        )
        XCTAssertEqual(
            SearchScorer.rank(applications: [visualStudioCode], query: "vsl").first?.id,
            visualStudioCode.id
        )
    }

    func testExactMatchBeatsFrequentlyUsedSubstring() {
        let exact = application(name: "Code")
        let frequent = application(
            name: "Visual Studio Code",
            preference: LauncherPreference(
                alias: nil,
                isPinned: true,
                pinnedAt: Date(),
                launchCount: 10_000,
                lastLaunchedAt: Date()
            )
        )

        let results = SearchScorer.rank(
            applications: [frequent, exact],
            query: "code"
        )

        XCTAssertEqual(results.first?.primaryName, "Code")
    }

    func testAliasParticipatesInSearch() {
        let application = application(
            name: "Visual Studio Code",
            preference: LauncherPreference(
                alias: "editor",
                isPinned: false,
                pinnedAt: nil,
                launchCount: 0,
                lastLaunchedAt: nil
            )
        )

        XCTAssertEqual(
            SearchScorer.rank(applications: [application], query: "editor").first?.id,
            application.id
        )
    }

    func testEmptyQueryOrdersPinnedThenRecentThenUnused() {
        let now = Date()
        let pinned = application(
            name: "Pinned",
            preference: LauncherPreference(
                alias: nil,
                isPinned: true,
                pinnedAt: now.addingTimeInterval(-10),
                launchCount: 1,
                lastLaunchedAt: now.addingTimeInterval(-1_000)
            )
        )
        let recent = application(
            name: "Recent",
            preference: LauncherPreference(
                alias: nil,
                isPinned: false,
                pinnedAt: nil,
                launchCount: 1,
                lastLaunchedAt: now
            )
        )
        let unused = application(name: "Unused")

        let results = SearchScorer.rank(
            applications: [unused, recent, pinned],
            query: "",
            now: now
        )

        XCTAssertEqual(results.map(\.primaryName), ["Pinned", "Recent", "Unused"])
    }

    func testSearchP95StaysUnderThirtyMillisecondsWithTwoThousandApplications() {
        let applications = (0..<2_000).map { application(name: "Application \($0)") }
        for _ in 0..<10 {
            _ = SearchScorer.rank(applications: applications, query: "app199")
        }

        var durations: [TimeInterval] = []
        durations.reserveCapacity(100)
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = SearchScorer.rank(applications: applications, query: "app199")
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }

        let sorted = durations.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        XCTAssertLessThan(p95, 0.030, "p95 was \(p95 * 1_000)ms")
    }

    func testAliasValidationTrimsAndRejectsEmptyAndOversizedValues() throws {
        XCTAssertEqual(try LauncherViewModel.validatedAlias("  editor \n"), "editor")
        XCTAssertThrowsError(try LauncherViewModel.validatedAlias(" \n "))
        XCTAssertThrowsError(
            try LauncherViewModel.validatedAlias(String(repeating: "a", count: 65))
        )
    }

    private func application(
        name: String,
        preference: LauncherPreference = .empty
    ) -> LaunchableApplication {
        LaunchableApplication(
            id: ApplicationIdentity(rawValue: "bundle:test.\(name.launcherNormalized)"),
            bundleIdentifier: "test.\(name.launcherNormalized)",
            canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            displayName: name,
            localizedName: nil,
            version: "1.0",
            preference: preference
        )
    }
}
