# Voice Messages Plan

## Recommendation

Implement voice messages as a **first-class media type** on the wire and server: `voice` beside `photo`, `video`, `document`, and `nudge`.

Do **not** overload generic documents for the shipped feature.

On Apple clients, do **not** introduce a parallel local `voice` table in V1. Instead, add a new **binary content payload blob** on the local `message` row and store client-side voice content there first. That gives us room to grow voice and later move more client-only content into the same pattern without adding joins everywhere.

Why:
- The current architecture is already typed around distinct media kinds in proto, server persistence, encoders, Apple models, optimistic sends, and upload paths.
- Voice messages need dedicated semantics: recording UX, duration, waveform, inline playback, better notification copy, and likely their own compose action and media filtering later.
- Overloading `document` would save some schema churn but would push voice-specific conditionals into every document path and make generic audio files vs recorded voice notes ambiguous.
- A local message-row blob matches the repo’s existing protobuf-blob pattern and lets Apple clients avoid heavy joins for voice, transcription, and future richer content fields.

## Current State

- Message media only supports `photo | video | document | nudge` in proto today: [proto/core.proto](/Users/mo/dev/inline/proto/core.proto#L438), [proto/core.proto](/Users/mo/dev/inline/proto/core.proto#L1106)
- `Document` has no voice metadata like duration, waveform, or a voice flag: [proto/core.proto](/Users/mo/dev/inline/proto/core.proto#L483)
- Server message persistence only knows `mediaType = photo|video|document|nudge` plus `photoId` / `videoId` / `documentId`: [server/src/db/schema/messages.ts](/Users/mo/dev/inline/server/src/db/schema/messages.ts#L71)
- Server media tables only model `photos`, `documents`, and `videos`: [server/src/db/schema/media.ts](/Users/mo/dev/inline/server/src/db/schema/media.ts#L63)
- Uploads are typed as `photo | video | document` only: [server/src/methods/uploadFile.ts](/Users/mo/dev/inline/server/src/methods/uploadFile.ts#L16), [apple/InlineKit/Sources/InlineKit/Models/File.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Models/File.swift#L14)
- Apple send flows only handle `FileMediaItem.photo|document|video`: [apple/InlineKit/Sources/InlineKit/Files/FileTypes.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Files/FileTypes.swift#L31), [apple/InlineIOS/Features/Compose/ComposeView.swift](/Users/mo/dev/inline/apple/InlineIOS/Features/Compose/ComposeView.swift#L431), [apple/InlineMac/Views/Compose/ComposeAppKit.swift](/Users/mo/dev/inline/apple/InlineMac/Views/Compose/ComposeAppKit.swift#L935)
- Apple can render generic audio files only as documents with an audio icon, not inline voice playback: [apple/InlineKit/Tests/InlineKitTests/DocumentIconResolverTests.swift](/Users/mo/dev/inline/apple/InlineKit/Tests/InlineKitTests/DocumentIconResolverTests.swift#L29), [apple/InlineIOS/Features/Media/DocumentView.swift](/Users/mo/dev/inline/apple/InlineIOS/Features/Media/DocumentView.swift#L9)
- The active Apple seams are still the legacy platform composers and message views, not the new shared UI packages: [apple/InlineIOS/Features/Chat/ChatViewUIKit.swift](/Users/mo/dev/inline/apple/InlineIOS/Features/Chat/ChatViewUIKit.swift#L28), [apple/InlineMac/Views/ChatView/ChatViewAppKit.swift](/Users/mo/dev/inline/apple/InlineMac/Views/ChatView/ChatViewAppKit.swift#L204), [apple/InlineIOSUI/Sources/InlineIOSUI/InlineIOSUI.swift](/Users/mo/dev/inline/apple/InlineIOSUI/Sources/InlineIOSUI/InlineIOSUI.swift#L1)
- I did not find an existing audio recorder or inline audio player path under `apple/`; only video playback has explicit AV playback/session handling today: [apple/InlineIOS/Features/Media/ImageViewerController.swift](/Users/mo/dev/inline/apple/InlineIOS/Features/Media/ImageViewerController.swift#L536)
- The local `message` table is simple today, but InlineKit already uses protobuf blobs for local state such as `draftMessage` and `entities`, which is the right pattern for a new message-row content payload: [apple/InlineKit/Sources/InlineKit/Database.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Database.swift#L137), [apple/InlineKit/Sources/InlineKit/Database.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Database.swift#L507), [apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolDraftMessage.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolDraftMessage.swift#L30)

## Telegram Findings That Apply

- Telegram iOS records and sends voice as **Ogg Opus**: it imports `OpusBinding`, writes through `TGOggOpusWriter`, and sends voice messages with MIME `audio/ogg`: [/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramUI/Sources/ManagedAudioRecorder.swift](/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramUI/Sources/ManagedAudioRecorder.swift#L9), [/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramUI/Sources/ManagedAudioRecorder.swift](/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramUI/Sources/ManagedAudioRecorder.swift#L162), [/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift](/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift#L405)
- Telegram has a **shared playback model** that distinguishes `voice` from `music` and persists independently of a single chat view: [/Users/mo/dev/telegram/Telegram-iOS/submodules/AccountContext/Sources/SharedMediaPlayer.swift](/Users/mo/dev/telegram/Telegram-iOS/submodules/AccountContext/Sources/SharedMediaPlayer.swift#L8)
- Telegram also treats transcription as a later message-level enhancement, not part of the original recording/send path, which matches the staged approach requested here.

## Proposed V1 Shape

### Voice Format And Codec

Recommended canonical voice format:
- **Ogg Opus**
- MIME: `audio/ogg`

Reason:
- Better speech compression than AAC for voice notes.
- Aligns with Telegram’s proven voice-message path.
- Better long-term format if Inline eventually expands beyond Apple-first clients.

Implementation note:
- It is acceptable to use a temporary local intermediate during recording/processing if that simplifies capture, but the **uploaded file**, **server-stored asset**, and **local voice cache** should converge on Ogg Opus.

### Protocol And Server

Add:
- `Voice`
- `MessageVoice`
- `InputMediaVoice`

Update:
- `MessageMedia.oneof media += voice`
- `InputMedia.oneof media += voice`

Suggested `Voice` fields:
- `id`
- `date`
- `duration`
- `size`
- `mime_type`
- `cdn_url`
- `bytes waveform`

Notes:
- Keep waveform as raw bytes for V1. Telegram packs to 5-bit samples, but we do not need to copy that optimization immediately.
- Use seconds for duration to match existing media patterns.
- Leave room for a future transcription update without requiring a breaking media redesign.

Add a new `voices` table alongside `videos`:
- `id`
- `file_id`
- `date`
- `duration`
- `waveform`

Update `messages`:
- extend `mediaType` enum with `"voice"`
- add `voiceId`

Rationale:
- This matches the existing typed-media pattern better than stuffing voice metadata into `documents`.
- It keeps future behavior clean for forwarding, filtering, notifications, and analytics.

### Apple Client Storage Shape

Add a new blob field on local `message` rows, for example:
- `contentPayload` or `binaryContent`

Store a typed protobuf payload there, following the same pattern used for `DraftMessage`:
- local proto message
- `DatabaseValueConvertible`
- helper wrappers for read/write/merge

Suggested payload direction:
- `voice`
  - `voiceId`
  - `duration`
  - `waveform`
  - `mimeType`
  - `cdnUrl`
  - `localRelativePath`
  - optional future `transcription`
  - optional future `transcriptionState`

Rationale:
- avoids adding local `voice` tables and extra joins in V1
- gives a clean place for voice-only client state and future transcription state
- can later expand to other richer message payloads if this pattern works well

### Upload Shape

Add `voice` as a typed upload branch:
- multipart file
- required `duration`
- required `waveform` (base64 or bytes encoded as form field)
- optional explicit `mimeType` validation via the uploaded file metadata

Server-first ordering for V1:
1. upload changes
2. server DB
3. protocol exposure
4. server tests

## Scope

In scope for V1:
- `proto/`
- `server/`
- `apple/InlineKit`
- `apple/InlineIOSUI`
- `apple/InlineMacUI`
- `apple/InlineIOS`
- `apple/InlineMac`

Out of scope for V1:
- `web/`
- bot API/media send support
- trim/edit preview
- view-once voice messages
- special search/media filters beyond basic correctness

Explicitly deferred but planned:
- transcription via later server update
- sidebar/global “currently playing” UI built on the centralized player state

## Implementation Tracking

Last updated: `2026-03-09`

Status legend:
- `done`
- `in_progress`
- `pending`
- `blocked`

### Current Slice

- `in_progress` Feature gating on Apple
  - `done` Added a shared Apple experimental flag key/helper in `InlineKit`
  - `done` Added "Enable voice messages" toggles to iOS and macOS experimental settings
  - `done` Gated Apple-side unsupported fallback on the voice experimental flag
  - `done` Gated initial macOS/iOS render paths on the voice experimental flag
  - `pending` Gate record/send UI once recorder flows exist

- `in_progress` Phase 1: Upload groundwork + server DB
  - `done` Added `voice` to server file/upload typing
  - `done` Added server voice metadata validation for `audio/ogg` uploads plus waveform parsing
  - `done` Added `uploadVoice.ts`
  - `done` Added `voices` schema and `messages.voiceId`
  - `done` Added file/message model support for loading and cloning voice rows
  - `done` Generated and reviewed Drizzle migration `0064_add-voice-media.sql`
  - `done` Added focused upload validation tests for voice metadata

- `in_progress` Phase 2: Protocol + server message wiring + tests
  - `done` Extended `proto/core.proto` with `Voice`, `MessageVoice`, `InputMediaVoice`, `voice` media cases, and `RECORDING_VOICE`
  - `done` Added server message send/forward/encode wiring for `voice`
  - `done` Added `encodeVoice.ts`
  - `done` Updated notification/body formatting for voice messages
  - `done` Added server-side compose-action string mapping for `recordingVoice`
  - `done` Added Apple-side compose-action mapping for `recordingVoice`
  - `done` Regenerated protocol outputs (TS + Swift)
  - `done` Added and cleaned up focused server tests for encode/send/forward/upload/compose
  - `done` Ran server typecheck and focused voice-related test suite successfully

- `done` Phase 3: Shared Apple foundation
  - `done` Compose-action enum plumbing on Apple now includes `recordingVoice`
  - `done` local message-row blob payload (`Message.contentPayload`) plus client proto helpers
  - `done` local voice cache directory and persistence helpers
  - `done` centralized shared player in `InlineKit`
  - `done` Apple upload/download voice helpers and optimistic-send plumbing
  - `done` `InlineKit` package build passed after the shared voice changes
  - `blocked` `InlineUI` package build is currently blocked by unrelated existing file [InlineTinyThumbnailBackgroundView.swift](/Users/mo/dev/inline/apple/InlineUI/Sources/InlineUI/InlineTinyThumbnailBackgroundView.swift#L60) having a public/private visibility mismatch; voice-specific `VoiceMessageBubble` issues were fixed

- `pending` Phase 4: macOS Record
  - `pending` recorder implementation
  - `pending` compose/send integration

- `in_progress` Phase 5: macOS Render + Playback
  - `done` Added shared `VoiceMessageBubble` render surface
  - `done` Added centralized playback state via `SharedAudioPlayer`
  - `done` Wired voice into macOS message sizing for bubble and minimal layouts
  - `done` Wired voice into the macOS document slot for regular and minimal message views
  - `done` Added resend handling for voice messages in macOS message views
  - `pending` focused macOS app-target compile/verification (not run because full `xcodebuild` is not allowed by default)

- `in_progress` Phase 6: iOS Render
  - `done` Added initial iOS message-row integration using the shared `VoiceMessageBubble`
  - `done` Marked voice rows as multiline so they render through the existing stacked bubble layout
  - `pending` refine iOS metadata/status placement for voice-only rows
  - `pending` focused iOS app-target compile/verification (not run because full `xcodebuild` is not allowed by default)

### Coordination Notes

- Treat this document as the source of truth for which implementation slice is active.
- Current branch state is **post-shared-foundation checkpoint**: protocol/server groundwork, Apple feature gating, local payload/cache/player plumbing, and initial macOS/iOS render wiring are in place.
- The active follow-up slice is: finish app-target verification for the render work, then implement Phase 4 macOS record/send, then continue Phase 6/7 refinements.
- The only shared-package blocker at this checkpoint is unrelated to voice work: [InlineTinyThumbnailBackgroundView.swift](/Users/mo/dev/inline/apple/InlineUI/Sources/InlineUI/InlineTinyThumbnailBackgroundView.swift#L60).

## Implementation Phases

### Phase 1: Upload Groundwork + Server DB

1. Add typed upload support first:
   - extend [server/src/modules/files/types.ts](/Users/mo/dev/inline/server/src/modules/files/types.ts)
   - extend [server/src/methods/uploadFile.ts](/Users/mo/dev/inline/server/src/methods/uploadFile.ts)
   - add `uploadVoice.ts`
   - extend [server/src/modules/files/metadata.ts](/Users/mo/dev/inline/server/src/modules/files/metadata.ts)
2. Add server DB schema:
   - `voices` table in [server/src/db/schema/media.ts](/Users/mo/dev/inline/server/src/db/schema/media.ts)
   - `voiceId` and `mediaType="voice"` in [server/src/db/schema/messages.ts](/Users/mo/dev/inline/server/src/db/schema/messages.ts)
3. Add Drizzle migration.
4. Extend file model accessors/cloners in [server/src/db/models/files.ts](/Users/mo/dev/inline/server/src/db/models/files.ts)

Exit criteria:
- server can accept and persist uploaded voice files and metadata before the new protocol path is exposed

### Phase 2: Protocol + Server Message Wiring + Tests

1. Extend `proto/core.proto` with `Voice`, `MessageVoice`, `InputMediaVoice`, and `voice` cases.
2. Regenerate protocol outputs.
3. Extend send path:
   - [server/src/realtime/handlers/messages.sendMessage.ts](/Users/mo/dev/inline/server/src/realtime/handlers/messages.sendMessage.ts)
   - [server/src/functions/messages.sendMessage.ts](/Users/mo/dev/inline/server/src/functions/messages.sendMessage.ts)
4. Extend encoders:
   - add `encodeVoice.ts`
   - update [server/src/realtime/encoders/encodeMessage.ts](/Users/mo/dev/inline/server/src/realtime/encoders/encodeMessage.ts)
5. Extend forwarding/cloning and any message fetch joins:
   - [server/src/functions/messages.forwardMessages.ts](/Users/mo/dev/inline/server/src/functions/messages.forwardMessages.ts)
   - [server/src/db/models/messages.ts](/Users/mo/dev/inline/server/src/db/models/messages.ts)
6. Add server tests now, before Apple UI work:
   - upload validation
   - send/fetch/forward/encode
   - notification copy
   - backward-compat behavior where practical

Exit criteria:
- backend can upload, persist, send, fetch, forward, and encode a voice message
- non-updated clients fail soft or ignore unknown `voice` media without server crashes

### Phase 3: Shared Apple Foundation

Build reusable voice support in shared packages first, then adapt it into app targets.

1. Add a new local message-row blob field in [apple/InlineKit/Sources/InlineKit/Database.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Database.swift)
2. Define a local protobuf payload and `DatabaseValueConvertible` helpers following the `DraftMessage` pattern.
3. Extend local `Message` accessors/helpers to expose voice content from the payload, not from a local join-heavy media table.
4. Add typed upload helpers in:
   - [apple/InlineKit/Sources/InlineKit/ApiClient.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ApiClient.swift)
   - [apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift)
5. Add explicit local voice cache support:
   - extend [apple/InlineKit/Sources/InlineKit/Files/FileHelpers.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Files/FileHelpers.swift#L5) with `.voices`
   - extend `FileCache`
   - extend `FileDownload`
6. Add a **centralized shared player** in `InlineKit` that owns playback state beyond a single chat view.
   - Model it after Telegram’s shared playback approach: [/Users/mo/dev/telegram/Telegram-iOS/submodules/AccountContext/Sources/SharedMediaPlayer.swift](/Users/mo/dev/telegram/Telegram-iOS/submodules/AccountContext/Sources/SharedMediaPlayer.swift#L8)
   - This player should later feed sidebar/global UI for actively playing voice/music.
7. Add reusable record / playback / render building blocks in `InlineIOSUI` and `InlineMacUI`, with thin adapters in app targets where coupling is unavoidable.
8. Extend transaction send path:
   - [apple/InlineKit/Sources/InlineKit/Transactions/Methods/SendMessage.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/Transactions/Methods/SendMessage.swift)
   - if still used, evaluate `Transactions2` impact too
9. Replace upload-oriented compose status for voice with a new `recordingVoice` action in protocol, `ApiComposeAction`, helpers, and shared display plumbing.
   - current upload-specific compose helpers live in [apple/InlineKit/Sources/InlineKit/ViewModels/ComposeActions.swift](/Users/mo/dev/inline/apple/InlineKit/Sources/InlineKit/ViewModels/ComposeActions.swift#L244)

Exit criteria:
- Apple shared layer can create local voice records, upload them, map server IDs back, sync them from realtime, cache them locally, and play them through a single shared player

### Phase 4: macOS Record

1. Build the first recorder integration on macOS.
2. Keep the UX explicit:
   - record
   - stop/send
   - cancel
3. Store pending local voice data in the shared message payload / voice draft state, not in the text draft path.

### Phase 5: macOS Render + Playback

1. Add a dedicated voice bubble/view on macOS using shared render/player pieces first.
2. Bind it to the centralized player, not per-row private playback objects.
3. Persist playback state while navigating between chats.
4. Adapt active seams in the legacy app target:
- compose around [apple/InlineMac/Views/Compose/ComposeAppKit.swift](/Users/mo/dev/inline/apple/InlineMac/Views/Compose/ComposeAppKit.swift#L935)
- message rendering paths that currently special-case documents

### Phase 6: iOS Render

1. Add the iOS voice bubble/view using the same shared render/player layer.
2. Bind the iOS row to the centralized player rather than creating chat-local playback state.
3. Adapt active seams in:
   - [apple/InlineIOS/Features/Message/UIMessageView.swift](/Users/mo/dev/inline/apple/InlineIOS/Features/Message/UIMessageView.swift#L219)
   - related iOS message row extensions/views

### Phase 7: iOS Record

1. Add iOS record integration after playback/render is already stable.
2. Generate waveform locally after recording and write it into the shared message payload before upload.
3. Use shared package pieces for recorder state and rendering; keep only platform-specific mic/session wiring in the app target.
4. Keep the first version smaller than Telegram:
   - no trim UI
   - no pause/resume recording draft
   - no raise-to-listen

### Phase 8: Product Integration + Future Transcription

1. Notification copy:
   - replace generic `📄 File` with `🎤 Voice message` where appropriate in [server/src/functions/messages.sendMessage.ts](/Users/mo/dev/inline/server/src/functions/messages.sendMessage.ts#L1040)
2. Replace upload-oriented compose status with `RECORDING_VOICE`:
   - add it to [proto/core.proto](/Users/mo/dev/inline/proto/core.proto#L1522)
   - wire [server/src/functions/messages.sendComposeAction.ts](/Users/mo/dev/inline/server/src/functions/messages.sendComposeAction.ts)
   - update Apple mappings in `ApiComposeAction`, `ProtocolComposeAction`, and shared compose text UI
3. Decide whether chat info/search should expose voice separately or just omit from those tabs in V1.
4. Later transcription:
   - add a dedicated server update for voice transcription
   - merge transcription into the client `message.contentPayload`
   - render it as a later enhancement, not part of V1 send
5. Add analytics/logging for failure rates, upload duration, cancel rate, and playback failures.

## Tests

### Backend

- upload validation tests for voice MIME, extension, size, duration, waveform parsing
- send/fetch/forward encode tests
- migration test coverage where practical
- notification text coverage

### Apple Shared

- payload blob encode/decode tests for local voice content
- DB migration tests
- protocol parsing tests for message sync
- uploader tests for voice metadata form construction
- centralized player state tests

### iOS/macOS

- focused build/test runs for touched Swift packages
- manual verification:
  - macOS record and send in DM
  - macOS render/playback across chat navigation
  - iOS render/playback of received voice messages
  - iOS record and send in DM
  - cancel before send
  - failed upload and resend
  - forward voice message
  - receive and play multiple voice messages
  - background/foreground during upload and playback

## Open Decisions

1. **Direct Opus pipeline vs internal intermediate**
   - Recommendation: canonical uploaded/cached format is **Ogg Opus**
   - If direct capture into Opus is awkward on Apple, allow an internal intermediate during recording, then encode to Opus before upload/cache finalization

2. **Waveform format**
   - Recommendation: raw bytes in V1
   - Revisit packed bitstream later only if payload size becomes a real problem

3. **Compose UX**
   - macOS should stay explicit and simpler
   - iOS recording can follow later once playback/render is stable

4. **Search/media filtering**
   - V1 can skip dedicated voice filters
   - add later only if chat info/search needs it

5. **Backward compatibility**
   - confirm behavior of older clients when a new `voice` oneof case appears
   - if older clients do not degrade safely, gate sending behind a minimum client version rollout

## Risks

- The biggest product risk is **backward compatibility** for older clients that do not know the new `voice` oneof.
- The biggest implementation risk is **Opus encode/decode complexity on Apple** if we decide to mirror Telegram’s canonical format immediately.
- The main performance risk is doing waveform generation, transcoding, or file IO on the main thread in Apple clients.
- The main privacy risk is microphone permission handling and temporary-recording cleanup on device.

## Rollout Order

1. upload changes
2. server DB
3. protocol
4. server tests
5. macOS record
6. macOS render & playback
7. iOS render
8. iOS record
9. internal rollout and backward-compat verification

## Historical Reference

There is an older internal note at [2026-01-23-telegram-voice-messages-notes.md](/Users/mo/dev/inline/.agent-docs/2026-01-23-telegram-voice-messages-notes.md) describing a prior first-class `voice` design and Telegram-inspired UX. It is useful as reference material, but this plan is written against the **current** repository state on `2026-03-09`.
