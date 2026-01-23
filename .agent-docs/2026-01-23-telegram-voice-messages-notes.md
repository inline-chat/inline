# Telegram Voice Messages Learnings + Inline Implementation

This doc captures everything I learned from the **local Telegram-iOS sources** plus the **Inline iOS/server/proto implementation** I added.

## Scope & sources (local only)

Telegram iOS code reviewed (local clones):
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Components/ChatTextInputMediaRecordingButton/Sources/ChatTextInputMediaRecordingButton.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/LegacyComponents/Sources/TGModernConversationInputMicButton.m`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Components/Chat/ChatRecordingPreviewInputPanelNode/Sources/ChatRecordingPreviewInputPanelNode.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/AudioWaveform/Sources/AudioWaveform.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Sources/ManagedAudioRecorder.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/ChatPresentationInterfaceState/Sources/ChatTextInputPanelState.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/ChatInterfaceState/Sources/ChatInterfaceState.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Components/Chat/ChatMessageItemView/Sources/ChatMessageItemView.swift`
- `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Components/Chat/ChatTextInputActionButtonsNode/Sources/ChatTextInputActionButtonsNode.swift`

Inline implementation files (this repo, branch `feat/voice-messages-ios`):
- Protocol: `proto/core.proto`
- Server: `server/src/db/schema/media.ts`, `server/src/db/schema/messages.ts`, `server/src/db/schema/files.ts`,
  `server/src/modules/files/metadata.ts`, `server/src/modules/files/uploadVoice.ts`,
  `server/src/modules/files/uploadAFile.ts`, `server/src/modules/files/types.ts`,
  `server/src/db/models/files.ts`, `server/src/db/models/messages.ts`,
  `server/src/realtime/encoders/encodeVoice.ts`, `server/src/realtime/encoders/encodeMessage.ts`,
  `server/src/functions/messages.sendMessage.ts`, `server/src/functions/messages.forwardMessages.ts`,
  `server/src/functions/messages.getChats.ts`, `server/src/methods/uploadFile.ts`,
  `server/src/modules/notifications/eval.ts`, `server/drizzle/0053_add_voice_messages.sql`.
- InlineKit: `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`,
  `apple/InlineKit/Sources/InlineKit/Models/Media.swift`,
  `apple/InlineKit/Sources/InlineKit/Models/Message.swift`,
  `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift`,
  `apple/InlineKit/Sources/InlineKit/Database.swift`,
  `apple/InlineKit/Sources/InlineKit/ApiClient.swift`,
  `apple/InlineKit/Sources/InlineKit/FileHelpers.swift`,
  `apple/InlineKit/Sources/InlineKit/FileCache.swift`,
  `apple/InlineKit/Sources/InlineKit/FileDownload.swift`,
  `apple/InlineKit/Sources/InlineKit/FileUpload.swift`,
  `apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolMedia.swift`,
  `apple/InlineKit/Sources/InlineKit/Transactions/Methods/SendMessage.swift`.
- Inline iOS UI: `apple/InlineIOS/Features/Compose/ComposeView.swift`,
  `apple/InlineIOS/Features/Compose/VoiceRecorder.swift`,
  `apple/InlineIOS/Features/Compose/VoiceRecordingOverlayView.swift`,
  `apple/InlineIOS/Features/Media/VoiceMessageView.swift`,
  `apple/InlineIOS/Features/Message/UIMessageView.swift`,
  `apple/InlineIOS/Features/Message/UIMessageView+extensions.swift`.

---

## Telegram iOS learnings (all areas)

### 1) Data model & file encoding
- Voice messages are stored as **TelegramMediaFile** with `.Audio(isVoice: true, duration, waveform)`, MIME `"audio/ogg"`. See `ChatControllerMediaRecording.swift`.
- Waveform encoding is a **5-bit bitstream** per sample (`bitsPerSample = 5`) with **100 samples** and peak `31`. See `AudioWaveform.swift` and `ManagedAudioRecorder.swift`.
- `AudioWaveform.makeBitstream()` packs 5-bit values; `AudioWaveform(bitstream:, bitsPerSample: 5)` reconstructs. See `AudioWaveform.swift`.

### 2) Recording state machine
- Chat input panel recording state is explicit:
  - `.audio(recorder:isLocked:)`, `.video(status:isLocked:)`, `.waitingForPreview`. See `ChatTextInputPanelState.swift`.
- Recording mode toggles between **audio/video** via `ChatTextInputMediaRecordingButtonMode` in `ChatInterfaceState.swift`.

