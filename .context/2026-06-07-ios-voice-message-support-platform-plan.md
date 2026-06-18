# iOS Voice Message Support Platform Plan

Date: 2026-06-07
Last revised: 2026-06-12

## Goal

Implement iOS voice message recording and sending using Inline's existing voice media backend, shared playback UI, and the current macOS voice composer as the product model.

Telegram is only a technical reference for recorder lifecycle, audio capture, waveform handling, cleanup, and playback coordination. Do not copy Telegram's press-hold, slide-to-cancel, lock, trim, or other chat-input UX unless we explicitly decide to later.

## Current Recommendation

Ship V1 as a small iOS-only implementation using the existing voice media stack:

- Use the macOS product model: tap mic, record in a compact composer row, stop into review, then cancel/play/send.
- Use AAC `.m4a` with MIME `audio/mp4`.
- Use the existing direct voice send path through `TransactionSendMessage(mediaItems: [.voice])`.
- Build the active voice composer as a fixed-height SwiftUI row hosted inside the current UIKit `ComposeView`.
- Keep voice code in its own folder with its own view model and view. `ComposeView` should be a thin host that talks to voice through a small API surface.
- Keep recorder and view-model code iOS-local for V1. Extract shared Apple recorder code only after iOS proves the same lifecycle and tests as macOS.
- Treat Telegram as a recorder/playback lifecycle reference only, not a UX reference.

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

## Third-Pass Revision

This revision makes Proposal A the definitive V1 plan and turns the work into small implementation slices with clear acceptance criteria.

### Closed Decisions

- Primary implementation: iOS-local recorder/view model plus a SwiftUI-hosted active voice row inside the existing UIKit composer.
- Fallback implementation: switch only the row to UIKit if the hosted SwiftUI row causes measurable compose height jitter, input lag, gesture conflicts, or excessive layout invalidation during 20 Hz waveform updates.
- Module boundary: all recorder, audio-session, waveform, playback-preview, permission, and active voice UI state belongs under `apple/InlineIOS/Features/Compose/Voice/`. `ComposeView` should not grow voice-specific audio logic.
- Feature flag behavior: match macOS. Voice controls are installed/read when the composer is created; live toggling in Settings is not required for V1 because the current settings copy already says experimental UI changes may require restart.
- Recording format: AAC `.m4a`, MIME `audio/mp4`, 48 kHz, mono, 32 kbps, medium quality.
- Audio session: start conservatively with `.playAndRecord` and `.default`; do not force speaker routing. Try `.spokenAudio` only if device tests show better interruption/route behavior without hurting recording.
- Minimum duration: reject recordings under 0.5s before `FileCache.saveVoice`.
- Maximum duration: no product-visible cap in V1. Enforce the existing 20 MB server cap defensively by failing save/send if the encoded file is too large.
- Send surface: voice review sends directly through `.sendMessage(mediaItems: [.voice])`, not through document/audio/attachment paths.
- Silent sends: iOS already has "Send without notification" on the normal send button. The voice review send control should call the same send helper with an optional `MessageSendMode`, and should expose the silent action if it can do so without crowding the compact row.
- Sharing: do not refactor macOS first. Extract a shared recorder later only if the iOS implementation proves the lifecycle is actually identical.

## V1 Implementation Slices

### Slice 0: Voice Module Boundary

Create a contained voice feature boundary before adding recorder logic.

Voice-owned responsibilities:

- microphone permission checks and request flow
- `AVAudioSession` setup/teardown
- `AVAudioRecorder` lifecycle
- interruption, route-change, background handling
- live metering and waveform generation
- local preview playback state
- temp-file cleanup
- active voice row UI state and callbacks
- conversion from finished recording to `FileMediaItem.voice`

Compose-owned responsibilities:

- decide whether voice can be shown from broad compose state
- host/show/hide the voice row
- pass peer/chat/reply/silent-send context into a narrow send callback
- reset normal compose UI after voice send/cancel

Allowed boundary API:

- `start(peerId:)`
- `cancel()`
- `send(mode:) async throws -> FileMediaItem`
- `phase`
- `canSend`
- simple render state for duration, waveform, and playback controls

