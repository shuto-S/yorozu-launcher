# Yorozu Development Guide

This guide is the operational source for building, testing, and profiling Yorozu. Product scope and roadmap live in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

The repository is public, while the application is still an early local-first dogfood
build. Keep implementation notes reproducible and generic: never document a developer's
machine path, signing identity, account, credential, or captured user data.

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
| Sparkle | 2.9.6 | Release-only signed application updates |

Do not add or update dependencies without reviewing the need, license, supported macOS versions, and effect on launch time and resident memory.

Sparkle is linked into the app but its updater is never started in Debug or UI-test
builds. Only a non-test Release build with a valid HTTPS `SUFeedURL` and non-empty
`SUPublicEDKey` starts the scheduler. Normal Root Search does not perform an update check.

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

Accessibility trust is tied to the current code-signing identity.
For stable automatic-paste, Command input-mode switching, and Window Control tests,
create an ignored local override:

1. In Xcode, open **Settings → Accounts** and add an Apple Account.
2. Select the account, open **Manage Certificates**, and create an **Apple Development** certificate if one is not already available.
3. Find the account's Team ID, then create the local override:

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Replace `YOUR_TEAM_ID` in `Config/Local.xcconfig`, then rebuild. The following command
should list the development identity:

```bash
security find-identity -v -p codesigning
```

Do not commit `Config/Local.xcconfig`, certificate names, provisioning profiles, or
other personal signing data.

An ad hoc signature changes when the executable changes. macOS can therefore show an old
Yorozu entry while the current build remains untrusted, or turn its switch off after a
rebuild. Use an Apple Development identity before diagnosing TCC-dependent features.
Input mode switching uses an active session event tap and posts the native JIS Eisu or
Kana key to the focused application. Accessibility grants the required event listening
and posting access; a separate Input Monitoring grant is not required.

Treat `AXIsProcessTrusted()` and `CGPreflightPostEventAccess()` as authoritative for
Input Mode Switching. System
Settings can display an enabled row for a different Yorozu build with the same display
name. When that happens, remove the stale row, reveal the current build from General
settings, and add that exact app once. Do not use `tccutil reset` in development scripts
or application code.

Apple Development and Developer ID Application are different TCC identities even when
they share `com.yorozu.app`. Rebuilding repeatedly with one stable Apple Development
identity preserves local development authorization; published updates preserve the
Developer ID identity separately.

The General settings screen exposes the feature toggle, current-build Accessibility
state, System Settings and current-build recovery actions, permission refresh, and bounded
diagnostics for the monitor and last switch. An ad hoc warning appears only when that
signing problem is detected. English and Japanese sources are resolved automatically from
enabled, select-capable macOS input sources; there is no separate source picker.

While input mode switching is enabled and authorized, Yorozu holds a user-initiated
`ProcessInfo` activity that allows idle system sleep. This keeps the event tap
responsive when Yorozu is not frontmost without preventing the Mac from sleeping. The
event tap runs on its own named thread and run loop, so delivery does not depend on the
main AppKit run loop or the application being active. A lightweight health check recreates
an invalidated tap. Monitoring, the health check, and the activity are all stopped
immediately when the feature is disabled or the app terminates.

Window Control follows the same permission and signing rules. Its active session event tap is
created only after the feature is enabled, two distinct modifier combinations are set,
and the current process is trusted. It listens only for modifier changes and primary-button
drag events, then coalesces matching gestures before performing Accessibility work on a
dedicated serial queue. Move gestures use cached screen snapshots and preview top, left,
and right edge targets against `NSScreen.visibleFrame`; the target frame is applied only
on `leftMouseUp`. Releasing the modifier first cancels the snap. The preview panel exists
only while a snap candidate is active, and screen snapshots refresh only when the display
configuration changes. It uses a user-initiated activity that still permits idle system
sleep.

The shared project must remain buildable without a personal Apple account. Never place a Development Team directly in `project.pbxproj`.

