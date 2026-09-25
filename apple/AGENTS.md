# Instructions for Apple clients

## Scope

- Shared Swift packages: `apple/InlineKit`, `apple/InlineUI`, `apple/InlineProtocol`, and more.
- App targets: `apple/InlineIOS`, `apple/InlineMac`.
- Prefer new feature work in `apple/InlineIOSUI` and `apple/InlineMacUI` or new targets/modules when change is bigger. Use legacy targets only when tightly coupled.

## Defaults

- Minimum versions: iOS 18 and macOS 15.
- Prefer Swift Testing (`import Testing`, `@Test`, `@Suite`) and Observation (`@Observable`, `@Bindable`).
- Avoid `EnvironmentObject` / `ObservableObject` where practical.
- Prefer Swift strict concurrency and composable views. Avoid main-thread heavy work unless it's to support our first frame render constraint. Most of our renders should be first frame ready sync or best effort first frame for optional media.
- Xcode project uses filesystem-synced groups.

## Research, investigations and docs

- Prefer reading as much as possible from Apple Developer Docs when working with Apple's APIs especially newer ones.
- Add `.md` extension to documentation URLs to get the markdown version, eg. https://developer.apple.com/documentation/swift/double.md

## Builds And Checks

- Prefer focused package builds/tests (`swift test`, `swift build`, Swift syntax/type checks) over full `xcodebuild`. Ideally only on touched files, and avoid repeatedly calling them for every small change.
- Regenerate Swift protos with `bun run proto:generate-swift` from `scripts/` when needed.

## Local Data And Protocols

- `AppDatabase` migrations are in `InlineKit/Sources/InlineKit/Database.swift`; append new migrations at the end.
- For protobuf blobs in DB, follow the `DraftMessage` typed-model + `ProtocolHelpers` + `DatabaseValueConvertible` pattern.

## Debug And Release Commands

- iOS physical-device debug: get an ID with `xcrun devicectl list devices`, then run `bun run ios:debug -- --device <id>`. Add `--no-build`, `--no-launch`, or `--no-logs` as needed. Plain `ios:debug`, `--select`, and `--list` invoke `simctl list`; use them only with explicit simulator-tooling approval. Logs go to `.tmp/ios-debug-*.log`.
- macOS debug: `bun run macos:debug` builds and opens `Inline Debug.app`, stopping an existing debug instance by default. Add `--no-build`, `--no-open`, `--no-stop`, or `--no-logs` as needed. Logs go to `.tmp/macos-debug-*.log`.
- Local macOS Sparkle build: `cd scripts && bun run macos:build-local-app -- --channel <stable|beta|tip>` produces `build/InlineMacDirectLocal/Build/Products/DevBuild/Inline-Dev.app`. Keep `DevBuild` aligned with `Release` except for intentional app identity and profile settings.
- macOS release, when authorized: `cd scripts && bun run macos:release-app -- --channel <stable|beta|tip>` publishes the direct Sparkle/DMG release.
- Keep raw traces and exports in ignored `.traces/`; summarize findings in `../secret-sauce/.context/`.

## UI And Performance

- Send/open-chat and message-list paths are latency-sensitive; validate first-frame and scrolling performance when changing them.
- Keep message rendering lightweight and pure: prepare required data before constructing rows; do no database/network reads, heavy setup, or menu fetching in view/cell construction.
- Avoid `.receive(on: DispatchQueue.main)` after a GRDB observation when its initial value is needed for the first render; the hop defers delivery. Keep expensive observation work off the main thread.
- For new macOS per-message content, use measured manual layout rather than `NSStackView` or auto-layout and such. However, apply geometry to Auto Layout-backed children such as `PlatformPhotoView` through constraints if needed, not direct `frame`/`bounds` changes.
- Prefer `.frame(maxWidth: .infinity, alignment: .leading)` over `Spacer()` solely to push one element away from another.
- In bounded UIKit-hosted SwiftUI, set `hostingController.safeAreaRegions = []` unless the content should inherit the window safe area.
- Gate Liquid Glass APIs to iOS/macOS 26+, group related effects in `GlassEffectContainer`, and use `.interactive()` only for controls.
