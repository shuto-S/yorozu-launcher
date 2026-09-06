import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem: NSStatusItem
    private var keepAwakeStatusItem: NSStatusItem?
    private let viewModel: LauncherViewModel
    private let keepAwakeController: KeepAwakeController
    private let appUpdateController: AppUpdateController?
    private let openPalette: () -> Void
    private let openSettings: () -> Void
    private var keepAwakeObserverID: UUID?
    private var isRestarting = false

    init(
        viewModel: LauncherViewModel,
        keepAwakeController: KeepAwakeController? = nil,
        appUpdateController: AppUpdateController? = nil,
        openPalette: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.keepAwakeController = keepAwakeController ?? viewModel.keepAwakeController
        self.appUpdateController = appUpdateController
        self.openPalette = openPalette
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        keepAwakeObserverID = self.keepAwakeController.addObserver { [weak self] in
            self?.synchronizeKeepAwakeStatusItem()
        }
        synchronizeKeepAwakeStatusItem()
    }

    private func configureStatusItem() {
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: "Yorozu"
            )
        }
        statusItem.button?.setAccessibilityLabel("Yorozu")
        statusItem.menu = makeMainMenu()
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        rebuildMainMenu(menu)
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return appUpdateController?.canCheckForUpdates == true
        }
        return true
    }

    private func rebuildMainMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(
            title: String(localized: "menu.open"),
            symbol: "macwindow.on.rectangle",
            action: #selector(open)
        ))
        menu.addItem(item(
            title: String(localized: "menu.reindex"),
            symbol: "arrow.clockwise",
            action: #selector(reindex)
        ))
        menu.addItem(.separator())
        menu.addItem(keepAwakeMenuItem())
        menu.addItem(.separator())
        menu.addItem(item(
            title: String(localized: "menu.settings"),
            symbol: "gearshape",
            keyEquivalent: ",",
            action: #selector(showSettings)
        ))
        let checkForUpdatesItem = item(
            title: String(localized: "menu.check-for-updates"),
            symbol: "arrow.down.circle",
            action: #selector(checkForUpdates)
        )
        checkForUpdatesItem.isEnabled = appUpdateController?.canCheckForUpdates == true
        menu.addItem(checkForUpdatesItem)
        menu.addItem(item(
            title: String(localized: "menu.view-latest-release"),
            symbol: "safari",
            action: #selector(viewLatestRelease)
        ))
        menu.addItem(item(
            title: String(localized: "menu.restart"),
            symbol: "arrow.triangle.2.circlepath",
            action: #selector(restart)
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            title: String(localized: "menu.quit"),
            symbol: "xmark.circle",
            keyEquivalent: "q",
            action: #selector(quit)
        ))
    }

    private func keepAwakeMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(
            title: "Keep Awake: \(keepAwakeController.isActive ? "On" : "Off")",
            action: nil,
            keyEquivalent: ""
        )
        parent.image = keepAwakeImage()
        parent.submenu = makeKeepAwakeMenu()
        return parent
    }

    private func makeKeepAwakeMenu() -> NSMenu {
        let menu = NSMenu(title: "Keep Awake")
        let toggleTitle = keepAwakeController.isActive
            ? "Turn Off"
            : "Turn On for \(keepAwakeController.defaultDuration.title)"
        menu.addItem(item(
            title: toggleTitle,
            symbol: keepAwakeController.isActive
                ? "cup.and.saucer"
                : "cup.and.saucer.fill",
            action: #selector(toggleKeepAwake)
        ))
        menu.addItem(.separator())

        let durationItem = NSMenuItem(
            title: "Start for Duration",
            action: nil,
            keyEquivalent: ""
        )
        durationItem.image = NSImage(
            systemSymbolName: "timer",
            accessibilityDescription: "Start for Duration"
        )
        let durationMenu = NSMenu(title: "Start for Duration")
        for duration in KeepAwakeDuration.choices {
            let item = NSMenuItem(
                title: duration.title,
                action: #selector(startKeepAwakeForDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = duration.storedValue
            item.state = keepAwakeController.activeDuration == duration ? .on : .off
            durationMenu.addItem(item)
        }
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)
        return menu
    }

    private func item(
        title: String,
        symbol: String,
        keyEquivalent: String = "",
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func synchronizeKeepAwakeStatusItem() {
        if keepAwakeController.showsSeparateMenuBarIcon {
            if keepAwakeStatusItem == nil {
                keepAwakeStatusItem = NSStatusBar.system.statusItem(
                    withLength: NSStatusItem.squareLength
                )
            }
            keepAwakeStatusItem?.button?.image = keepAwakeImage()
            keepAwakeStatusItem?.button?.setAccessibilityLabel(
                "Keep Awake \(keepAwakeController.isActive ? "On" : "Off")"
            )
            keepAwakeStatusItem?.menu = makeKeepAwakeMenu()
        } else if let keepAwakeStatusItem {
            NSStatusBar.system.removeStatusItem(keepAwakeStatusItem)
            self.keepAwakeStatusItem = nil
        }
    }

    private func keepAwakeImage() -> NSImage? {
        let description = keepAwakeController.isActive ? "Keep Awake On" : "Keep Awake Off"
        let image = NSImage(
            systemSymbolName: keepAwakeController.isActive
                ? "cup.and.saucer.fill"
                : "cup.and.saucer",
            accessibilityDescription: description
        )
        image?.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu {
            rebuildMainMenu(menu)
        }
    }

    @objc private func open() { openPalette() }

    @objc private func reindex() {
        Task { await viewModel.reindex() }
    }

    @objc func showSettings() { openSettings() }

    @objc private func checkForUpdates() {
        appUpdateController?.checkForUpdates()
    }

    @objc private func viewLatestRelease() {
        if let appUpdateController {
            appUpdateController.openLatestRelease()
        } else {
            NSWorkspace.shared.open(AppUpdateController.latestReleaseURL)
        }
    }

    @objc private func toggleKeepAwake() {
        keepAwakeController.toggle()
    }

    @objc private func startKeepAwakeForDuration(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        keepAwakeController.start(for: KeepAwakeDuration(storedValue: value))
    }

    @objc private func restart() {
        guard !isRestarting else { return }
        isRestarting = true

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] application, error in
            let startedNewProcess = error == nil
                && application?.processIdentifier != currentProcessIdentifier
            Task { @MainActor [weak self] in
                self?.isRestarting = false
                if startedNewProcess {
                    NSApp.terminate(nil)
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