### 3) Recorder lifecycle & pipeline (start -> preview -> send)
- Recorder comes from a **shared media manager** and can resume from an audio draft (`resumeData`). See `ChatControllerMediaRecording.swift`.
- Ending the recording:
  - Duration **< 0.5s** is discarded with error feedback.
  - Otherwise waveform and resource are stored, and `mediaDraftState` becomes `.audio(...)` for preview or send. See `ChatControllerMediaRecording.swift`.
- Sending immediately creates a local file, attaches `.Audio(isVoice: true, duration, waveform)` attributes, and enqueues the message. See `ChatControllerMediaRecording.swift`.

### 4) Gesture UX: press/hold, cancel, lock, switch modes
- **Start delay**: mic button waits **0.19s** before actually beginning recording. Releasing sooner switches mode (audio/video). See `ChatTextInputMediaRecordingButton.swift`.
- **Cancel / lock thresholds** (legacy mic button):
  - Slide **left** to cancel: `distanceX < -150` or velocity `x < -400`.
  - Slide **up** to lock: `distanceY < -110` or velocity `y < -400`.
  - Feedback thresholds (flags) at `distanceX < -100` and `distanceY < -60`. See `TGModernConversationInputMicButton.m`.
- Mic overlay uses a **dedicated presentation container/window** so gestures keep working even if touch leaves the button. See `ChatTextInputMediaRecordingButton.swift` and `TGModernConversationInputMicButton.m`.

### 5) Permissions & restrictions
- Recording is blocked when:
  - User is in an **ongoing call**.
  - Disk space check fails.
  - Chat restrictions ban sending voice/instant video.
  - Microphone (and camera for video) permission is denied. See `ChatControllerLoadDisplayNode.swift`.
- Restricted chats can show **undo/toast** or premium unlock animations. See `ChatControllerLoadDisplayNode.swift`.

### 6) Preview, pause, trim, resume
- After stop, UI enters **preview** state; waveform shown with scrubbing and trim handles. See `ChatRecordingPreviewInputPanelNode.swift`.
- Trim UI details:
  - Trim handles hidden if `duration < 2s`.
  - `minDuration = max(1.0, 56.0 * duration / waveformWidth)` for trim. See `ChatRecordingPreviewInputPanelNode.swift`.
- Resume recording from preview shows **trim warning** when applicable. See `ChatControllerMediaRecording.swift`.
- Tooltip suggestions for pausing voice messages are governed by `ApplicationSpecificNotice`. See `ChatControllerMediaRecording.swift`.

### 7) Send pipeline + view-once
- Sending voice uses `.Audio(isVoice: true, duration, waveform)` attributes.
- **View-once** voice messages use `AutoremoveTimeoutMessageAttribute` with `viewOnceTimeout`. See `ChatControllerMediaRecording.swift`.
- Preview UI has view-once affordances (some tooltips are currently commented out). See `ChatRecordingPreviewInputPanelNode.swift`.

### 8) Playback UI
- Voice playback UI uses waveform + duration label.
- If waveform is missing for instant video, Telegram falls back to a **default base64 waveform**. See `ChatMessageInteractiveFileNode.swift`.
- Voice messages are treated as **audio media** for playback; progress and scrubbing integrate with media player nodes. See `ChatMessageInteractiveFileNode.swift` and `ChatRecordingPreviewInputPanelNode.swift`.

### 9) Transcription
- Audio transcription button is **premium-gated** with trial/boost rules, disabled for secret chats, and disabled for view-once messages. See `ChatMessageInteractiveFileNode.swift`.

### 10) Accessibility
- VoiceOver:
  - Record button labels/hints for voice vs video modes. See `ChatTextInputActionButtonsNode.swift`.
  - Voice message labels and duration spoken for incoming/outgoing messages. See `ChatMessageItemView.swift`.
  - Preview waveform accessibility label. See `ChatRecordingPreviewInputPanelNode.swift`.

---

## Inline implementation (current branch)

### Protocol
- `Voice` media and `MessageVoice` wrapper added.
- `InputMediaVoice` added and integrated into `InputMedia` and `MessageMedia` oneof.
- Generated protocol updates in:
  - `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`
  - `server/packages/protocol/src/core.ts`
  - `web/packages/protocol/src/core.ts`

### Server (Bun/TS)
- **DB schema**
  - New `voices` table with `fileId`, `duration`, `waveform`, `date`. See `server/src/db/schema/media.ts`.
  - `messages.voice_id` column, `media_type` enum updated. See `server/src/db/schema/messages.ts`.
  - `files.file_type` includes `voice`. See `server/src/db/schema/files.ts`.
  - Migration: `server/drizzle/0053_add_voice_messages.sql`.