Window Control validates the actual event-tap port and enabled state, checks health every
five seconds only while enabled, and recreates monitoring after wake or session recovery.
The same check also detects Accessibility re-grants without foregrounding Yorozu; it
does not request permission automatically. Rebinding a chord cancels an active drag.
Its filtering tap runs after the Command-alone observer, so a Command-modified drag does
not become an input-mode switch. Stopping the feature cancels pending mouse-up frame and
snap updates as well as pending drag samples. A failed target lookup stays attached to that
gesture; moving over another window does not silently select a different target. Failures
remain visible in Settings after the mouse button is released.
Cancellation is checked again after slow AX replies and before deferred activation or
snap previews. An individual AX write already sent to another process cannot be undone,
but cancellation prevents later steps from being applied.

Window targeting uses the topmost visible Window Server owner for application-scoped AX
hit testing, then matches its bounds to that application's AXWindows if needed. AX lookup
has a one-second total budget with per-request timeouts capped at 200 ms; an incomplete
scan cannot select an ambiguous candidate. Frame matching allows up to 4 pt per edge
for the small Window Server/AX frame insets observed on macOS 26 standard windows.
Direct AX hit testing uses the validated owner and point containment instead: Window
Server geometry can lag behind AX during a move, so only fallback lookup compares bounds.
Invalid geometry, ambiguous matches, and menus covering the target are rejected.
No window titles or contents are captured, and no
process-wide Accessibility timeout is changed.

Window Control's modifier recorders expose separate accessibility actions and own key
handling only while recording. Escape cancels recording without closing Settings; Tab
ends recording and resumes normal focus movement. Leaving Settings, losing focus, or
closing the palette discards the pending chord and removes its local monitor.

For optional real AX verification, build `Tests/Fixtures/WindowControlFixture.swift`
as a separate temporary executable named `WindowControlFixture`:

```bash
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -target arm64-apple-macos26.0 Tests/Fixtures/WindowControlFixture.swift \
  -o /tmp/WindowControlFixture
```

Run `WindowControlLiveTests` in a signed test host that already has Accessibility
permission. Use `build-for-testing`, copy its generated `.xctestrun` beside the original,
and set the `YorozuTests` entry's `CommandLineArguments` to
`["--ui-testing", "--ui-testing-run-id", "<unique-run-id>"]`. Set its
`EnvironmentVariables.YOROZU_LIVE_WINDOW_TESTS` to `1` and
`EnvironmentVariables.YOROZU_WINDOW_FIXTURE_EXECUTABLE` to the fixture's absolute path,
then use `test-without-building -xctestrun <copy> -only-testing:YorozuTests/WindowControlLiveTests`.
This uses an isolated database and defaults, with normal monitors and networking disabled.
The tests start and foreground only their own fixture, check target lookup through its title bar and
content, check real position/size read-back after move, resize and snap-frame writes,
and terminate the fixture. Missing existing permission, screen lock, or another window
covering the hit-test fixture is an explicit skip, not a pass.
It does not validate physical pointer delivery or replace unlocked drag acceptance tests.

### Public-repository safety

- Keep `Config/Local.xcconfig` ignored; only the placeholder example is tracked.
- Never commit API keys, access tokens, cookies, Keychain exports, provisioning files, or
  personal signing identifiers.
- Never commit `Yorozu.sqlite`, WAL/SHM files, clipboard captures, snippet content, URL
  preview data, screenshots, logs, traces, or Xcode result bundles.
- Scrub local paths and selected text from issue reports, test fixtures, screenshots, and
  commit messages.
- If a suspected vulnerability contains sensitive details, use a private GitHub security
  channel when available instead of a public issue.

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
.github/        CI and tag-driven release automation
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
          ├── AIChatViewModelStore and provider registry
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
- AI Chat and Translation are opt-in feature routes. They do not create network tasks
  during normal Root Search startup.
