import XCTest

final class YorozuUITests: XCTestCase {
    @MainActor
    func testLauncherShowsSearchField() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        XCTAssertTrue(
            application.searchFields["launcher.search"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(application.buttons["launcher.footer.primary"].exists)
        XCTAssertTrue(application.buttons["launcher.footer.actions"].exists)
    }

    @MainActor
    func testSearchAndAliasEditorFromActionMenu() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let searchField = application.searchFields["launcher.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("vsc")

        let codeRow = application
            .descendants(matching: .any)["launcher.row.application:bundle:com.microsoft.vscode"]
        XCTAssertTrue(codeRow.waitForExistence(timeout: 5))
        let codeRowFrame = codeRow.frame

        application.typeKey("k", modifierFlags: .command)
        let actionPanel = application.descendants(matching: .any)["launcher.action-panel"]
        let openAction = application.buttons["launcher.action.open"]
        let editAlias = application.buttons["launcher.action.editAlias"]
        XCTAssertTrue(actionPanel.waitForExistence(timeout: 2))
        XCTAssertTrue(openAction.waitForExistence(timeout: 2))
        XCTAssertTrue(editAlias.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(openAction.frame.minX, codeRowFrame.midX)

        let actionSearch = application.textFields["launcher.action-search"]
        XCTAssertTrue(actionSearch.waitForExistence(timeout: 2))
        actionSearch.click()
        actionSearch.typeText("edit")
        XCTAssertEqual(actionSearch.value as? String, "edit")
        XCTAssertEqual(searchField.value as? String, "vsc")

        let filteredEditAlias = application.buttons["launcher.action.editAlias"]
        XCTAssertTrue(filteredEditAlias.waitForExistence(timeout: 2))
        filteredEditAlias.click()

        XCTAssertTrue(actionPanel.waitForNonExistence(timeout: 2))
        XCTAssertTrue(actionSearch.waitForNonExistence(timeout: 2))
        XCTAssertTrue(
            application.textFields["aliases.alias-field"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            application.descendants(matching: .any)["launcher.aliases"].exists
        )

        application.buttons["aliases.cancel"].click()
        XCTAssertTrue(application.searchFields["launcher.search"].exists)
    }

    @MainActor
    func testSettingsExposeLauncherShortcut() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing-settings", "--ui-testing-sticky"]
        application.launch()

        let settings = application.descendants(matching: .any)["launcher.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(application.dialogs.count, 1)
        XCTAssertFalse(application.searchFields["launcher.search"].exists)

        let general = application
            .descendants(matching: .any)["settings.destination.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 2))
        general.click()
        application.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            application.staticTexts["Recording"].waitForExistence(timeout: 2)
        )
        let accessibilityStatus: String
        if application.staticTexts["Allowed"].exists {
            accessibilityStatus = "Allowed"
        } else if application.staticTexts["Not Allowed"].exists {
            accessibilityStatus = "Not Allowed"
        } else {
            accessibilityStatus = "Missing"
        }
        XCTContext.runActivity(
            named: "Current process Accessibility: \(accessibilityStatus)"
        ) { _ in
            XCTAssertNotEqual(accessibilityStatus, "Missing")
        }

        let shortcuts = application
            .descendants(matching: .any)["settings.destination.shortcuts"]
        shortcuts.click()
        XCTAssertTrue(application.staticTexts["Open Yorozu"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            application.staticTexts["Show or hide the launcher from anywhere."].exists
        )
        XCTAssertTrue(application.staticTexts["Open Clipboard History"].exists)
        XCTAssertTrue(application.staticTexts["Open Snippets"].exists)
        XCTAssertTrue(application.staticTexts["Open Aliases"].exists)

        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settings.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testRootSettingsRouteReturnsToRootOnEscape() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let searchField = application.searchFields["launcher.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("settings")

        let settingsRow = application
            .descendants(matching: .any)["launcher.row.feature:settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 2))
        application.typeKey(.return, modifierFlags: [])

        let settings = application.descendants(matching: .any)["launcher.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        XCTAssertEqual(application.dialogs.count, 1)
        XCTAssertFalse(searchField.exists)

        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        XCTAssertTrue(settings.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testCommandCommaShowsSettingsInTheExistingPanel() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        XCTAssertTrue(
            application.searchFields["launcher.search"].waitForExistence(timeout: 5)
        )
        application.typeKey(",", modifierFlags: .command)

        let settings = application.descendants(matching: .any)["launcher.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        XCTAssertEqual(application.dialogs.count, 1)

        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settings.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testFeatureTransitionClearsActiveSearchEditor() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let searchField = application.searchFields["launcher.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("snippets")

        let snippetsRow = application
            .descendants(matching: .any)["launcher.row.feature:snippets"]
        XCTAssertTrue(snippetsRow.waitForExistence(timeout: 2))
        application.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        searchField.typeText("x")
        XCTAssertEqual(searchField.value as? String, "x")
    }

    @MainActor
    func testReducedTransparencyAndMotionKeepPaletteUsable() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = [
            "--ui-testing",
            "--ui-testing-sticky",
            "--ui-testing-dark",
            "--ui-testing-high-contrast",
            "--ui-testing-reduce-transparency",
            "--ui-testing-reduce-motion",
        ]
        application.launch()

        let searchField = application.searchFields["launcher.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("vsc")
        XCTAssertEqual(searchField.value as? String, "vsc")

        application.typeKey("k", modifierFlags: .command)
        let actionPanel = application.descendants(matching: .any)["launcher.action-panel"]
        XCTAssertTrue(actionPanel.waitForExistence(timeout: 2))
        let actionSearch = application.textFields["launcher.action-search"]
        XCTAssertTrue(actionSearch.waitForExistence(timeout: 2))
        actionSearch.typeText("edit")
        XCTAssertEqual(actionSearch.value as? String, "edit")

        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(actionPanel.waitForNonExistence(timeout: 2))
        searchField.typeText("s")
        XCTAssertEqual(searchField.value as? String, "vscs")
    }

    @MainActor
    func testAliasesTwoPaneAddFlowSupportsMouseAndKeyboard() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let rootSearch = application.searchFields["launcher.search"]
        XCTAssertTrue(rootSearch.waitForExistence(timeout: 5))
        rootSearch.typeText("aliases")

        let aliasesRow = application
            .descendants(matching: .any)["launcher.row.feature:aliases"]
        XCTAssertTrue(aliasesRow.waitForExistence(timeout: 2))
        aliasesRow.doubleClick()

        let aliases = application.descendants(matching: .any)["launcher.aliases"]
        XCTAssertTrue(aliases.waitForExistence(timeout: 2))
        XCTAssertTrue(
            application.buttons["launcher.footer.addAlias"]
                .waitForExistence(timeout: 2)
        )

        application.buttons["launcher.footer.addAlias"].click()
        let applicationSearch = application
            .descendants(matching: .any)["aliases.application-search"]
        XCTAssertTrue(applicationSearch.waitForExistence(timeout: 2))
        applicationSearch.typeText("vsc")

        let codeCandidate = application
            .descendants(matching: .any)[
                "aliases.application.bundle:com.microsoft.vscode"
            ]
        XCTAssertTrue(codeCandidate.waitForExistence(timeout: 3))
        codeCandidate.click()
        application.buttons["aliases.continue"].click()

        let aliasField = application
            .descendants(matching: .any)["aliases.alias-field"]
        XCTAssertTrue(aliasField.waitForExistence(timeout: 2))
        aliasField.click()
        aliasField.typeText("temporary")
        application.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(aliasField.waitForNonExistence(timeout: 2))
        XCTAssertTrue(aliases.exists)
    }

}
