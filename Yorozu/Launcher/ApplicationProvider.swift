import Foundation

struct ApplicationProvider: CommandProvider {
    let id = CommandProviderID(rawValue: "applications")
    let catalog: ApplicationCatalog

    func search(query: SearchQuery, context: SearchContext) async -> [CommandResult] {
        await catalog.search(query: query.rawValue).map {
            CommandResult(
                id: CommandResultID(rawValue: "application:\($0.id.rawValue)"),
                kind: .application,
                title: $0.primaryName,
                subtitle: $0.subtitle,
                icon: .application($0.canonicalURL),
                score: 0,
                isPinned: $0.preference.isPinned,
                payload: .application($0)
            )
        }
    }

    func actions(for result: CommandResult) async -> [CommandAction] {
        [
            CommandAction(id: .open, title: "Open", systemImageName: "arrow.up.forward.app"),
            CommandAction(id: .togglePin, title: "Toggle Pin", systemImageName: "pin"),
            CommandAction(id: .editAlias, title: "Edit Alias", systemImageName: "character.cursor.ibeam"),
            CommandAction(id: .revealInFinder, title: "Show in Finder", systemImageName: "folder"),
        ]
    }

    func perform(action: CommandActionID, result: CommandResult) async throws {
        throw LauncherError.commandNotSupported
    }
}