- Provider credentials are loaded lazily from Keychain or the provider's local app-server
  integration only when the provider is selected or used.
- AI message bodies, attachments, and prompt drafts are not stored in SQLite.
- Yorozu does not implement cloud sync or telemetry.
- Debug and UI-test builds do not start Sparkle or load the external appcast.

### Application updates

`AppUpdateController` owns Sparkle's standard updater and exists outside the latency-
sensitive launcher search path. Release builds use the Info.plist feed URL and EdDSA
public key; Debug builds contain neither entry. The menu-bar **Check for Updates…** item
uses Sparkle's standard UI, while **View Latest Release…** provides a recovery path when
the feed or network cannot be used.

Tag-driven Developer ID signing, notarization, GitHub Release creation, EdDSA appcast
generation, and GitHub Pages deployment are documented in [RELEASING.md](RELEASING.md).
No private release credential belongs in the repository.

Clipboard maintenance is intentionally amortized. Non-image captures perform full database retention maintenance every 32 writes; in-memory pruning still occurs for each capture. Image captures perform full maintenance immediately.
The database and in-memory catalog use the same last-used order, stable ID tie-breaker,
item limit, and image-budget admission when pruning. Pin items remain exempt.

Copy and Paste, including AI message Copy across all providers, share a single-flight
coordinator until clipboard restoration finishes. AI UI tests inject the same isolated
copy service rather than constructing a system pasteboard accessor.
It rechecks the clipboard revision after asynchronous preparation and activation waits,
before posting Paste, and before restoration. A new external copy cancels replacement
or is left intact after Paste. A restoration failure is reported separately from a
failed Paste so users are not prompted to paste the same content twice.
Unreadable advertised pasteboard representations fail preservation before any mutation;
empty representations remain valid. Writes retain the ownership generation returned by
`clearContents()` so a concurrent external copy cannot be mistaken for Yorozu's data.
The history monitor ignores only Yorozu-owned generations (bounded to 16), not all
copies during a time window. External copies immediately after Copy/Paste remain eligible
for recording. Reads validate the expected generation before and after materializing data.

Action Panel hover selection requires an actual change in screen pointer position.
Keyboard-driven scrolling under a stationary pointer must not replace the keyboard
selection. This uses event-driven hover callbacks, not another monitor or timer.

### Translation and Calculator

Translation is an explicit Root Search feature. It can use selected text when Accessibility
allows it, or text entered in the translation route. Provider, model, reasoning level, and
target language are user-configurable. The translation request is sent only after the user
starts translation; clipboard content is not attached implicitly.

Root arithmetic is deliberately narrow and predictable. Only ASCII digits, decimal points,
parentheses, and `+ - * / %` are accepted. Results are copied through an explicit result
action, while invalid expressions and division by zero remain non-copyable error states.

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
- fake Codex/OpenAI/Claude/Ollama providers, credentials, conversation fixtures, and chat services with no network access.

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
- Root arithmetic, including copy-result actions and division-by-zero handling
- Translation with typed input, selected-text handoff, provider/model/reasoning selection,
  and copy controls
- Input Mode Switching while Yorozu is both frontmost and inactive: Left Command alone
  selects English, Right Command alone selects Japanese, Command shortcuts and
  Command-clicks remain unaffected, disabling the feature stops monitoring, and Settings
  reports the actual source transition or a specific missing-source/selection error

For focused Input Mode Switching regression coverage, run:

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:YorozuTests/CommandInputModeSwitchingTests \
  test
```

Ollama is disabled by default and has no Keychain credential. It contacts the default local
service (`127.0.0.1:11434`) only after the provider is selected or used. Model discovery uses
the local tags endpoint and chat responses are consumed as newline-delimited JSON; Root
Search never performs this work.

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
- Before pushing, run `git diff --check` and inspect `git diff --cached` for secrets,
  personal paths, credentials, and runtime artifacts.
- Separate unit/integration results, UI automation, and manual acceptance in the final report.
