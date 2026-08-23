# Yorozu Implementation Status and Roadmap

Last updated: 2026-08-23

## Product direction

Yorozu is a lightweight native command palette for macOS. It aims to keep frequent
application, clipboard, text-reuse, translation, calculation, and AI workflows fast
without requiring a browser engine, background network service, or extension runtime.

The repository is public, but the product is still an early local-first private-dogfood
build. Public source availability does not imply a packaged release, API stability, or
support for third-party deployment.

The current target is:

- macOS 26 or later
- Apple Silicon only
- Swift 6 with strict concurrency
- AppKit for macOS lifecycle and platform integration
- SwiftUI for palette content and settings
- local-first persistence with SQLite and GRDB

## Implemented

### Application launcher

- persistent `NSPanel` opened with a configurable global shortcut
- application discovery from standard macOS application directories
- in-memory normalized, prefix, acronym, substring, and fuzzy search
- recent-use and frequency ranking
- pinning and aliases
- integrated Action Panel
- Finder reveal, automatic application-directory monitoring, and manual recovery reindex

### Clipboard History

- dedicated two-pane palette route
- text, URL, file, and image captures
- local search, pinning, deletion, clear-history controls, and retention settings
- excluded-application settings and concealed/transient pasteboard filtering
- lazy image reads and bounded preview decoding
- optional safe URL previews
- Accessibility-based automatic paste with safe copy fallback
- clipboard restoration that does not overwrite a newer user copy

### Snippets

- dedicated two-pane palette route
- create, edit, duplicate, delete, search, copy, and paste
- optional keyword storage for future expansion support
- local usage ranking

### Aliases

- dedicated two-pane management route
- search by alias, application name, and bundle identifier
- add, edit, and delete without a separate utility window
- immediate reflection in Root Search

### Translation

- Root Search command and dedicated translation route
- typed input or explicitly selected text when Accessibility allows it
- configurable target language, provider, model, and reasoning level
- streaming result with independent copy controls for source and translation
- no implicit clipboard or selection upload

### Calculator

- Root Search arithmetic candidate for ASCII `+`, `-`, `*`, `/`, `%`, and parentheses
- explicit `Copy Result` and `Copy Expression` actions
- `Return` copies a valid result rather than launching an application
- invalid expressions and division by zero are surfaced as non-copyable errors

### AI Chat

- dedicated single-pane route: Root Search → chat list → conversation
- shared provider-neutral models, `AIChatViewModel`, list, conversation, composer, message, and Action Panel UI
- provider registry and provider-neutral conversation interfaces with capability-driven behavior
- Codex enabled by default through the installed `codex app-server` and Sign in with ChatGPT
- optional OpenAI API provider that can be enabled alongside Codex
- optional Claude Messages API provider that can be enabled alongside Codex and OpenAI API
- optional Ollama provider that can be enabled for models installed in the local Ollama service
- local title-only search and last-message ordering without network requests
- OpenAI Responses API streaming backed by Conversations API state
- API-key storage in macOS Keychain
- model selection, opt-in Web Search, explicit file inputs, citations, archive, and complete-delete retry
- minimal SQLite index containing title, model, archive/deletion state, and timestamps only
- no ChatGPT sidebar/history synchronization and no implicit Clipboard attachment

### Settings and interaction

- Settings integrated into the existing palette
- General, Clipboard, AI, and Shortcuts sections
- configurable shortcuts for Yorozu and feature routes
- current-process Accessibility status
- optional left/right Command-alone switching to Eisu/Kana, configured only in General
- permission-first Input Mode Switching settings limited to enablement, Accessibility
  status, System Settings access, and manual permission refresh
- windowless background monitoring protected from App Nap, with automatic event-tap recovery
- keyboard-first operation with mouse-accessible primary actions
- Japanese IME marked-text handling in search and action fields
- outside-click dismissal and menu-bar restart
- Light, Dark, high-contrast, reduced-transparency, and reduced-motion test modes

### Performance foundations

- one persistent panel and shared result-list hierarchy
- immutable in-memory search snapshots
- route and search revision checks
- lightweight command payload IDs with lookup indexes
- cached default route results
- incremental Clipboard catalog updates
- amortized database retention maintenance
- bounded image and URL-preview caches
- built-in presentation and Clipboard-interaction performance modes
- lazy provider credential and network initialization

## v0.1 private-dogfood milestones

The v0.1 implementation includes both prerequisite hardening milestones.

### v0.0.1 — Safety

- Clipboard replacement validates content and preserves the existing pasteboard before clearing it
- preservation is bounded to 16 items, 32 types per item, and 32 MiB total
- failed writes attempt restoration and report whether restoration succeeded
- stale files and empty or invalid images are rejected without changing the pasteboard
- Copy/Paste usage is recorded only after a successful write or safe Copy fallback
- storage corruption is backed up once and replaced only after migrations have passed validation in a temporary database
- transient SQLite failures remain retryable and do not trigger destructive recovery
- URL previews use an opt-in bounded fetcher with redirect, address, MIME, and payload validation

