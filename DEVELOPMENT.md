# Yorozu Development Guide

This guide is the operational source for building, testing, and profiling Yorozu. Product scope and roadmap live in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Supported environment

- macOS 26 or later
- Apple Silicon (`arm64`) only
- Xcode 26 or later
- Swift 6 with strict concurrency

The app bundle identifier is `com.yorozu.app`. Yorozu is an `LSUIElement` menu-bar utility and does not create a normal Dock window.

## Dependencies

Dependencies are resolved with Swift Package Manager and pinned in `Package.resolved`.

| Package | Version | Purpose |
|---|---:|---|
| KeyboardShortcuts | 3.0.1 | User-configurable global shortcuts |
| GRDB.swift | 7.11.1 | SQLite migrations and persistence |

Do not add or update dependencies without reviewing the need, license, supported macOS versions, and effect on launch time and resident memory.

## Local setup

The shared Debug configuration builds ad hoc:

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

### Apple Development signing

Accessibility trust is tied to the current code-signing identity. For stable automatic-paste testing, create an ignored local override:

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Replace `YOUR_TEAM_ID` in `Config/Local.xcconfig`. Do not commit this file, certificate names, provisioning profiles, or other personal signing data.

The shared project must remain buildable without a personal Apple account. Never place a Development Team directly in `project.pbxproj`.

## Repository structure

```text
Yorozu/
├── App/        Lifecycle, dependency construction, menu bar, shortcuts
├── Core/       Shared routes and value models
├── Launcher/   Discovery, catalogs, ranking, persistence, view model
├── Platform/   AppKit, SwiftUI, pasteboard, Accessibility, settings
└── Resources/  Product strings, app icon, menu-bar asset

YorozuTests/    Unit and integration tests
YorozuUITests/  macOS UI automation
Config/         Shared Debug defaults and local signing template
```

## Runtime architecture

`AppDelegate` constructs the long-lived services once. `PaletteWindowController` owns one persistent `NSPanel`, while `LauncherViewModel` publishes route and result state to SwiftUI.

```text
Global Shortcut / Menu Bar
          │
          ▼
PaletteWindowController ── NSPanel lifecycle, focus, key routing
          │
          ▼
LauncherViewModel ─────── route, query, selection, actions
          │
          ├── ApplicationCatalog
          ├── ClipboardCatalog
          ├── SnippetCatalog
          └── FeatureCommandCatalog
                    │
                    ▼
               LauncherStore
```

Important boundaries:

- Keep AppKit objects on the appropriate actor, normally `MainActor`.
- Search immutable in-memory snapshots; never query SQLite for every keystroke.
- Pass stable IDs in `CommandPayload` and resolve full objects from the current snapshot.
- Cancel stale search, image, and URL-preview work before publishing results.
- Keep clipboard conversion, hashing, image decoding, and database work outside route-transition and selection paths.
- Do not recreate the result list just because a detail pane becomes visible.

## Persistence and privacy

The runtime database is stored at:

```text
~/Library/Application Support/com.yorozu.app/Yorozu.sqlite
```

It may contain clipboard content, snippet content, application paths, and URL-preview metadata. Never copy it into the repository, fixtures, logs, bug reports, or performance artifacts.

Privacy invariants:

- Never log clipboard bodies, snippets, URLs, file paths, credentials, or selected text.
- Clipboard history is local and disabled by default.
- URL previews are optional and may contact the selected website.
- A failed URL preview is not retried repeatedly during the same process.
- Yorozu does not currently implement AI chat, cloud sync, or telemetry.

Clipboard maintenance is intentionally amortized. Non-image captures perform full database retention maintenance every 32 writes; in-memory pruning still occurs for each capture. Image captures perform full maintenance immediately.

### Storage recovery

At startup, Yorozu validates the current migrations against a temporary database before attempting recovery of the real database. If corruption, schema incompatibility, or invalid persisted values prevent startup, Yorozu makes one recovery attempt:

1. close the current database;
2. move SQLite, WAL, and SHM files to `Application Support/com.yorozu.app/Recovery/<UTC timestamp>/`;
3. create and hydrate a fresh database;
4. show a recovery notice in Settings with Reveal Backup and Dismiss actions.

An incomplete backup move is rolled back where possible, and the source database is never deleted as a recovery shortcut. Busy, disk-full, permission, and general I/O errors do not trigger recovery; they remain retryable.

## Validation

### Unit and integration

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:YorozuTests \
  test
```

### UI automation

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:YorozuUITests \
  test
```

The UI runner requires Xcode Automation permission. If it cannot enable automation or materialize a worker, report that separately from unit and integration results.

### Isolated UI-test environment

Pass `--ui-testing-run-id <unique-value>` when starting the test host. UI-test mode must use:

- a temporary SQLite database;
- a dedicated `UserDefaults` suite;
- fixed application fixtures and a fake application launcher;
- a fake pasteboard;
- Clipboard monitoring disabled;
- fake Accessibility and event-posting dependencies;
- global shortcut registration disabled and shortcut recorders backed by isolated bindings;
- URL preview networking disabled.
- fake Codex/OpenAI/Claude providers, credentials, conversation fixtures, and chat services with no network access.

Failure to construct this environment is fatal. UI tests must never fall back to production dependencies. Test shutdown waits for Clipboard monitoring to stop, closes the store, and only then removes the temporary directory.

### Manual acceptance

For UI or input changes, check:

- Light and Dark appearances
- Increase Contrast
- Reduce Transparency
- Reduce Motion
- keyboard selection and one-row-at-a-time scroll following
- mouse selection and footer actions
- outside-click dismissal
- Root, Clipboard, Snippets, Aliases, AI Chat, and Settings route transitions
- Japanese IME composition, candidate movement, confirmation, and cancellation
- automatic paste and copy fallback with Accessibility both allowed and denied

## Performance measurement

Debug builds expose bounded performance modes:

| Argument | Report |
|---|---|
| `--performance-testing` | `/private/tmp/yorozu-palette-performance.json` |
| `--performance-testing-clipboard` | `/private/tmp/yorozu-palette-performance-clipboard.json` |
| `--performance-testing-snippets` | `/private/tmp/yorozu-palette-performance-snippets.json` |
| `--performance-testing-clipboard-interaction` | `/private/tmp/yorozu-clipboard-interaction-performance.json` |

Run the built executable directly with one argument. Each mode warms the persistent panel, writes a timing-only JSON report, and exits.

When evaluating a performance change:

1. Build the original and changed source separately.
2. Ensure no normal Yorozu or test-host process is running.
3. Run at least four independent trials for each compared mode.
4. Compare p50, p95, maximum, idle CPU, and resident memory.
5. Confirm that a faster measurement is not displaying an empty or stale list.
6. Re-run the 2,000-item search tests.

Targets:

| Metric | Target |
|---|---:|
| Warm palette presentation | p95 under 80 ms |
| Search over 2,000 items | p95 under 30 ms |
| Idle CPU | below 0.5% |
| Resident memory | below 100 MB |

## Git and review hygiene

- Inspect `git status`, the intended diff, and `git diff --check` before committing.
- Stage explicit files when the worktree is mixed.
- Keep local signing, databases, visual QA captures, logs, traces, and Xcode result bundles untracked.
- Do not include clipboard or snippet content in test names, snapshots, commit messages, or pull-request descriptions.
- Separate unit/integration results, UI automation, and manual acceptance in the final report.