Do not let `ComposeView` directly own recorder instances, audio sessions, waveform buffers, temp URLs, or preview player state.

Acceptance criteria:

- New voice files live under `apple/InlineIOS/Features/Compose/Voice/`.
- `ComposeView.swift` contains hosting, eligibility, and send/cancel glue only.
- Voice internals can be unit-tested or previewed without instantiating the full compose view.

### Slice 1: Eligibility and State Boundaries

Add a small, pure eligibility helper before touching the composer layout. It can live near `ComposeView.swift` unless a better existing compose helper exists.

Inputs:

- feature flag
- text after trimming attachment replacement markers
- attachment count
- pending video count
- editing state
- forward context
- peer/chat availability
- current voice phase

Acceptance criteria:

- Mic is eligible only for an idle, empty composer with no attachments, no pending videos, no editing, no forwarding, and valid peer/chat.
- The eligibility helper can be unit-tested without UIKit if it is extracted into a pure type.
- Existing text/file send eligibility is unchanged.

### Slice 2: Recorder and View Model

Add iOS-local files under `apple/InlineIOS/Features/Compose/Voice/`:

- `ComposeVoiceRecorder.swift`
- `ComposeVoiceRecordingViewModel.swift`
- `ComposeVoiceInputView.swift`
- `ComposeVoiceButton.swift` or a factory method in `ComposeView+UIViews.swift`

Recorder requirements:

- Request permission with the iOS 18+ `AVAudioApplication` APIs before recorder allocation.
- Configure and deactivate `AVAudioSession` inside recorder lifecycle.
- Pause active `SharedAudioPlayer` playback before starting or resuming recording.
- Emit duration and live meter samples at about 20 Hz.
- Produce a bounded waveform of 96 or 100 raw `UInt8` samples.
- Finish into review when a valid file exists; return to idle when the file is invalid or too short.
- Stop safely on audio interruption, route change, and app backgrounding.
- Remove temp files on cancel, failed start, failed finish, failed save, and deinit.

View-model requirements:

- Use one explicit phase enum: `idle`, `recording`, `review`.
- Own recorder, local preview playback, timers, and `ComposeActions.startVoiceRecording(for:)` status cleanup.
- Keep side effects out of SwiftUI `body` and UIKit layout methods.
- Expose a small public surface to compose: phase/render state, start, cancel, send/take media, and optional silent-send capability.
- `takeVoiceMediaItem()` calls `FileCache.saveVoice(...)` and returns `.voice(voice)`.

Acceptance criteria:

- Permission denied leaves the composer idle and does not create a stuck recording status.
- A sub-0.5s recording cannot be sent.
- A valid recording becomes a local `.voice` media item with duration, MIME type, size, local path, and waveform.
- Temp files do not survive cancel or failed finish.

### Slice 3: Hosted Voice Row

Build `ComposeVoiceInputView` as a small render/control surface, not a service owner.

UI shape:

- Fixed-height horizontal row hosted by the existing UIKit `ComposeView`.
- Recording: cancel, red recording indicator, live waveform, duration, stop/pause.
- Review: cancel, play/pause, seekable waveform, duration, send.
- Accessibility labels for record, stop, pause, cancel, play, seek, send, and silent send if exposed.

Performance rules:

- UIKit owns the view model; SwiftUI receives explicit state/model input and callback closures.
- Keep the host container stable and only show/hide it when the voice phase changes.
- Keep changing observation scope narrow so 20 Hz metering updates re-render only the voice row.
- Do not do formatting, file reads, DB reads, upload checks, or audio-session work from `body`.

Acceptance criteria:

- The row does not change compose width/height on each meter tick.
- Typing performance in normal compose is unchanged when voice is idle.
- Voice review playback works before upload because it uses the saved local file.

### Slice 4: Compose Integration

Integrate into:

- `apple/InlineIOS/Features/Compose/ComposeView.swift`
- `apple/InlineIOS/Features/Compose/ComposeView+UIViews.swift`

Behavior:

