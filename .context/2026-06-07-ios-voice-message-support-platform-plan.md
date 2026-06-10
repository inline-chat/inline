# iOS Voice Message Support Platform Plan

Date: 2026-06-07

## Goal

Implement iOS voice message recording and sending using Inline's existing voice media backend, shared playback UI, and the current macOS voice composer as the product model.

Telegram is only a technical reference for recorder lifecycle, audio capture, waveform handling, cleanup, and playback coordination. Do not copy Telegram's press-hold, slide-to-cancel, lock, trim, or other chat-input UX unless we explicitly decide to later.

## Current Inline State

### Backend and protocol

- Voice is already a first-class media type:
  - `proto/core.proto` has `MessageMedia.voice`, `MessageVoice`, `InputMedia.voice`, and `InputMediaVoice`.
  - `server/src/db/schema/media.ts` has `voices`.
  - `server/src/db/schema/messages.ts` has `mediaType = "voice"` and `voiceId`.
  - `server/src/functions/messages.sendMessage.ts` accepts `voiceId` and writes voice media.
  - `server/src/realtime/encoders/encodeVoice.ts` emits duration, size, MIME type, signed URL, and waveform.
- Server upload accepts voice through `uploadFile`:
  - valid MIME types: `audio/ogg`, `audio/mp4`, `audio/x-m4a`
  - valid extensions: `.ogg`, `.oga`, `.m4a`, `.mp4`
  - MIME and extension must match
  - waveform is required and capped at 2048 bytes
  - max voice file size is 20 MB

### Apple shared foundation

- `FileMediaItem.voice(Client_MessageVoiceContent)` already exists.
- `FileCache.saveVoice(...)` saves voice data into the local `Voices` cache and returns `Client_MessageVoiceContent` with:
  - temporary local voice ID
  - duration
  - waveform
  - MIME type
  - local relative path
  - size
- `FileUploader.uploadVoice(...)`, `voiceProgressPublisher(...)`, `waitForUpload(voiceLocalId:)`, and `InputMedia.fromVoiceId(...)` already exist.
- `TransactionSendMessage` already:
  - creates optimistic voice messages by storing voice content in `Message.contentPayload`
  - uploads voice media
  - sends `InputMedia.voice`
- `SharedAudioPlayer` and `VoiceMessageBubble` provide shared playback/download/seek UI.
- `ComposeActions.startVoiceRecording(for:)` already sends and keeps `recordingVoice` compose status alive.

### macOS voice composer

Current files:

- `apple/InlineMac/Views/Compose/ComposeVoiceRecorder.swift`
- `apple/InlineMac/Views/Compose/ComposeVoiceRecordingViewModel.swift`
- `apple/InlineMac/Views/Compose/ComposeVoiceInputView.swift`
- `apple/InlineMac/Views/Compose/ComposeVoiceButton.swift`
- `apple/InlineMac/Views/Compose/ComposeAppKit.swift`

Behavior to preserve as the product model:

- Voice controls are installed only when `ExperimentalFeatureFlags.voiceMessagesEnabled` is true when the compose view is created.
- The mic button appears only when:
  - the composer text is empty after trimming
  - there are no attachments
  - the user is not editing
  - the user is not forwarding
  - no voice recording/review is active
- Starting recording replaces text editor, menu, emoji, attachment strip, and send button with a compact voice input row.
- Recording phase shows live waveform, duration, red indicator, and pause/finish control.
- Review phase shows play/pause, waveform seek, duration, cancel, and send.
- Sending calls `takeVoiceMediaItem()`, then sends `.sendMessage(mediaItems: [.voice])` with reply and silent-send state.
- Escape cancels and space toggles pause/play on macOS. iOS should use touch controls rather than these key handlers.

Recorder details to match:

- AAC `.m4a` via `AVAudioRecorder`
- `kAudioFormatMPEG4AAC`
- 48 kHz, mono, 32 kbps, medium quality
- meter timer every 0.05s
- waveform samples normalized to `UInt8`
- saved MIME type `audio/mp4`
- saved extension `m4a`

### Current iOS state

- iOS already has `NSMicrophoneUsageDescription`.
- iOS already has the experimental "Enable voice messages" setting.
- iOS message rows already render voice through `VoiceMessageBubble` inside `UIMessageView`.
- Voice messages are already marked multiline for iOS layout.
- iOS compose does not have:
  - mic button/control
  - recorder
  - recording/review state
  - permission flow
  - send integration for locally recorded voice
- iOS compose attachment preview has a `.voice` fallback icon, but upload tracking is incomplete:
  - `uploadProgressPublisher(for: .voice)` returns nil
  - `startAttachmentUpload(.voice)` is a no-op
  - this should be fixed if iOS sends voice through the attachment preview path

