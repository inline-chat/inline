# macOS compose attachment draft persistence plan

Date: 2026-01-08

## Context / current behavior
- macOS compose persists text drafts via `Drafts.shared.update(peerId:attributedString:)` called from `ComposeAppKit.saveDraftWithDebounce()`.
- Drafts are stored in `Dialog.draftMessage` (InlineProtocol `DraftMessage`), encoded via `ProtocolDraftMessage` helpers.
- Compose attachments (`ComposeAppKit.attachmentItems` + `ComposeAttachments` UI) are in-memory only and cleared on view teardown.
- Local media is persisted via `FileCache` to the app cache + DB (`PhotoInfo`, `VideoInfo`, `DocumentInfo`), and referenced by `FileMediaItem`.

## Goal
Persist compose attachments in macOS so they survive navigation away from a chat (and optionally app relaunch), similar to how compose text drafts persist.

## Proposed approach (preferred)
Extend `DraftMessage` to carry attachment drafts encoded as JSON bytes (array of `FileMediaItem`). This reuses the existing `Dialog.draftMessage` storage without adding new tables.

### Data model
- Add optional field in proto:
  - `message DraftMessage { string text = 1; optional MessageEntities entities = 2; optional bytes attachments_json = 3; }`
- Encode/decode `[FileMediaItem]` via JSON using `Codable` (FileMediaItem is already `Codable`).
- Preserve ordering by storing an array in the saved order (store order in compose).

## Plan (file-level)
1. **Proto + generated types**
   - Update `proto/core.proto` to add `attachments_json` to `DraftMessage`.
   - Regenerate protos (`bun run generate:proto` and `bun run proto:generate-swift`).
   - Update `apple/InlineKit/Sources/InlineProtocol/core.pb.swift` via regeneration.

2. **DraftMessage helpers**
   - Update `apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolDraftMessage.swift` to encode/decode `attachments_json`.
   - Use JSON encoder/decoder; ignore decoding errors and treat as nil.

3. **Drafts API**
   - Extend `MessageDraft` to include `attachments: [FileMediaItem]?`.
   - Extend `Drafts.update(peerId:text:entities:attachments:)` and `Drafts.update(peerId:attributedString:attachments:)`.
   - Keep existing call sites compatible with default `nil` attachments.

4. **ComposeAppKit persistence**
   - Track attachment order in `ComposeAppKit` (e.g., `attachmentOrder: [String]` for IDs).
   - Save attachments on add/remove; reuse the existing debounce (call `saveDraftWithDebounce()` when attachments change).
   - On `loadDraft()`, decode attachments and rehydrate UI:
     - rebuild `attachmentItems` + `attachmentOrder`,
     - load thumbnails/images from cached local paths,
     - call `ComposeAttachments.addImageView/addVideoView/addDocumentView`.
   - After restore, call `updateHeight(animate: false)` and `updateSendButtonIfNeeded()`.

5. **Cleanup + edge cases**
   - Do not persist pending placeholders (only persist once a `FileMediaItem` exists).
   - If a local file referenced by a draft is missing, skip it (optionally prune on save).
   - On `clear()` after sending, ensure draft attachments are cleared via `Drafts.shared.clear`.

## Manual verification checklist
- Add image/video/document, navigate away, return: attachments still visible and sendable.
- App relaunch (if stored in DB): attachments restored.
- Missing local file: no crash; attachment skipped.
- Send: draft cleared, attachments removed.

## Open questions
1. Should attachment drafts persist across app relaunch (DB) or only across in-app navigation?
2. OK to extend `DraftMessage` in proto (regen Swift/TS), or prefer a mac-only table?
3. Do we need strict insertion order for media thumbnails, or can we derive order from IDs?
4. Should we attempt to persist pending placeholders before FileCache finishes, or ignore them?
