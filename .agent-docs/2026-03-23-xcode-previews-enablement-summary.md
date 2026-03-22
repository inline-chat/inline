# Xcode Previews Enablement Summary (macOS)

Date: 2026-03-23
Scope: Changes made specifically to get SwiftUI Canvas previews to run for Inline macOS message interaction UI.

## What was changed

1. `apple/InlineMac/App/AppDependencies.swift`
- Converted stored properties to explicit initialization in `init(previewMode:)`.
- Added preview detection via `XCODE_RUNNING_FOR_PREVIEWS`.
- In preview mode, switched DB/data dependencies from `AppDatabase.shared` to `AppDatabase.empty()` and `DataManager(database: previewDatabase)`.

2. `apple/InlineMac/App/AppDelegate.swift`
- Added preview detection helper `isRunningInXcodePreview`.
- Added early returns in `applicationWillFinishLaunching` and `applicationDidFinishLaunching` when running in preview.
- Changed `dependencies` to lazy initialization.
- Changed `dockBadgeService` to lazy optional and disabled it for previews.
- Guarded dock badge start/termination calls with optional chaining.

3. `apple/InlineKit/Sources/InlineKit/Database.swift`
- Added preview detection helper.
- Added fallback helpers to initialize unencrypted in-memory DB for preview-only contexts when SQLCipher initialization fails.
- Updated in-memory DB initialization paths to use this fallback in preview mode.

4. `apple/InlineMac/Views/Message/MessageInteractionPreviews.swift`
- Added preview canvases for:
  - Message action rows (incoming)
  - Message action rows (outgoing/loading)
  - Reply footer (normal)
  - Reply footer (loading)

## Observed behavior during debugging

- Initial preview crash due SQLCipher initialization in preview process was addressed by preview-only DB fallback.
- Subsequent state showed Canvas tabs but no rendered content (`Cannot find previews`), indicating additional preview-host/runtime issues remained.

## Requested rollback action

Per user request, all preview-specific changes above are being discarded from the working tree while keeping this summary doc for future reference.
