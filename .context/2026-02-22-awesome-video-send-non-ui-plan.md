# Awesome Video Sending (Thread 1061) - Non-UI Plan

## Scope and Goal
- Scope: shared video send/upload pipeline only (InlineKit + API interactions), no picker redesign and no "Library merge" UX work.
- Goal: reach thread targets for reliable long video send, pre-upload processing/compression, true transfer progress data, and processing/upload byte state availability for message surfaces.

## Source Inputs Reviewed
- Thread data: chat `1061` (`spec: awesome video sending`) via Inline CLI.
- Telegram references (local):
  - `/Users/dena/dev/Telegram-iOS/submodules/LegacyComponents/Sources/TGMediaVideoConverter.m`
  - `/Users/dena/dev/Telegram-iOS/submodules/TelegramCore/Sources/State/PendingMessageManager.swift`
  - `/Users/dena/dev/Telegram-iOS/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveMediaNode/Sources/ChatMessageInteractiveMediaNode.swift`
- Inline architecture:
  - `apple/InlineKit/Sources/InlineKit/Files/FileCache.swift`
  - `apple/InlineKit/Sources/InlineKit/Files/VideoCompression.swift`
  - `apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift`
  - `apple/InlineKit/Sources/InlineKit/ApiClient.swift`
  - `server/src/methods/uploadFile.ts`
- Best-practice references:
  - Apple AVFoundation export/session state + progress + network optimization docs.
  - Apple URLSessionTaskDelegate upload progress callback docs (`didSendBodyData`).

## Facts From Thread 1061 (Must-Haves)
- Pre-upload video processing/compression for faster uploads.
- Real upload progress (not fake spinner-only state).
- Report uploaded bytes and total bytes in upload state.
- Communicate processing state during resize/compression.
- Keep stage 3 out of scope for this PR:
  - multipart upload
  - resumable upload after app restart
  - major server/client large-file infrastructure rework
- Pipeline is shared with macOS; solution must be shared-safe.
- Add tests and ensure they pass.

## Current Gaps
- MP4s are currently attached as-is in `FileCache.saveVideo`, so most camera videos skip compression.
- Upload progress is a `Double` fraction with legacy sentinel `-1` for processing.
- No first-class bytes-sent / bytes-total model for upload.
- Video upload state is not exposed as structured progress stream for consumers.

## Non-UI Implementation Plan
1. Add typed upload progress model in `InlineKit`.
   - Introduce a single source-of-truth upload progress snapshot with stages: `processing`, `uploading`, `completed`, `failed`.
   - Include `bytesSent`, `totalBytes`, and clamped fraction.

2. Upgrade API upload delegate progress payload.
   - Replace raw fraction callback with structured transport progress from `ApiClient.uploadFile`.
   - Keep behavior compatible and deterministic (`0` at start, `1` on success).

3. Move video preprocessing into upload pipeline.
   - Keep `FileCache.saveVideo` for secure copy/transcode normalization and local preview persistence.
   - In `FileUploader.performUpload`, preprocess video for upload before network transfer:
     - attempt compression for large/high-bitrate videos
     - fall back safely to original local file when compression is unnecessary/ineffective
     - propagate processing state before upload starts
     - use actual upload payload size for byte totals exposed to progress state

4. Improve cancellation behavior during video export.
   - Ensure compression/export is cancellation-aware, so canceling send aborts preprocessing promptly.

5. Expose upload progress stream APIs from `FileUploader`.
   - Add publisher API per media id (initially video path needed for this task).
   - Maintain existing lifecycle semantics for completion/failure and cleanup.

6. Add tests.
   - Unit tests for upload progress stage/fraction/byte mapping behavior.
   - Keep existing `VideoCompressionTests` passing.

## Risk Controls
- Do not modify server contract; send same multipart fields (`type`, `file`, video metadata + thumbnail).
- Do not implement multipart/resume in this PR.
- Keep shared pipeline behavior valid for both iOS and macOS.

## Validation Plan
- `cd apple/InlineKit && swift test --filter VideoCompressionTests`
- `cd apple/InlineKit && swift test --filter FileUploadProgressTests`
- If filters are unavailable in this environment, run full `swift test` for InlineKit.

## Review Checkpoint (Deep Understanding)
- This plan directly maps to the highest-priority thread asks (compression, processing, real upload progress with bytes) and intentionally excludes stage-3 architecture work.
- The approach is incremental: no API break on server side, minimal behavior change surface outside upload pipeline, and test-backed progress semantics.