## Telegram Technical Takeaways

Use these as implementation guidance only:

- Keep recording as an explicit state machine, not loosely coupled booleans.
- Stop active media playback before starting/resuming a recording.
- Keep recorder work off fragile UI code paths and clean up temp files on cancel/deinit.
- Reject very short recordings before enqueueing/sending. Telegram uses `< 0.5s`; use the same technical threshold.
- Generate bounded waveform data. Telegram compresses to about 100 samples and then 5-bit packs it. Inline can keep raw `UInt8` samples because `AudioWaveformView` already consumes byte samples, but stay far below the server's 2048-byte cap.
- Treat audio session acquisition/failure as part of the recorder lifecycle. If the audio session is interrupted or cannot start, stop recording and return to idle/review safely.
- Playback should be centralized by media identity, not owned by each message cell. Inline already has this with `SharedAudioPlayer`.

Do not copy for V1:

- press-hold to record
- slide left to cancel
- slide up to lock
- trim handles
- view-once voice
- resume-from-draft
- Opus/Ogg encoder dependency
- Telegram's overlay input UX

## Second-Pass Review

The first-pass plan is directionally right: backend/protocol are ready, received-message playback mostly exists, and the missing slice is iOS compose recording plus a small upload-tracking cleanup. The main decisions left are implementation shape, not product semantics.

Recommended V1 path:

- Keep the product UX aligned with macOS: tap mic, record into a compact composer row, stop into review, then cancel/play/send.
- Use AAC `.m4a`/`audio/mp4` for iOS V1 because macOS already uses it and the server validates it.
- Send from the voice review row directly through `TransactionSendMessage(mediaItems: [.voice])`.
- Use a SwiftUI-hosted voice input row inside the existing UIKit composer, unless a build/perf check shows hosting overhead or sizing instability.
- Keep recorder/view-model iOS-local for the first implementation, then extract the pure recorder later only if the duplicated code starts drifting.

### Decision Weights

Scoring: 5 is best. Weights reflect this feature's current risk profile.

- Product consistency with macOS: 30%
- Implementation risk: 25%
- Maintainability: 20%
- Runtime/performance risk: 15%
- Future extensibility: 10%

### Proposal A: iOS-local recorder and view model, SwiftUI-hosted review row

Weighted score: 4.35 / 5

Shape:

- Add iOS-local `ComposeVoiceRecorder`, `ComposeVoiceRecordingViewModel`, and `ComposeVoiceInputView`.
- Mirror macOS phases and send behavior.
- Host `ComposeVoiceInputView` inside `ComposeView` with `UIHostingController` or `UIHostingConfiguration`-style containment.

Pros:

- Best match to macOS product model with minimal cross-platform churn.
- Lets iOS use `AudioWaveformView` directly instead of duplicating waveform drawing.
- Keeps risky compose layout work scoped to iOS.
- Low backend risk because it uses the existing `.voice` media path.

Cons:

- Some recorder/view-model duplication with macOS.
- UIKit/SwiftUI hosting inside a latency-sensitive composer needs sizing and lifecycle validation.
- We must be careful not to let SwiftUI state trigger layout churn while recording.

Recommendation:

- Use this for V1. Keep the SwiftUI view small and stable: one horizontal row, fixed height, explicit callbacks, no live service calls from `body`.

### Proposal B: Extract shared Apple voice recorder/view model first

Weighted score: 3.65 / 5

Shape:

- Move the pure recorder and possibly most of the view model into `InlineKit` or a shared Apple UI package.
- macOS and iOS both call the shared implementation.

Pros:

- Better long-term maintainability.
- Reduces duplicate encoding, waveform, cleanup, and duration logic.
- Makes future changes like max duration, silence handling, or audio-session tuning easier to keep consistent.

Cons:

- Touches working macOS voice code before iOS is proven.
- Harder boundary: permission prompts, toasts, keyboard handlers, platform audio-session details, and send state differ.
- More package/API surface to stabilize before we know the iOS needs.

Recommendation:

- Defer. After iOS ships and both platforms pass manual recording/playback tests, extract only the pure recorder if the code is clearly identical. Keep permission/UI view models platform-owned.

### Proposal C: UIKit-native voice row instead of SwiftUI-hosted row

Weighted score: 3.95 / 5

Shape:

- Build the iOS review/recording row entirely in UIKit.
- Either wrap `AudioWaveformView` in a hosting subview just for waveform, or write a small UIKit waveform view.

Pros:

- Most predictable inside the current UIKit compose layout.
- Easier to avoid SwiftUI invalidation during a 20 Hz metering stream.
- Fits the surrounding legacy iOS composer style.