- Show the mic button only when the eligibility helper returns true.
- Hide text view, plus button if needed, attachment strip, and normal send button while voice is active.
- Keep the active row inside the compose container with stable constraints.
- Interact with the voice feature only through the voice view model boundary; do not add recorder/audio-session/temp-file logic to compose.
- `sendTapped` sends voice when phase is `review`, ignores normal sends while actively recording, and otherwise keeps current text/media behavior.
- Voice send preserves reply target and silent-send mode.
- Successful enqueue clears reply/draft/voice state the same way normal send clears composer state.
- Cancelling voice returns to the exact idle composer state without discarding unrelated text or attachment state.

Acceptance criteria:

- Feature flag off has no visible or behavioral composer change.
- Feature flag on shows mic only for eligible empty compose.
- Recording/review state survives ordinary layout passes and keyboard frame changes.
- Normal text, file, edit, forward, reply, and silent send paths still work.

### Slice 5: Upload Tracking and Resend Correctness

Fix the existing iOS `.voice` gaps even though V1 sends from the review row:

- `uploadProgressPublisher(for: .voice)` returns `FileUploader.shared.voiceProgressPublisher(voiceLocalId:)`.
- `startAttachmentUpload(.voice)` calls `FileUploader.shared.uploadVoice(voiceContent:)`.
- Cancel paths use the voice upload cancellation mechanism if available; otherwise route through the shared upload ID cancellation path.
- Add `.voice` coverage to `FileMediaItemLocalFileURLTests`.
- Add voice upload progress tests only if the existing test helpers make this focused and cheap.

Acceptance criteria:

- Queued/resend flows can upload voice media using the same progress system as photo/video/document.
- Local file URL lookup works for `.voice`.
- Existing photo/video/document upload tests keep passing.

### Slice 6: Message UI Validation

Validate current iOS `VoiceMessageBubble` before changing shared UI:

- outgoing optimistic voice plays from local path before upload completes
- uploaded outgoing voice remains playable after server update/CDN URL merge
- incoming voice downloads and plays under existing local-cache policy
- download progress, retry, cancel, and duration states render correctly
- voice-only metadata/status placement is acceptable in the iOS bubble

Only patch shared `VoiceMessageBubble` if iOS exposes a real bug. Do not fork the voice bubble for iOS unless shared behavior cannot satisfy both platforms.

## Verification Plan

Focused checks:

- `cd apple/InlineKit && swift build`
- `cd apple/InlineKit && swift test --filter FileMediaItemLocalFileURLTests`
- `cd apple/InlineUI && swift build`
- `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (iOS)" -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`

Manual checks:

- feature flag off: no mic UI, existing composer unaffected
- feature flag on: mic appears only for eligible empty composer
- permission allowed, denied, and previously denied paths
- start, stop to review, play/pause, seek, cancel
- valid send in regular chat
- send as reply
- send without notification from voice review if exposed
- recording interrupted by app backgrounding, call/audio interruption, and route change
- local playback immediately after send, then playback after upload/server update
- normal text, media, edit, forward, reply, and silent-send flows after cancelling voice

## Non-Goals For V1

- Telegram press-hold, slide-to-cancel, slide-to-lock, trim, view-once, or overlay UX
- Opus/Ogg encoder dependency
- transcription UI
- waveform packing changes
- voice drafts/resume after app relaunch
- backend/protocol changes
- web, bot API, desktop, or CLI changes

## Production Readiness Notes

- Security: do not log audio data, auth data, or user-sensitive file paths. Keep permission errors user-visible but not content-revealing.
- Performance: recorder metering must stay lightweight and must not trigger broad composer or message-list invalidation.
- Storage: temp recorder files must be removed; committed voice files should live only in the existing `Voices` cache.
- Compatibility: use modern iOS microphone permission APIs because the app minimum is iOS 18.
- Backward compatibility: server/protocol already support voice, so V1 should not require migrations or new realtime contracts.
- Release safety: keep the feature behind the existing experimental voice flag until device testing covers permission, interruption, local playback, upload, and resend behavior.
