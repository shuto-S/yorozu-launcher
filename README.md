# Yorozu

Yorozu is a lightweight, keyboard-first launcher for macOS. It brings application launching, clipboard history, snippets, aliases, and settings into one native command palette.

> [!NOTE]
> Yorozu is in early development. The current build targets macOS 26 or later on Apple Silicon.

## Features

- Application search and launch
- Pinning, aliases, and recent-use ranking
- Clipboard history for text, URLs, files, and images
- Snippet creation, search, copy, and paste
- Dedicated two-pane screens for Clipboard History, Snippets, Aliases, and Settings
- Configurable global shortcuts
- Keyboard-first navigation with mouse support
- Japanese IME-safe command handling
- Native AppKit and SwiftUI interface

## Requirements

- macOS 26 or later
- Apple Silicon Mac
- Xcode 26 or later

## Build

The project builds ad hoc by default, so it does not require a personal Apple Development Team.

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Automatic paste uses macOS Accessibility permission. For that permission to remain stable between local builds, copy the signing template and enter your own Apple Development Team:

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

`Config/Local.xcconfig` is intentionally ignored by Git. Never commit personal signing identifiers or provisioning data.

## Test

```bash
xcodebuild \
  -project Yorozu.xcodeproj \
  -scheme Yorozu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

## Privacy

Clipboard history and snippets are stored locally. Yorozu does not send clipboard or snippet content over the network. URL previews are optional because loading one can contact the linked website.

The repository intentionally excludes local visual QA captures and runtime databases because they can contain application names, URLs, or clipboard content.

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

The broader implementation direction is documented in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).