Cons:

- Duplicates UI behavior already implemented in shared SwiftUI waveform and macOS voice row.
- More custom UIKit drawing/state code.
- Higher chance of visual drift from macOS.

Recommendation:

- Keep as fallback if SwiftUI hosting causes layout churn, touch handling issues, or build complexity. If used, still reuse `AudioWaveformView` only if the hosting boundary is contained and stable.

### Proposal D: Treat recorded voice as a normal compose attachment preview

Weighted score: 2.90 / 5

Shape:

- Recording creates `.voice` and adds it to `attachmentItems`.
- Existing attachment preview strip shows waveform/icon and normal send button sends it.

Pros:

- Reuses attachment send state and upload tracking after `.voice` gaps are fixed.
- Could support "record and then add text" naturally if desired later.

Cons:

- Does not match macOS UX, where active voice has a dedicated compact composer row.
- The current attachment strip is thumbnail/file oriented, not a voice review control.
- Forces voice preview/playback into an attachment abstraction that is already incomplete for `.voice`.
- Higher risk of odd behavior with text, drafts, pending videos, and forwards.

Recommendation:

- Do not use for V1. Still fix `.voice` upload tracking because shared resend/attachment paths already know about voice.

### Proposal E: Opus/Ogg on iOS V1

Weighted score: 2.75 / 5

Shape:

- Add or integrate an Opus/Ogg encoder and upload `audio/ogg`.

Pros:

- Better voice compression.
- Matches Telegram's technical media format.
- More future-proof for non-Apple clients if we standardize on Opus later.

Cons:

- New native dependency and packaging risk.
- More testing burden for recording, playback, save/share, transcription, and upload validation.
- macOS already ships AAC `.m4a`; using a different iOS codec increases cross-platform variance.
- Server already accepts Apple AAC.

Recommendation:

- Defer. Keep server support for Ogg, but ship iOS V1 with `.m4a`/`audio/mp4` and revisit Opus only if bandwidth/storage becomes a real problem.

### Proposal F: AudioEngine/AudioUnit recorder instead of AVAudioRecorder

Weighted score: 3.10 / 5

Shape:

- Use `AVAudioEngine` or lower-level AudioUnit capture to own PCM samples, waveform, and encoding more directly.

Pros:

- Better control over metering, interruptions, silence detection, and future live upload/transcoding.
- Closer to Telegram's technical architecture.

Cons:

- More implementation and interruption complexity.
- Requires custom file writing/encoding decisions.
- Unnecessary for the current server-accepted AAC path.

Recommendation:

- Do not use for V1. `AVAudioRecorder` is enough for compact voice messages and mirrors current macOS.

## Second-Pass Adjustments To The Plan

- Prefer a SwiftUI-hosted voice input row for V1, but make it fixed-height and callback-driven.
- Add a fallback note: switch to UIKit-native row if hosting causes compose layout churn.
- Keep iOS recorder/view-model local first; defer shared extraction.
- Make `.voice` attachment upload tracking a small required cleanup, but not the main send surface.
- Add a hard minimum-duration rule of 0.5s before `FileCache.saveVoice`.
- Add explicit interruption/background handling to Phase 1, not only manual validation.

## iOS Implementation Plan

### Phase 1: iOS recorder and view model

Add iOS-local files under `apple/InlineIOS/Features/Compose/Voice/`:

- `ComposeVoiceRecorder.swift`
- `ComposeVoiceRecordingViewModel.swift`
- `ComposeVoiceInputView.swift` or UIKit equivalent
- `ComposeVoiceButton.swift` or a factory method beside existing compose buttons

Start by porting the macOS recorder and view model shape with iOS-specific permission and UI hooks. Avoid refactoring macOS in this slice unless the extraction is mechanical and low risk.

Recorder rules:

- Output `.m4a` with MIME `audio/mp4`.
- Use the same settings as macOS unless testing shows an iOS-specific issue:
  - 48 kHz
  - mono
  - 32 kbps
  - AAC
- Use `AVAudioApplication.shared.recordPermission` and `AVAudioApplication.requestRecordPermission` for iOS 18+.
- Configure `AVAudioSession` for recording, and restore/deactivate when done:
  - category likely `.playAndRecord`
  - mode `.spokenAudio` or `.default` after testing
  - options should be conservative; avoid forcing speaker unless playback/recording tests require it
- Pause any active `SharedAudioPlayer` voice before recording starts.
- Emit duration and live samples at roughly 20 Hz.
- Keep waveform output to 96 or 100 bytes.
- Discard recordings under 0.5s with haptic/error feedback.
- Observe audio interruptions, route changes, and app backgrounding; stop safely and return to review or idle based on whether a valid recording exists.
- Always remove temp files on cancel, failed start, failed finish, and deinit.

