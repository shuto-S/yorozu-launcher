# Yorozu

Yorozu is a lightweight, keyboard-first launcher for macOS. It brings application launching, clipboard history, snippets, aliases, multi-provider AI chat, and settings into one native command palette.

> [!NOTE]
> Yorozu is an early, local-first development build for macOS 26 or later on Apple Silicon. The source repository is public. Release automation exists, but no packaged release is considered supported until the signed update path has passed the two-version verification gate.

## Features

- Application search and launch
- Pinning, aliases, and recent-use ranking
- Clipboard history for text, URLs, files, and images
- Snippet creation, search, copy, and paste
- Dedicated screens for Clipboard History, Snippets, Aliases, AI Chat, and Settings
- AI-assisted translation with configurable target language, provider, model, and reasoning level
- Root Search arithmetic for ASCII `+`, `-`, `*`, `/`, `%`, and parentheses
- Codex chat through the installed `codex app-server` and the user's ChatGPT plan
- OpenAI Responses API chat with streaming, Web Search, file inputs, and local title indexing
- Claude Messages API chat with streaming and local title indexing (enable it and add an Anthropic API key in Settings)
- Ollama chat with locally installed models discovered from the local Ollama service (enable it in Settings; no API key is required)
- Configurable global shortcuts
- Optional launch at login using the macOS Login Items service
- Optional Left/Right Command-alone input-mode switching for English and Japanese
- Optional modifier-drag window moving and bottom-right resizing
- Keyboard-first navigation with mouse support
- Japanese IME-safe command handling
- Native AppKit and SwiftUI interface
- Release-only Sparkle update checks with a GitHub Releases fallback

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

Input Mode Switching is disabled by default. Enable it from **Settings → General** to
use Left Command alone for English and Right Command alone for Japanese. It requires
macOS Input Monitoring permission. Yorozu then selects an enabled English or Japanese
input source directly through macOS rather than posting synthetic Eisu/Kana key events.
Command shortcuts and regular Command-clicks continue to work normally. Once enabled,
the listen-only monitor remains available while Yorozu is not the active application.

Window Control is also disabled by default. Configure two different modifier-key
combinations in **Settings → Window Control**, then hold one combination while dragging
with the left mouse button. Move and resize gestures use Accessibility, run only while
the feature is enabled, and allow normal idle system sleep.

When Root Search recognizes a supported arithmetic expression, the result is shown as a
copyable command. `Return` copies the result; the Action Panel also offers `Copy Result`
and `Copy Expression`. Natural-language arithmetic, Unicode operators, and division by
zero are intentionally not evaluated.

## Requirements

- macOS 26 or later
- Apple Silicon Mac
- Xcode 26 or later

## Quick start

Clone the repository and build the shared Debug configuration. The checked-in project
does not contain a personal Development Team and can be built with its ad-hoc Debug
defaults:

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

Automatic paste and Window Control use macOS Accessibility permission. Input Mode
Switching uses Input Monitoring. These TCC permissions are tied to the signed app
identity. Ad hoc signatures change between builds, so copy the signing template and
enter your own Apple Development Team when testing these features:

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

`Config/Local.xcconfig` is intentionally ignored by Git. Never commit personal signing identifiers or provisioning data.

After changing the signature, macOS may require you to remove a stale Yorozu entry from
the relevant Privacy & Security pane and add the current build again. Yorozu never changes
TCC data automatically. The General settings screen shows the current Input Monitoring
state for the running executable, links to the relevant System Settings pane, and can
reveal the exact build that must be authorized. An entry that is switched on for an older
Debug or ad hoc build does not authorize the current app.

Published updates keep `com.yorozu.app` and the same Developer ID team so macOS can retain
existing Accessibility and Input Monitoring grants. The release workflow rejects an
unexpected bundle ID, team, or cdhash-only designated requirement before publication.
Moving between a local Apple Development build and a published Developer ID build is an
identity change and can still require one intentional re-authorization.

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

The UI-test target must use its isolated test environment. It must not use the developer's
normal SQLite database, pasteboard, Keychain, application list, or network credentials.

## Local configuration

AI credentials are configured from Yorozu Settings and stored in the macOS Keychain. Do
not add API keys to source files, shell scripts, fixtures, screenshots, issue reports, or
commit messages. Codex authentication is delegated to the locally installed Codex
app-server; Yorozu does not read or export its tokens.

For stable Accessibility testing, use the ignored `Config/Local.xcconfig` described above.
The tracked `Config/Local.example.xcconfig` contains only a placeholder and is safe to
share. If the signing identity changes, macOS may require the current build to be
re-authorized in Privacy & Security → Accessibility.

## Privacy

Clipboard history and snippets are stored locally. Yorozu does not send clipboard or snippet content over the network. URL previews are optional because loading one can contact the linked website.

AI Chat and Translation are explicit. Codex is enabled by default and delegates ChatGPT
authentication and conversation content to the installed `codex app-server`; Yorozu never
reads or stores Codex tokens. The optional OpenAI API and Claude providers keep the user's
API keys in macOS Keychain and use their respective API billing. The optional Ollama
provider connects only to the default local Ollama service, discovers installed models on
the Mac, and does not require or store a credential. Network requests are created only
after the relevant feature is opened and used.

Yorozu stores only provider IDs, chat titles, model IDs, and list metadata in SQLite. AI
message bodies are sent only to the provider after an explicit user action and are not
written to the repository. Credentials, clipboard content, and snippet content are not
committed or attached automatically. Yorozu does not synchronize with ChatGPT history.
Ollama conversations are sent to the local Ollama installation and are not sent to a cloud
AI provider by Yorozu. Translation can read selected text only when the user invokes it
and macOS Accessibility permits that operation.

Clipboard history is local, disabled by default, and configurable by source application,
retention, and item limit. URL previews are opt-in and use bounded HTTP(S)-only fetching
with address, redirect, MIME, and payload checks; enabling previews can contact the
selected website.

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
- [RELEASING.md](RELEASING.md): Developer ID, notarization, Sparkle, and GitHub Releases/Appcast operations
- [AGENTS.md](AGENTS.md): repository constraints for coding agents

## Public repository hygiene

Before opening an issue or pull request, inspect the diff for local paths, runtime
databases, clipboard or snippet captures, screenshots, logs, Keychain exports, API keys,
access tokens, and signing or provisioning identifiers. The repository's ignore rules
cover common local artifacts, but an ignored file can still be added explicitly.

If a report may contain sensitive data, describe the problem without the value and use a
private GitHub security channel when available. Do not publish credentials or personal
data in a public issue.

No license has been selected yet. Until one is added, the source remains under its default copyright restrictions.
