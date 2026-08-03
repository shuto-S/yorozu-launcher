# Yorozu Repository Guide

This file applies to the entire repository. Follow the user's current request and higher-level instructions first.

## Documentation map

- `README.md`: product overview, supported environment, and quick start.
- `DEVELOPMENT.md`: local setup, architecture, validation, performance measurement, and Git hygiene.
- `IMPLEMENTATION_PLAN.md`: implemented scope, current constraints, and roadmap.
- The code and shared Xcode settings are authoritative when documentation drifts.

## Product constraints

- Yorozu is a lightweight native macOS command palette.
- Support macOS 26 or later on Apple Silicon only.
- Keep the bundle identifier `com.yorozu.app`.
- Keep the app as an `LSUIElement` menu-bar utility with no regular Dock window.
- Preserve the keyboard-first interaction model while keeping all primary actions mouse-accessible.
- Keep product-facing copy in English.
- Keep Root Search, Clipboard History, Snippets, Aliases, AI Chat, and Settings in the existing palette.
- Snippet auto-expansion, cloud sync, and distribution automation are not implemented. Do not imply otherwise in product copy or documentation.

## Repository map

- `Yorozu/App`: lifecycle, dependency construction, menu bar, and shortcut registration.
- `Yorozu/Core`: shared command, application, clipboard, snippet, and route models.
- `Yorozu/Launcher`: discovery, catalogs, ranking, persistence, and `LauncherViewModel`.
- `Yorozu/Platform`: `NSPanel`, SwiftUI surfaces, pasteboard, Accessibility, URL previews, and settings.
- `YorozuTests`: unit and integration tests.
- `YorozuUITests`: macOS UI automation.
- `Config`: shared Debug signing defaults and the ignored local signing override.

## Architecture

- Use Swift 6 with strict concurrency.
- Use AppKit for `NSPanel`, focus, active-application restoration, pasteboard, Accessibility, and other macOS-specific behavior.
- Use SwiftUI for palette content and settings.
- Keep `NSImage`, `NSRunningApplication`, and other AppKit objects on the appropriate actor boundary.
- Search immutable in-memory snapshots. Do not query SQLite for each keystroke.
- Keep persistence in `LauncherStore`; do not introduce parallel storage for existing entities.
- Reuse the shared route, two-pane layout, Action Panel, and shortcut registry before adding new variants.
- Do not add dependencies without explicit user approval.
- Keep command payloads lightweight. Pass stable identifiers across UI boundaries and resolve full models from the current snapshot.
- Preserve route and search revision checks so canceled asynchronous work cannot overwrite the current route or selection.
- Keep the current dependency set pinned unless a requested change requires otherwise:
  - KeyboardShortcuts 3.0.1
  - GRDB.swift 7.11.1

## UI and input

- Prefer macOS 26 standard controls, semantic colors, system typography, and system separators.
- Do not add custom blur, fixed appearance colors, custom shadows, or unnecessary nested glass effects.
- Keep Root Search, Clipboard History, Snippets, Aliases, AI Chat, and Settings inside the existing palette rather than creating separate utility windows.
- Preserve Japanese IME composition. Before consuming Return, Enter, arrow, Escape, or Tab events, respect the field editor's marked-text state.
- Keep keyboard selection scrolled into view and preserve mouse selection.

## Performance and privacy

- Treat launcher presentation, route changes, and selection movement as latency-sensitive paths.
- Keep clipboard conversion, image decoding, hashing, large-text normalization, database writes, and URL preview work off the main route-transition path.
- Cancel stale searches and previews, and prevent canceled work from overwriting current selection state.
- Do not rebuild the result-list hierarchy merely because the route opens a detail pane.
- Keep default route results cached in memory, and update lookup indexes when publishing a new result snapshot.
- Preserve the bounded image and failed-URL preview caches. Do not retry a failed URL preview every time selection returns to it.
- Clipboard database retention maintenance is deliberately amortized for non-image captures. In-memory pruning remains on the capture path; image captures trigger full database maintenance immediately.
- Performance targets:
  - warm palette presentation p95 under 80 ms;
  - search over 2,000 items p95 under 30 ms;
  - idle CPU below 0.5%;
  - resident memory below 100 MB.
- Never log clipboard bodies, snippet bodies, URLs, file paths, API keys, credentials, or user-selected text.
- Keep AI message bodies and attachments out of SQLite and never access Keychain or OpenAI during normal Root Search startup.
- Do not commit runtime databases, QA screenshots, clipboard captures, or local machine paths.

## Signing

- Shared project settings must not contain a personal Development Team or provisioning profile.
- Local Apple Development signing belongs in `Config/Local.xcconfig`, which is ignored by Git.
- Use `Config/Local.example.xcconfig` as the template.
- Do not reset Accessibility permissions or alter TCC data automatically.

## Validation

Start with focused tests. `DEVELOPMENT.md` contains the full matrix.

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build

xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:YorozuTests \
  test
```

- Run `-only-testing:YorozuUITests` separately so UI automation failures are not reported as unit-test failures.
- The Xcode test runner may require Automation permission before it can materialize a macOS UI-test worker.
- Distinguish unit/integration success, UI automation, and manual acceptance.
- For UI changes, check Light, Dark, Reduce Transparency, Increase Contrast, Reduce Motion, keyboard navigation, mouse operation, and VoiceOver where relevant.
- For IME changes, manually verify composition, candidate navigation, confirmation, and cancellation in every affected search field.
- For performance changes, compare multiple independent runs of the original and changed binaries; do not reuse old screen-observed figures.
- After changes, inspect the intended Git diff and confirm ignored privacy-sensitive artifacts are not staged.