- **Upload**
  - `uploadVoice()` handles file + metadata (duration + waveform). See `server/src/modules/files/uploadVoice.ts`.
  - Validation: allowed extensions `m4a|aac`, mime types `audio/m4a|audio/mp4|audio/aac|audio/x-m4a`, size <= 40 MB, duration > 0. See `server/src/modules/files/metadata.ts`.
  - `uploadFile` endpoint accepts voice metadata (duration + base64 waveform). See `server/src/methods/uploadFile.ts`.
- **Models/Encoders**
  - `FileModel.getVoiceById`, `processFullVoice`, `cloneVoiceById`. See `server/src/db/models/files.ts`.
  - Message queries include voice relations. See `server/src/db/models/messages.ts`, `server/src/functions/messages.getChats.ts`.
  - `encodeVoice` + message encoder updates. See `server/src/realtime/encoders/encodeVoice.ts`, `encodeMessage.ts`.
- **Send/Forward**
  - `messages.sendMessage` accepts `voiceId` and sets media type.
  - `messages.forwardMessages` clones voice.
- **Notifications**
  - Notification text includes voice message indicator. See `server/src/modules/notifications/eval.ts`.

### InlineKit (Swift)
- **Models**
  - Added `Voice` + `VoiceInfo`. See `InlineKit/Models/Media.swift`.
  - `Message` parses `voice` media, `voiceId` relationship. See `InlineKit/Models/Message.swift`.
  - `FullMessage` includes `voiceInfo`. See `InlineKit/ViewModels/FullChat.swift`.
  - DB migration adds `voice` table and `message.voiceId`. See `InlineKit/Database.swift`.
- **Upload/Download**
  - `FileMediaItem.voice(VoiceInfo)` plus `FileUpload.uploadVoice`.
  - Multipart metadata includes `duration` + `waveform` (base64). See `InlineKit/ApiClient.swift`.
  - `FileCache`/`FileDownloader` handle saving/downloading voice.
  - `FileHelpers` adds `.voices` cache directory.
- **Send pipeline**
  - `SendMessage` transaction supports voice attachments and waits for upload. See `InlineKit/Transactions/Methods/SendMessage.swift`.

### Inline iOS UI

#### Recording UX
- Long-press mic to record; slide **left** to cancel and **up** to lock.
  - `cancelThreshold = 80pt`, `lockThreshold = 70pt`. See `ComposeView.swift`.
- Recording overlay shows timer + cancel/lock state. See `VoiceRecordingOverlayView.swift`.
- Minimum duration guard: **< 0.5s discarded** (matches Telegram). See `ComposeView.swift`.
- Microphone permission flow uses `AVAudioSession.recordPermission` with Settings prompt. See `ComposeView.swift`.

#### Audio encoding + waveform
- Recording format: **AAC in .m4a**, 44.1 kHz, mono, 64 kbps. See `VoiceRecorder.swift`.
- Waveform generation:
  - Reads PCM data from `AVAssetReader`, extracts 16-bit samples.
  - Buckets into **100 samples**; each is normalized to **0-255** (UInt8). See `VoiceRecorder.swift`.
- Note: This differs from Telegram's 5-bit bitstream; Inline stores raw UInt8 amplitude samples.

#### Playback UI
- `VoiceMessageView`:
  - Uses `AVAudioPlayer` with timer tick **0.05s** for progress updates.
  - Posts `voicePlaybackStarted` notification to stop other voice playback.
  - Renders waveform bars with progress color.
  - Fallback waveform (60 bars) when waveform is missing. See `VoiceMessageView.swift`.
- Downloads via `FileDownloader.downloadVoice` and caches via `FileCache`. See `InlineKit`.

---

## Known differences vs Telegram (not implemented yet)

- No **preview/edit/trim** UI for voice before sending.
- No **pause/resume** recording flow.
- No **view-once** voice messages.
- No **transcription** UI or premium gating.
- No **raise-to-listen** or smart proximity playback.
- No **live waveform** mic blob animation.
- No **audio/ogg + Opus** encoding; Inline uses AAC in .m4a.
- iOS only (no macOS/web yet).

---

## Inline voice message spec (current behavior)

1) User long-presses mic button -> recording starts after permission check.
2) Slide left cancels (discard), slide up locks (recording continues until stop button).
3) Release to send; recordings < 0.5s discarded.
4) Voice file saved to local cache, waveform generated, voice metadata stored.
5) Upload voice file + duration + waveform.
6) Send message with `InputMedia.voice(voiceId)`.
7) Playback shows waveform + duration; tap to play/pause; download if needed.
