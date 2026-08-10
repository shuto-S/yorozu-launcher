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
            application.textFields["modal.alias.value"]
                .waitForExistence(timeout: 2)
        )
        application.buttons["modal.cancel"].click()
        XCTAssertTrue(
            application.descendants(matching: .any)["launcher.aliases"].exists
        )
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
    func testAISettingsUsesProviderTabsInsideExistingPanel() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = [
            "--ui-testing-settings",
            "--ui-testing-sticky",
            "--ui-testing-light",
            "--ui-testing-high-contrast",
            "--ui-testing-reduce-transparency",
            "--ui-testing-reduce-motion",
        ]
        application.launch()

        let settings = application.descendants(matching: .any)["launcher.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        let aiDestination = application
            .descendants(matching: .any)["settings.destination.ai"]
        XCTAssertTrue(aiDestination.waitForExistence(timeout: 2))
        aiDestination.click()

        XCTAssertTrue(
            application.popUpButtons["Default Provider"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            application.radioGroups["Provider"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            application.switches["Enable Codex"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(application.staticTexts["Connection"].exists)
        XCTAssertTrue(application.staticTexts["Chat Defaults"].exists)
        let providerForm = application.scrollViews.element(boundBy: 1)
        XCTAssertTrue(providerForm.exists)
        providerForm.swipeUp()
        let reasoningPicker = application.popUpButtons["Reasoning"]
        XCTAssertTrue(reasoningPicker.waitForExistence(timeout: 2))
        reasoningPicker.click()
        let highReasoning = application.menuItems["High"]
        XCTAssertTrue(highReasoning.waitForExistence(timeout: 2))
        highReasoning.click()
        XCTAssertEqual(reasoningPicker.value as? String, "High")

        let modelPicker = application.popUpButtons["Model"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 2))
        modelPicker.click()
        let fastModel = application.menuItems["Codex UI Fast"]
        XCTAssertTrue(fastModel.waitForExistence(timeout: 2))
        fastModel.click()
        XCTAssertEqual(modelPicker.value as? String, "Codex UI Fast")
        XCTAssertEqual(reasoningPicker.value as? String, "Model Default")
        XCTAssertTrue(application.staticTexts["Data and Billing"].exists)

        let openAITab = application.radioButtons["settings.ai.provider.openai_api"]
        XCTAssertTrue(openAITab.waitForExistence(timeout: 2))
        openAITab.click()
        XCTAssertTrue(
            application.switches["Enable OpenAI API"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(application.buttons["Test Connection"].exists)
        XCTAssertEqual(application.dialogs.count, 1)
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
    func testKeyboardSelectionKeepsEveryRootRowVisibleWhileMovingBothDirections() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let searchField = application.searchFields["launcher.search"]
        let footer = application.buttons["launcher.footer.primary"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(footer.waitForExistence(timeout: 2))

        for _ in 0..<25 {
            application.typeKey(.downArrow, modifierFlags: [])
            assertSelectedRootRowIsVisible(
                in: application,
                below: searchField,
                above: footer
            )
        }

        for _ in 0..<25 {
            application.typeKey(.upArrow, modifierFlags: [])
            assertSelectedRootRowIsVisible(
                in: application,
                below: searchField,
                above: footer
            )
        }
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
            .descendants(matching: .any)["modal.alias.application-search"]
        XCTAssertTrue(applicationSearch.waitForExistence(timeout: 2))
        applicationSearch.typeText("vsc")

        let codeCandidate = application
            .descendants(matching: .any)[
                "modal.alias.application.bundle:com.microsoft.vscode"
            ]
        XCTAssertTrue(codeCandidate.waitForExistence(timeout: 3))
        codeCandidate.click()
        application.buttons["modal.alias.continue"].click()

        let aliasField = application
            .descendants(matching: .any)["modal.alias.value"]
        XCTAssertTrue(aliasField.waitForExistence(timeout: 2))
        aliasField.click()
        aliasField.typeText("temporary")
        application.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(aliasField.waitForNonExistence(timeout: 2))
        XCTAssertTrue(aliases.exists)
    }

    @MainActor
    func testSnippetEditorUsesTheSharedInPaletteModal() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let rootSearch = application.searchFields["launcher.search"]
        XCTAssertTrue(rootSearch.waitForExistence(timeout: 5))
        rootSearch.typeText("snippets")
        application.typeKey(.return, modifierFlags: [])

        let newSnippet = application.buttons["launcher.footer.newSnippet"]
        XCTAssertTrue(newSnippet.waitForExistence(timeout: 2))
        newSnippet.click()

        let modal = application.descendants(matching: .any)["palette.modal"]
        XCTAssertTrue(modal.waitForExistence(timeout: 2))
        XCTAssertTrue(application.textFields["modal.snippet.name"].exists)
        XCTAssertTrue(application.textViews["modal.snippet.content"].exists)

        application.typeKey("k", modifierFlags: .command)
        XCTAssertFalse(
            application.descendants(matching: .any)["launcher.action-panel"].exists
        )

        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(modal.waitForNonExistence(timeout: 2))
        XCTAssertTrue(newSnippet.exists)
    }

    @MainActor
    func testAIChatUsesSinglePaneListAndConversationNavigation() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let rootSearch = application.searchFields["launcher.search"]
        XCTAssertTrue(rootSearch.waitForExistence(timeout: 5))
        rootSearch.typeText("AI Chat")

        let aiRow = application
            .descendants(matching: .any)["launcher.row.feature:aiChat.codex"]
        XCTAssertTrue(aiRow.waitForExistence(timeout: 2))
        aiRow.click()
        application.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            application.descendants(matching: .any)["launcher.ai"]
                .waitForExistence(timeout: 2)
        )
        let chatListSearch = application.searchFields["launcher.search"]
        XCTAssertTrue(chatListSearch.waitForExistence(timeout: 2))
        let conversationRow = application
            .descendants(matching: .any)["ai.chat-row.conversation-ui-test"]
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 2))
        conversationRow.doubleClick()

        XCTAssertTrue(
            application.descendants(matching: .any)["ai.composer"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(chatListSearch.exists)

        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(chatListSearch.waitForExistence(timeout: 2))
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(rootSearch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testActionPanelKeyboardSelectionKeepsEveryActionVisible() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let rootSearch = application.searchFields["launcher.search"]
        XCTAssertTrue(rootSearch.waitForExistence(timeout: 5))
        rootSearch.typeText("AI Chat")

        let aiRow = application
            .descendants(matching: .any)["launcher.row.feature:aiChat.codex"]
        XCTAssertTrue(aiRow.waitForExistence(timeout: 2))
        aiRow.click()
        application.typeKey(.return, modifierFlags: [])

        let conversationRow = application
            .descendants(matching: .any)["ai.chat-row.conversation-ui-test"]
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 2))
        conversationRow.doubleClick()
        XCTAssertTrue(
            application.descendants(matching: .any)["ai.composer"]
                .waitForExistence(timeout: 2)
        )

        application.typeKey("k", modifierFlags: .command)
        let actionPanel = application.descendants(matching: .any)["launcher.action-panel"]
        let actionSearch = application.textFields["launcher.action-search"]
        XCTAssertTrue(actionPanel.waitForExistence(timeout: 2))
        XCTAssertTrue(actionSearch.waitForExistence(timeout: 2))

        for _ in 0..<10 {
            application.typeKey(.downArrow, modifierFlags: [])
            assertSelectedActionIsVisible(
                in: application,
                inside: actionPanel,
                above: actionSearch
            )
        }

        for _ in 0..<10 {
            application.typeKey(.upArrow, modifierFlags: [])
            assertSelectedActionIsVisible(
                in: application,
                inside: actionPanel,
                above: actionSearch
            )
        }
    }

    @MainActor
    private func assertSelectedRootRowIsVisible(
        in application: XCUIApplication,
        below searchField: XCUIElement,
        above footer: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resultRows = application.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "launcher.row."
            )
        )
        guard let selectedRow = resultRows.allElementsBoundByIndex.first(
            where: \.isSelected
        ) else {
            XCTFail(
                "The selected result row is not visible.",
                file: file,
                line: line
            )
            return
        }

        let selectedFrame = selectedRow.frame
        XCTAssertGreaterThanOrEqual(
            selectedFrame.minY,
            searchField.frame.maxY - 1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            selectedFrame.maxY,
            footer.frame.minY + 1,
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertSelectedActionIsVisible(
        in application: XCUIApplication,
        inside actionPanel: XCUIElement,
        above actionSearch: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actions = application.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "launcher.action."
            )
        )
        guard let selectedAction = actions.allElementsBoundByIndex.first(
            where: \.isSelected
        ) else {
            XCTFail("The selected action is not visible.", file: file, line: line)
            return
        }

        XCTAssertGreaterThanOrEqual(
            selectedAction.frame.minY,
            actionPanel.frame.minY - 1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            selectedAction.frame.maxY,
            actionSearch.frame.minY + 1,
            file: file,
            line: line
        )
    }

}
