import XCTest

final class YorozuUITests: XCTestCase {
    @MainActor
    func testRootKeyboardScrollReversesWithoutJumping() {
        verifyKeyboardScroll(routeSearch: nil, idPrefix: "application:bundle:test.yorozu.scroll.")
    }

    @MainActor
    func testClipboardKeyboardScrollReversesWithoutJumping() {
        verifyKeyboardScroll(routeSearch: "Clipboard History", idPrefix: "clipboard:")
    }

    @MainActor
    func testActionPanelKeyboardScrollReversesWithoutJumping() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()
        let search = application.searchFields["launcher.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Keep Awake")
        XCTAssertTrue(application.descendants(matching: .any)["launcher.row.feature:keepAwake"].waitForExistence(timeout: 5))
        application.typeKey("k", modifierFlags: .command)
        let duration = application.buttons["launcher.action.keepAwakeSetDuration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 2))
        duration.click()
        let viewport = application.scrollViews.element(boundBy: 1)
        func row(_ index: Int) -> XCUIElement {
            application.buttons["launcher.action.keepAwakeDuration.\(index * 5)"]
        }
        XCTAssertTrue(row(0).waitForExistence(timeout: 2))
        for index in 1...24 {
            application.typeKey(.downArrow, modifierFlags: [])
            assertFullyVisible(row(index), in: viewport)
        }
        for index in stride(from: 23, through: 0, by: -1) {
            let before = row(index).frame
            let wasVisible = viewport.frame.insetBy(dx: -1, dy: -1).contains(before)
            application.typeKey(.upArrow, modifierFlags: [])
            assertFullyVisible(row(index), in: viewport)
            if wasVisible {
                XCTAssertEqual(row(index).frame.minY, before.minY, accuracy: 1)
            }
        }
        application.terminate()
    }

    @MainActor
    private func verifyKeyboardScroll(routeSearch: String?, idPrefix: String) {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky", "--ui-testing-scroll"]
        application.launch()
        let search = application.searchFields["launcher.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if let routeSearch {
            search.typeText(routeSearch)
            let featureID = routeSearch == "Snippets" ? "snippets" : "clipboardHistory"
            XCTAssertTrue(application.descendants(matching: .any)["launcher.row.feature:\(featureID)"].waitForExistence(timeout: 5))
            application.typeKey(.return, modifierFlags: [])
        }
        search.click()
        search.typeText("Scroll Fixture")
        let viewport = application.scrollViews.firstMatch
        func row(_ index: Int) -> XCUIElement {
            let suffix = routeSearch == nil
                ? String(index)
                : String(format: "00000000-0000-0000-0000-%012d", index + 1)
            return application.descendants(matching: .any)["launcher.row.\(idPrefix)\(suffix)"]
        }
        XCTAssertTrue(row(0).waitForExistence(timeout: 5))
        let lastIndex = routeSearch == nil ? 19 : 24
        for index in 1...lastIndex {
            application.typeKey(.downArrow, modifierFlags: [])
            assertFullyVisible(row(index), in: viewport)
        }
        for index in stride(from: lastIndex - 1, through: 0, by: -1) {
            let before = row(index).frame
            let wasVisible = viewport.frame.insetBy(dx: -1, dy: -1).contains(before)
            application.typeKey(.upArrow, modifierFlags: [])
            assertFullyVisible(row(index), in: viewport)
            if wasVisible {
                XCTAssertEqual(row(index).frame.minY, before.minY, accuracy: 1,
                               "An already-visible row must not jump to the top edge")
            }
        }
        application.terminate()
    }

