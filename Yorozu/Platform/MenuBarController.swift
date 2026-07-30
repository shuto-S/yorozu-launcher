import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let viewModel: LauncherViewModel
    private let openPalette: () -> Void
    private let openSettings: () -> Void
    private var isRestarting = false

    init(
        viewModel: LauncherViewModel,
        openPalette: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.openPalette = openPalette
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
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

        let menu = NSMenu()
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
        menu.addItem(item(
            title: String(localized: "menu.settings"),
            symbol: "gearshape",
            keyEquivalent: ",",
            action: #selector(showSettings)
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
        statusItem.menu = menu
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

    @objc private func open() {
        openPalette()
    }

    @objc private func reindex() {
        Task {
            await viewModel.reindex()
        }
    }

    @objc func showSettings() {
        openSettings()
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
