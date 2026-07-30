import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleLauncher = Self(
        "toggleLauncher",
        initial: .init(.space, modifiers: [.option])
    )
    static let openClipboardHistory = Self("openClipboardHistory")
    static let openSnippets = Self("openSnippets")
    static let openAliases = Self("openAliases")
}

struct AppShortcutDefinition: Identifiable {
    let id: String
    let title: String
    let detail: String
    let name: KeyboardShortcuts.Name
}

enum AppShortcutCatalog {
    static var settings: [AppShortcutDefinition] {
        [
            AppShortcutDefinition(
                id: "open-launcher",
                title: String(localized: "settings.shortcuts.open-launcher"),
                detail: String(localized: "settings.shortcuts.open-launcher-detail"),
                name: .toggleLauncher
            ),
            AppShortcutDefinition(
                id: "open-clipboard-history",
                title: "Open Clipboard History",
                detail: "Open clipboard history directly from anywhere.",
                name: .openClipboardHistory
            ),
            AppShortcutDefinition(
                id: "open-snippets",
                title: "Open Snippets",
                detail: "Open snippets directly from anywhere.",
                name: .openSnippets
            ),
            AppShortcutDefinition(
                id: "open-aliases",
                title: "Open Aliases",
                detail: "Open application aliases directly from anywhere.",
                name: .openAliases
            ),
        ]
    }

    @MainActor
    static func validation(
        for definition: AppShortcutDefinition,
        shortcut: KeyboardShortcuts.Shortcut
    ) -> KeyboardShortcuts.ValidationResult {
        if let conflict = settings.first(where: {
            $0.id != definition.id
                && KeyboardShortcuts.getShortcut(for: $0.name) == shortcut
        }) {
            return .disallow(
                reason: "This shortcut is already used by “\(conflict.title)”."
            )
        }
        return .allow
    }

    @MainActor
    static func reset() {
        KeyboardShortcuts.reset(settings.map(\.name))
    }
}