    @MainActor
    private func assertFullyVisible(_ row: XCUIElement, in viewport: XCUIElement) {
        let predicate = NSPredicate { _, _ in
            row.exists && !row.frame.isEmpty
                && viewport.frame.insetBy(dx: -1, dy: -1).contains(row.frame)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 2), .completed)
    }

    @MainActor
    func testSettingsRemainVisibleWhenApplicationDeactivates() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing-settings"]
        application.launch()

        let settings = application.descendants(matching: .any)["launcher.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()

        XCTAssertTrue(settings.waitForExistence(timeout: 2))
    }

    @MainActor
    func testRootPaletteClosesWhenApplicationDeactivates() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing"]
        application.launch()

        let searchField = application.searchFields["launcher.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()

        XCTAssertTrue(searchField.waitForNonExistence(timeout: 2))
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
    func testWindowControlSettingsExposeSafeDisabledConfiguration() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = [
            "--ui-testing-settings",
            "--ui-testing-sticky",
        ]
        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["launcher.settings"]
                .waitForExistence(timeout: 5)
        )

        let destination = application
            .descendants(matching: .any)[
                "settings.destination.windowControl"
            ]
        XCTAssertTrue(destination.waitForExistence(timeout: 2))
        destination.click()

        let moveRecorder = application.buttons["settings.window-control.move-recorder"]
        let resizeRecorder = application.buttons["settings.window-control.resize-recorder"]
        XCTAssertTrue(moveRecorder.waitForExistence(timeout: 2))
        XCTAssertTrue(resizeRecorder.exists)
        XCTAssertTrue(moveRecorder.isEnabled)
        XCTAssertTrue(resizeRecorder.isEnabled)
        XCTAssertEqual(moveRecorder.label, "Move Window Key Combination")
        XCTAssertEqual(resizeRecorder.label, "Resize Window Key Combination")
        XCTAssertEqual(moveRecorder.value as? String, "⌃")
        XCTAssertEqual(resizeRecorder.value as? String, "⌃⌘")
        for operation in ["move", "resize"] {
            let clear = application.buttons["settings.window-control.\(operation)-clear"]
            XCTAssertTrue(clear.exists)
            XCTAssertTrue(clear.isEnabled)
        }

        let enableToggle = application.switches[
            "settings.window-control.enabled"
        ]
        XCTAssertTrue(enableToggle.exists)
        XCTAssertTrue(enableToggle.isEnabled)
        XCTAssertTrue(application.staticTexts["Off"].exists)
        XCTAssertTrue(application.staticTexts["Not Allowed"].exists)
        application.buttons["settings.window-control.move-clear"].click()
        XCTAssertEqual(moveRecorder.value as? String, "Not Set")
        XCTAssertFalse(enableToggle.isEnabled)
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
        let appleTab = application.radioButtons["settings.ai.provider.apple_intelligence"]
        XCTAssertTrue(appleTab.waitForExistence(timeout: 2))
        appleTab.click()
        XCTAssertTrue(application.switches["Enable Apple Intelligence"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.staticTexts["Apple Intelligence is available"].waitForExistence(timeout: 2))
        XCTAssertEqual(application.dialogs.count, 1)
    }

    @MainActor
    func testAppleIntelligenceCanBeEnabledAndOpenedFromRoot() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()
        let search = application.searchFields["launcher.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Settings")
        application.typeKey(.return, modifierFlags: [])
        let ai = application.descendants(matching: .any)["settings.destination.ai"]
        XCTAssertTrue(ai.waitForExistence(timeout: 3))
        ai.click()
        let tab = application.radioButtons["settings.ai.provider.apple_intelligence"]
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        tab.click()
        let enabled = application.switches["Enable Apple Intelligence"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3))
        enabled.click()
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        application.typeKey("a", modifierFlags: .command)
        search.typeText("AI Chat: Apple Intelligence")
        let row = application.descendants(matching: .any)["launcher.row.feature:aiChat.apple_intelligence"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        application.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(application.buttons["ai.chat-row.__yorozu_new_chat__"].waitForExistence(timeout: 3))
        XCTAssertEqual(application.staticTexts["ai.empty-description"].value as? String, "Chats are kept only until Yorozu quits.")
        application.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(application.textViews["ai.composer"].waitForExistence(timeout: 3))
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
    func testTranslationFocusesInputWhenOpened() {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing", "--ui-testing-sticky"]
        application.launch()

        let rootSearch = application.searchFields["launcher.search"]
        XCTAssertTrue(rootSearch.waitForExistence(timeout: 5))
        rootSearch.typeText("translate")
        application.typeKey(.return, modifierFlags: [])

        let input = application.textViews["translation.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        application.typeText("Focus check")
        XCTAssertEqual(input.value as? String, "Focus check")
    }

}
