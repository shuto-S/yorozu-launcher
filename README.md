# Yorozu

Yorozu is a lightweight, keyboard-first launcher for macOS. It brings application launching, clipboard history, snippets, aliases, multi-provider AI chat, and settings into one native command palette.

> [!NOTE]
> Yorozu is an early development build for macOS 26 or later on Apple Silicon. There is no packaged release yet.

## Features

- Application search and launch
- Pinning, aliases, and recent-use ranking
- Clipboard history for text, URLs, files, and images
- Snippet creation, search, copy, and paste
- Dedicated screens for Clipboard History, Snippets, Aliases, AI Chat, and Settings
- Codex chat through the installed `codex app-server` and the user's ChatGPT plan
- OpenAI Responses API chat with streaming, Web Search, file inputs, and local title indexing
- Claude Messages API chat with streaming and local title indexing (enable it and add an Anthropic API key in Settings)
- Configurable global shortcuts
- Keyboard-first navigation with mouse support
- Japanese IME-safe command handling
- Native AppKit and SwiftUI interface

## Default controls

| Action | Shortcut |
|---|---|
| Open Yorozu | `⌥ Space` |
| Move selection | `↑` / `↓` |
| Run the primary action | `Return` |
| Open the Action Panel | `⌘ K` |
| Go back or close | `Esc` |
| Open Settings | `⌘ ,` |

Feature-specific global shortcuts can be configured in Settings.

## Requirements

- macOS 26 or later
- Apple Silicon Mac
- Xcode 26 or later

## Quick start

Clone the repository and build the shared Debug configuration:

The project builds ad hoc by default, so it does not require a personal Apple Development Team.

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Open the built app from Xcode's Products group or from the corresponding DerivedData `Build/Products/Debug` directory.

### Stable local signing

Automatic paste uses macOS Accessibility permission. Ad hoc signatures change between builds, so copy the signing template and enter your own Apple Development Team when testing paste behavior:

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

`Config/Local.xcconfig` is intentionally ignored by Git. Never commit personal signing identifiers or provisioning data.

After changing the signature, macOS may require you to remove the stale Yorozu entry from Privacy & Security → Accessibility and add the current build again. Yorozu never changes TCC data automatically.

## Validation

Run unit and integration tests independently from UI automation:

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:YorozuTests \
  test
```

UI tests require Xcode Automation permission and should be run with `-only-testing:YorozuUITests`.

## Privacy

Clipboard history and snippets are stored locally. Yorozu does not send clipboard or snippet content over the network. URL previews are optional because loading one can contact the linked website.

AI Chat is explicit. Codex is enabled by default and delegates ChatGPT authentication and conversation content to the installed `codex app-server`; Yorozu never reads or stores Codex tokens. The optional OpenAI API and Claude providers keep the user's API keys in macOS Keychain and use their respective API billing. Yorozu stores only provider IDs, chat titles, model IDs, and list metadata in SQLite. It does not synchronize with ChatGPT history and never attaches clipboard content automatically.

The repository intentionally excludes local visual QA captures and runtime databases because they can contain application names, URLs, or clipboard content.

Yorozu does not implement cloud sync, telemetry, or snippet auto-expansion in the current version.

## Project structure

```text
Yorozu/
├── App/        App lifecycle and shortcut registration
├── Core/       Shared models and search primitives
├── Launcher/   Catalogs, persistence, ranking, and view model
├── Platform/   AppKit, SwiftUI, pasteboard, windows, and settings
└── Resources/  Localization and icon assets

YorozuTests/
YorozuUITests/
```

## Development documentation

- [DEVELOPMENT.md](DEVELOPMENT.md): setup, architecture, validation, performance harnesses, and contribution hygiene
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md): current implementation status and roadmap
- [AGENTS.md](AGENTS.md): repository constraints for coding agents

No license has been selected yet. Until one is added, the source remains under its default copyright restrictions.