View-model rules:

- Mirror macOS states:
  - `idle`
  - `recording`
  - `review`
- Own recorder, local preview playback, timers, and `ComposeActions.startVoiceRecording(for:)` cleanup.
- `takeVoiceMediaItem()` should call `FileCache.saveVoice(...)` and return `.voice(voice)`.
- Do not call DB/network APIs from SwiftUI/UIKit body/layout code.
- If SwiftUI is used for the input row, keep the view fixed-height and pass all side effects through explicit callbacks.

### Phase 2: iOS compose integration

Integrate into `apple/InlineIOS/Features/Compose/ComposeView.swift`.

Behavior should match the macOS product model:

- Show mic button only when the composer can start voice recording:
  - voice flag enabled
  - text is empty after trimming attachment replacement markers
  - no attachments
  - no pending videos
  - not editing
  - not forwarding
  - peer/chat are available
  - voice state is idle
- When voice is active:
  - hide text view, plus button if needed, attachment strip, and send button
  - show the compact voice input row inside the compose container
  - keep height at the normal compose minimum unless the current iOS layout needs a small fixed voice height
- In recording state:
  - show live waveform, duration, red recording indicator, stop/pause control, and cancel
- In review state:
  - show play/pause, seekable waveform, duration, cancel, and send
- `sendTapped` should:
  - send voice if phase is `review`
  - ignore normal text send if voice is actively recording
- Send should preserve:
  - current reply target
  - silent send if supported by the iOS composer state
  - normal optimistic send path through `Transactions.shared.mutate(.sendMessage(...))`
- Clear reply/draft and reset compose state after successful enqueue, same as normal send.

Do not send voice through generic document/audio file paths.

### Phase 3: upload tracking and resend correctness

Fix the existing iOS compose voice attachment gaps:

- `uploadProgressPublisher(for: .voice)` should return `FileUploader.shared.voiceProgressPublisher(voiceLocalId:)`.
- `startAttachmentUpload(.voice)` should call `FileUploader.shared.uploadVoice(voiceContent:)`.
- Cancellation should call `FileUploader.shared.cancelVoiceUpload(voiceLocalId:)` or the existing upload-id cancel path.
- If the voice composer sends directly without rendering an attachment preview, still add these fixes because resend/queued/preview paths already have `.voice` support in shared models.

Add focused tests where feasible:

- `FileMediaItemLocalFileURLTests` should include `.voice`.
- `FileUploadProgressTests` should include voice progress publisher behavior if existing helpers make this cheap.
- Add a small pure-state test for voice send eligibility if `ComposeSendEligibility` or a new helper is extended.

### Phase 4: polish received/sent message UI

Validate iOS `VoiceMessageBubble` in actual message rows:

- outgoing optimistic voice with local path plays before upload completes
- outgoing message keeps local path after server update merges remote ID/CDN URL
- incoming voice auto-downloads under local policy
- download progress, cancel, retry, and duration states render correctly
- voice-only metadata/status placement is acceptable in bubble layout
- accessibility labels are present for record, stop, cancel, play, seek, and send

Only adjust shared `VoiceMessageBubble` if iOS exposes a real issue; avoid platform-specific forks unless necessary.

### Phase 5: verification

Run focused checks:

- `cd apple/InlineKit && swift build`
- `cd apple/InlineKit && swift test --filter FileMediaItemLocalFileURLTests`
- `cd apple/InlineUI && swift build`
- iOS app build:
  - `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (iOS)" -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`

Manual simulator/device checks:

- feature flag off: no mic UI, existing composer unaffected
- feature flag on: mic appears only for empty composer
- permission denied: clear prompt/open-settings path, no broken active state
- start, stop to review, play/pause, seek, cancel
- send voice in regular chat
- send voice as reply
- send voice silently if iOS composer exposes silent mode
- recording interrupted by app backgrounding/call/audio route change stops safely
- message is playable immediately from local file, then remains playable after upload/server update

## Production Readiness Notes

- Security: do not log file paths with sensitive user context beyond existing local debug logs; never print audio data or auth tokens.
- Performance: recorder metering must be lightweight and must not write to DB or upload from UI render paths.
- Storage: temp recorder files must be removed; saved voice files should live only in the existing `Voices` cache.
- Compatibility: use modern iOS microphone permission APIs because the app minimum is iOS 18.
- Scope: keep this iOS-only. Backend/protocol are already present; do not expand to web, bot API, trim, transcription UI, or Telegram-style gestures in this slice.
