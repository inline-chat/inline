# Voice Message Downloads Plan

Date: 2026-06-07

## Goal

Fix voice message playback/download/progress bugs and add production-ready configurable auto-download behavior for voice messages, media, and files.

## Known Issues

- Some voice messages do not play when clicked, while saving the audio succeeds.
- Download progress can render as a blue rectangle instead of a clear download/progress/cancel control.
- Voice messages are not auto-downloaded under a user-configurable policy.
- Downloaded voice message UI can get stuck at 100% progress instead of returning to duration/playback state.
- Voice messages need to use the same durable cache/download/storage semantics expected for chat media.

## TODO

- [x] Map existing voice message playback, save, and download code paths.
- [x] Map existing attachment/media caching and local file URL conventions.
- [x] Map user settings storage and update flows on Apple clients and backend.
- [x] Identify why playable URLs differ from save/download URLs.
- [x] Fix progress UI states for download, cancel, completion, duration, and retry.
- [x] Add configurable auto-download thresholds for media, files, and voice messages.
- [x] Wire voice messages into auto-download and local cache resolution.
- [x] Add or update focused tests where feasible.
- [x] Run focused builds/tests for touched packages.

## Findings

- Voice playback and saving both ultimately depend on `Message.voiceLocalURL`, which is derived from
  `Client_MessageVoiceContent.localRelativePath`.
- Voice download uses `FileDownloader.downloadVoice`, stores the file in the `Voices` cache directory, then
  calls `FileCache.saveVoiceDownload` to update the message payload in SQLite.
- `VoiceMessageBubble` is a SwiftUI view embedded in AppKit/UIKit message cells. It currently has no durable
  local URL state of its own, so it can remain in a transient 100% progress state while waiting for message reload.
- `FileDownloader` keeps the completed progress snapshot in memory, so a newly bound bubble can immediately see
  a 100% progress value even after the actual task has completed.
- `VoiceMessageBubble` checks only the message value for local availability before playing. If the file has been
  downloaded by another view/session but the current message value has not refreshed yet, clicking can do nothing
  useful even though the file is present in cache.
- Notification settings are synced through protocol `UserSettings`, server encrypted general settings JSON, and
  `INUserSettings` on Apple. Auto-download settings must stay local because a user may want different preferences
  on iOS and macOS.
- Photos are already auto-downloaded opportunistically by photo views; documents/videos/voices need explicit
  threshold-based policy checks before starting downloads.

## Decisions

- Store auto-download settings locally in the Apple app group `UserDefaults`, not in synced protocol/server
  settings, so iOS and macOS can keep different thresholds.
- Keep media auto-download defaults conservative and size-based. Voice messages should be enabled by default with
  a small MB threshold so short voice messages become playable without an extra click. Files default to 10 MB.
- Add a shared Apple policy/helper for size threshold checks so SwiftUI/UIKit/AppKit views do not duplicate
  conversion and default logic.
- Treat stale voice `localRelativePath` values as unavailable if the file is no longer on disk, so the UI falls
  back to download/retry instead of presenting a play button that cannot start playback.
- Reject unsupported or mismatched voice MIME/extension pairs at upload time. For existing rows, use the stored
  MIME type when valid and derive only from supported storage extensions when the MIME type is missing or invalid.
  Do not label unknown voice files as Ogg or M4A.
- Apply the new media auto-download policy to video downloads and background image prefetch. Visible photo views
  still render through the existing photo cache path to avoid regressing image display until a proper photo
  download overlay/manual state exists.

## Clarification Pass

- [x] Make auto-download preferences local-only instead of protocol/server-synced.
- [x] Change the default file auto-download threshold from disabled to 10 MB.
- [x] Remove guessed voice MIME defaults from upload, download, realtime encoding, transcription, and macOS save paths.
- [x] Rerun focused server/protocol/package checks after the local-only/MIME cleanup.

## Stabilization Review Fixes

- [x] Centralized server voice MIME/extension resolution in one helper and reused it from upload validation,
  realtime encoding, and transcription.
- [x] Added regression coverage for old voice rows that need MIME derived from storage extension, including
  invalid legacy MIME values, while keeping new uploads strict about unsupported MIME types.