### v0.0.2 — Test isolation

- `AppEnvironment` separates production dependencies from UI-test dependencies
- UI tests use a temporary SQLite database and a dedicated `UserDefaults` suite
- application discovery, launching, pasteboard access, Accessibility checks, event posting, and URL preview networking are replaced with deterministic fakes
- global hotkey registration is disabled and shortcut recorders use isolated in-memory bindings
- Clipboard monitoring and network access remain disabled in UI-test mode
- test shutdown closes SQLite before removing the temporary directory
- CI builds and runs Unit/Integration tests on an Apple Silicon macOS 26 runner; UI automation remains a local permission-dependent check

These milestones are prerequisites for the three-business-day private dogfood gate. They are not separate distributable releases.

## Current architecture

```text
App/
  AppDelegate
  Menu bar and shortcut registration

Core/
  Shared value models, routes, and command payloads

Launcher/
  Application discovery and ranking
  Clipboard, snippet, AI conversation, and feature catalogs
  LauncherStore
  LauncherViewModel

Platform/
  PaletteWindowController and PaletteView
  Pasteboard, Accessibility, and paste coordination
  Settings, AI provider integrations, and safe URL previews
```

The runtime database is the single persistence source for launcher preferences, feature usage, clipboard history, snippets, AI chat list metadata, and URL-preview metadata. Search never queries SQLite per keystroke. AI message bodies and attachments are not stored in SQLite.

## Quality targets

| Metric | Target |
|---|---:|
| Warm palette presentation | p95 under 80 ms |
| Search over 2,000 items | p95 under 30 ms |
| Idle CPU | below 0.5% |
| Resident memory | below 100 MB |
| Network during normal search | none |

Privacy and reliability requirements:

- no clipboard, snippet, URL, file-path, credential, or selected-text logging
- no automatic network transmission of clipboard or snippet content
- URL previews remain explicit and optional
- AI network work starts only from an explicit AI or Translation action
- database failure must not make already-loaded Copy/Paste actions unusable
- paste failure must preserve copied content and explain the next action
- Japanese IME composition must reach the AppKit field editor

## Known constraints

- Clipboard History is disabled by default.
- Automatic paste requires current-process Accessibility trust and stable local signing.
- Command input-mode switching is disabled by default. It requires current-process
  Accessibility trust, stable local signing across rebuilds, and an existing Japanese
  input source in macOS.
- Non-image database retention cleanup is batched; expired rows can remain on disk until the next maintenance pass or explicit settings prune.
- A URL preview that fails is not retried again during the same app process.
- Codex requires an installed compatible `codex` executable and an authenticated ChatGPT account.
- OpenAI API Chat requires a user-provided API key and API Platform billing.
- Claude Chat requires a user-provided Anthropic API key and Anthropic API billing.
- Ollama Chat requires Ollama to be running locally and at least one locally installed model;
  it does not require an API key or cloud account.
- Translation requires an enabled provider with translation capability and the provider's
  configured credentials or local authentication.
- Local provider conversation indexes cannot be reconstructed by enumerating all remote conversations.
- UI automation depends on Xcode Automation permission and can fail before executing tests even when unit tests and the app are healthy.
- There is no packaged, notarized release yet.
- No open-source license has been selected yet; public visibility should not be treated as
  a grant to redistribute the source.

## Near-term roadmap

### v0.1 dogfood acceptance

- continue measuring cold start, warm presentation, route changes, selection movement, and long-session memory
- complete repeatable Light/Dark/accessibility appearance QA
- complete three business days of normal use with no P0/P1 issue, Clipboard loss, crash, recovery loop, or unusable interaction

### Text expansion

- opt-in global snippet expansion
- ASCII-prefixed triggers and delimiter rules
- per-application exclusions
- explicit Japanese IME composition safeguards
- no Input Monitoring request until the feature is enabled

### Distribution

- Developer ID signing and Hardened Runtime
- notarization and stapling
- versioned releases and release notes
- update mechanism only after signature and rollback design are reviewed

## Out of scope for the current release

- ChatGPT conversation-history synchronization
- autonomous Mac operation
- Voice, image generation, Custom GPTs, MCP, and File Search
- extension marketplace or third-party code execution
- team sharing or cloud sync
- Windows, Linux, iOS, or Mac App Store distribution
- OCR and full-fidelity preservation of every pasteboard representation
- A public hosted service or shared provider credentials

## Definition of done for a change

1. The change follows the existing route, Action Panel, shortcut, and persistence boundaries.
2. Focused tests cover success and failure paths.
3. The macOS Debug build succeeds.
4. Unit/integration, UI automation, and manual acceptance are reported separately.
5. UI work is checked with keyboard and mouse input.
6. IME-sensitive work is verified with marked text.
7. Performance-sensitive work is compared against an independently built baseline.
8. No local signing data, runtime database, clipboard capture, QA screenshot, credential,
   or machine-specific path is staged.

See [DEVELOPMENT.md](DEVELOPMENT.md) for commands and operational details.
