# iOS Voice Message Reimplementation Plan

## Findings

- The shared voice contract is usable: `Client_MessageVoiceContent`, `FileCache.saveVoice`, `FileUploader.uploadVoice`, optimistic send, upload progress, and backend validation already support voice messages with `audio/mp4`/`.m4a`, duration, waveform, and size metadata.
- macOS has the right compose shape: recording/review phases, playback before send, and a narrow parent-compose integration. It also has draft voice work that is useful later, but not required for iOS beta.
- The current iOS recorder is the release blocker. It uses `AVAudioEngine`, rejects input formats unless they are Float32 non-interleaved, records CAF, then renders AAC on finish. That can fail by route and can leave users stuck in start/finish states.
- The current iOS live waveform uses the shared playback waveform view. It is correct but too view-heavy for frequent live meter updates in compose.
- Telegram source reinforces the technical split we want: a separate recording state/pipeline, compact waveform drawing, and chat input talking to recording through a small state/data surface. We should use that architecture principle, not Telegram's UX.

## Keep

- Shared backend/protobuf/client upload and send plumbing.
- `ComposeVoiceRecordingEligibility` and its tests.
- The dedicated `apple/InlineIOS/Features/Compose/Voice/` folder boundary.
- UIKit compose as the parent owner of peer/chat/send-mode/reply state.
- Review-before-send behavior matching Inline macOS.

## Rewrite

- Replace the iOS engine recorder with a direct AAC `.m4a` `AVAudioRecorder` implementation.
- Replace live compose waveform rendering with a dedicated Canvas-based compose waveform.
- Tighten state transitions so start/stop/cancel/background/interruption cannot leave the UI stuck.
- Keep the parent compose API limited to start, stop, cancel, play, send, and consume media item.

## Chosen Release Path

Use `AVAudioRecorder` for iOS beta:

- Record directly to `.m4a` (`audio/mp4`) with AAC, mono, 44.1 kHz, 40 kbps.
- Use `isMeteringEnabled` for responsive waveform samples.
- Keep finish cheap: stop recorder, read the already-encoded file off the main actor, validate size/data, and return `ComposeVoiceRecording`.
- Use `AVAudioSession` `.playAndRecord` with `.voiceChat`, `.allowBluetoothHFP`, and `.defaultToSpeaker`.
- Stop cleanly on audio interruptions and app background; cancel preparing states.

Tradeoff: this gives up custom normalization and explicit engine voice-processing control for V1. That is acceptable for beta because it removes the brittle route-dependent format path and the expensive finish conversion. If we need stronger DSP later, build an engine-backed V2 behind the same recorder API.

## Alternatives Considered

1. Patch the current `AVAudioEngine` recorder.
   - Pros: keeps normalization and existing waveform extraction.
   - Cons: still brittle around input formats/routes, more audio-thread code, more finish-time work.
   - Weight: 25%. Not beta-safe enough after observed failures.

2. Port macOS recorder directly.
   - Pros: fewer code changes and platform parity.
   - Cons: macOS has the same engine assumptions and synchronous finish.
   - Weight: 10%. Useful reference, not the iOS answer.

3. Use `AVAudioRecorder` for iOS V1.
   - Pros: smallest robust surface, direct server-compatible output, built-in metering, easier lifecycle.
   - Cons: less control over processing and normalization.
   - Weight: 65%. Best beta path.

## Hard Parts

- Microphone permission and app lifecycle races while the user taps quickly.
- Audio session interruptions, backgrounding, and route changes.
- Avoiding stuck UI during async finish/read.
- Keeping waveform responsive without expensive SwiftUI rebuilds.
- Preserving the compose parent boundary so voice does not leak into text/attachment logic.
- Real-device validation; Simulator microphone behavior is not enough.

## Verification

- Run focused Swift checks/tests for touched shared helpers.
- Build the iOS app target.
- Manual beta checklist on a real device:
  - tap mic, record, stop, play, scrub, cancel
  - send normal and silent
  - short recording rejection
  - tap start/stop rapidly
  - background while recording
  - audio interruption while recording
  - Bluetooth/no-headset route changes
  - receive/play sent voice message