- [x] Added regression coverage for MIME/extension mismatches that must not be encoded as playable voice media.
- [x] Made voice cancellation clear transient progress instead of showing a failed state or leaving a stale
  progress snapshot in the bubble.
- [x] Kept completed voice downloads out of the visible progress UI so the bubble returns to duration/playback
  immediately after completion.
- [x] Re-ran auto-download checks when reused macOS media views are rebound to a new message, and avoided starting
  offscreen downloads before the view is attached.
- [x] Fixed iOS photo prefetch bookkeeping so a media item blocked by the current local auto-download threshold is
  not permanently marked as already prefetched after the user changes settings.
- [x] Reduced manual voice cache clearing memory pressure by scanning message rows with a cursor and retaining only
  the voice cache entries that need deletion/local-path clearing.

## Verification

- `bun run generate:proto` passed.
- `cd server && bun test src/__tests__/userSettings.test.ts` passed.
- `cd server && bun run typecheck` passed.
- `cd server && bun run lint` exited 0 with unrelated existing warnings.
- `cd apple/InlineKit && swift build` passed.
- `cd apple/InlineKit && swift test --filter AutoDownloadSettingsTests` passed.
- `cd apple/InlineUI && swift build` passed.
- `cd apple/InlineMacUI && swift build` passed.
- `cd apple/InlineIOSUI && swift build` passed.
- `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build` passed.
- `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (iOS)" -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build` passed after removing a new warning in `ImagePrefetcher.swift`.
- `git diff --check` passed.
- Full `cd apple/InlineKit && swift test` still fails in pre-existing RealtimeV2/Sync suites unrelated to this
  change; the focused auto-download tests pass.
- Clarification follow-up:
  - `cd server && bun test src/__tests__/userSettings.test.ts src/__tests__/modules/files/voiceMetadata.test.ts src/modules/voiceTranscription/voiceTranscription.test.ts` passed.
  - `cd server && bun run typecheck` passed.
  - `cd server && bun run lint` exited 0 with existing warnings.
  - `cd packages/protocol && bun run typecheck` passed.
  - `cd apple/InlineKit && swift build` passed.
  - `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build` passed.
  - `git diff --check` passed.
  - `cd apple/InlineKit && swift test --filter AutoDownloadSettingsTests` is blocked before running the focused
    test by unrelated compile errors in `apple/InlineKit/Tests/InlineKitTests/RealtimeV2/SyncTests.swift`
    referencing removed sync config APIs.
  - `cd apple/InlineUI && swift build` is blocked by unrelated missing bot-command helpers in
    `apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift`.
- Stabilization follow-up:
  - `cd server && bun test src/__tests__/modules/files/voiceMetadata.test.ts src/realtime/encoders/encodeMessage.test.ts` passed, 24 tests.
  - `cd server && bun run typecheck` passed.
  - `cd server && bun run lint` exited 0 with existing warnings.
  - `cd apple/InlineKit && swift build` passed.
  - `cd apple/InlineUI && DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcrun swift build` passed with existing warnings.
  - `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (iOS)" -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build` passed with existing warnings.
  - `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build` passed with existing warnings.
  - `git diff --check` passed.
  - Plain `cd apple/InlineUI && swift build` uses the shell Swift 6.2.3 toolchain and fails before compiling because
    `InlineUI` now declares Swift tools 6.3.0; the same package builds with Xcode's Swift 6.3 toolchain.
  - The first parallel macOS/iOS app build attempt hit Xcode's shared DerivedData build database lock; rerunning the
    app builds serially passed.

## Caveats

- True Ogg/Opus voice playback may still require an AVPlayer/transcoding path; this pass fixes stale cache state,
  failed-state UI, and prevents unsupported voice files from being silently mislabeled.
- Invalid legacy voice rows with a MIME/extension mismatch are now intentionally omitted from realtime voice media
  instead of being mislabeled. Those rows need data repair to become playable.
- Cache clearing now removes voice files and clears stored voice local paths. It scans messages with content
  payloads, which is acceptable for manual cache clearing but could be indexed later if it becomes slow on very
  large local histories.
