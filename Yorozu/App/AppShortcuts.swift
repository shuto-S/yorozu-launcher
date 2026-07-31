import KeyboardShortcuts
import SwiftUI

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

}

@MainActor
final class AppShortcutSettings: ObservableObject {
    @Published private var shortcutsByID: [String: KeyboardShortcuts.Shortcut]
    private let usesIsolatedStorage: Bool

    init(usesIsolatedStorage: Bool = false) {
        self.usesIsolatedStorage = usesIsolatedStorage
        if usesIsolatedStorage {
            shortcutsByID = Self.defaultShortcuts
        } else {
            shortcutsByID = Dictionary(
                uniqueKeysWithValues: AppShortcutCatalog.settings.compactMap {
                    definition in
                    KeyboardShortcuts.getShortcut(for: definition.name).map {
                        (definition.id, $0)
                    }
                }
            )
        }
    }

    func binding(
        for definition: AppShortcutDefinition
    ) -> Binding<KeyboardShortcuts.Shortcut?> {
        Binding(
            get: { [weak self] in
                self?.shortcutsByID[definition.id]
            },
            set: { [weak self] shortcut in
                self?.set(shortcut, for: definition)
            }
        )
    }

    func validation(
        for definition: AppShortcutDefinition,
        shortcut: KeyboardShortcuts.Shortcut
    ) -> KeyboardShortcuts.ValidationResult {
        if let conflict = AppShortcutCatalog.settings.first(where: {
            $0.id != definition.id
                && shortcutsByID[$0.id] == shortcut
        }) {
            return .disallow(
                reason: "This shortcut is already used by “\(conflict.title)”."
            )
        }
        return .allow
    }

    func reset() {
        if usesIsolatedStorage {
            shortcutsByID = Self.defaultShortcuts
            return
        }
        KeyboardShortcuts.reset(AppShortcutCatalog.settings.map(\.name))
        reloadFromProductionStorage()
    }

    private func set(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        for definition: AppShortcutDefinition
    ) {
        shortcutsByID[definition.id] = shortcut
        if !usesIsolatedStorage {
            KeyboardShortcuts.setShortcut(shortcut, for: definition.name)
        }
    }

    private func reloadFromProductionStorage() {
        shortcutsByID = Dictionary(
            uniqueKeysWithValues: AppShortcutCatalog.settings.compactMap {
                definition in
                KeyboardShortcuts.getShortcut(for: definition.name).map {
                    (definition.id, $0)
                }
            }
        )
    }

    private static let defaultShortcuts: [String: KeyboardShortcuts.Shortcut] = [
        "open-launcher": .init(.space, modifiers: [.option]),
    ]
}
