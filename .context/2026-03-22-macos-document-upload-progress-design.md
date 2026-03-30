# macOS document upload progress design

## Goal

Add Telegram-style circular upload progress for pending outgoing document messages on macOS, with a centered `X` cancel affordance. Keep compose attachments unchanged. Preserve the existing document download UI for received messages and already-sent files.

## Scope

In scope:

- Pending outgoing message bubbles that render [`DocumentView`](../apple/InlineMac/Views/DocumentView/DocumentView.swift)
- Upload progress states: processing and byte-progress upload
- Cancel from the document row itself
- Reuse only the circular ring drawing/control primitive from the video UI

Out of scope:

- Compose attachment progress or pre-send uploads
- Photo upload progress in this change
- Redesigning the existing download document row
- Extracting a full shared transfer overlay component

## Existing context

- [`NewVideoView`](../apple/InlineMac/Views/Message/Media/NewVideoView.swift) already has the desired interaction pattern: circular line progress plus a centered cancel button for active transfers.
- [`DocumentView`](../apple/InlineMac/Views/DocumentView/DocumentView.swift) currently models only document download states and assumes `localPath != nil` means the file is locally available.
- [`FileUploader`](../apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift) already exposes document upload progress publishers, but only video and voice have dedicated cancel helpers.
- Pending message views already refresh `DocumentView` with updated `FullMessage` state via `update(with:fullMessage:)`.

## Chosen approach

Extract only the circular progress ring primitive from the video implementation into a small reusable AppKit view. Keep all surrounding layout and sizing decisions view-specific.

Why this approach:

- It preserves the current video behavior and visual feel.
- It avoids duplicating the ring drawing and animation logic.
- It lets `DocumentView` use tighter sizing than video without forcing a shared overlay layout.
- It keeps document-specific state handling isolated inside `DocumentView`.

## UI design

`DocumentView` keeps its current two-line file layout. The left icon area changes only when an upload is active for a pending outgoing message:

- Background remains the document icon circle container.
- The static icon is replaced by a circular line progress ring.
- A centered `X` button appears inside the ring.
- The file metadata row shows `Processing` or transferred bytes such as `2.1 MB / 8.4 MB`.
- The trailing text action button stays hidden during active transfer, matching the current download treatment.

The shared ring primitive will expose configuration for:

- stroke width
- minimum visible progress
- tint color
- optional spinning while active

The caller remains responsible for:

- frame size
- button size and symbol configuration
- background circle size and color
- layout constraints

## State model

Extend `DocumentView.DocumentState` so it can represent both upload and download transfer states:

- `locallyAvailable`
- `needsDownload`
- `downloading(bytesReceived:totalBytes:)`
- `uploadProcessing`
- `uploading(bytesSent:totalBytes:)`

Resolution order matters:

1. If the message is a pending outgoing message and the document upload is active or expected, prefer upload states.
2. Else if the file is truly locally available for an already-sent/received message, use `locallyAvailable`.
3. Else if a download is active, use download state.
4. Else use `needsDownload`.

This avoids the current false positive where pending outgoing documents already have a `localPath` before upload completes.

## Upload detection and progress binding

`DocumentView` should treat a row as upload-capable only when all of the following are true:

- `fullMessage` exists
- `fullMessage.message.status == .sending`
- the row represents a document message
- the document has a valid local document id

For that case, `DocumentView` binds to:

- `FileUploader.shared.documentProgressPublisher(documentLocalId:)`

Displayed text:

- `Processing` for `.processing`
- `sent / total` for `.uploading`
- no special inline completed UI; the row naturally transitions away once the message refreshes with server-backed data
- no inline failed control; let the existing message-level failed-send UX handle resend/cancel

`DocumentView.update(with:fullMessage:)` must clear and rebuild upload/download subscriptions whenever the message/document context changes so reused views do not leak stale transfer state.

## Cancel behavior

Tapping the centered `X` in a pending upload row should:

1. Cancel the document upload via a new document-specific helper in `FileUploader`
2. Cancel the pending send transaction
   - prefer `transactionId` when present
   - otherwise cancel by `randomId`, matching the video implementation
3. Delete the local pending message row so the bubble disappears immediately

This should mirror the existing cancel semantics in `NewVideoView`.

## Error handling

- Upload publisher failure should stop the upload binding and allow the row to resolve back through normal message state.
- Explicit cancel should be treated as removal of the pending row, not as an inline failed state.
- Download behavior for non-pending document rows should remain unchanged.
- If the document lacks a local document id, upload-specific UI should not activate.

## Files expected to change

- `apple/InlineMac/Views/Message/Media/NewVideoView.swift`
  - extract the ring primitive into a reusable local/shared type without changing current video behavior
- `apple/InlineMac/Views/DocumentView/DocumentView.swift`
  - add upload states, upload binding, transfer UI, and cancel behavior
- `apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift`
  - add document-specific cancel helper
- `apple/InlineKit/Tests/InlineKitTests/FileUploadProgressTests.swift`
  - add focused coverage for the new helper and any small shared state helpers

## Testing strategy

Automated:

- Extend upload progress tests for document cancel helper behavior.
- Add a small unit-tested resolver/helper if state resolution is factored out of `DocumentView`, especially for the case where a pending upload has `localPath` but must not resolve to `locallyAvailable`.

Manual macOS verification:

- Send a document and confirm the pending bubble shows `Processing`, then circular upload progress with centered `X`.
- Click the centered `X` and confirm the upload stops and the pending message disappears.
- Confirm a failed upload still uses existing message-level resend/cancel UX.
- Confirm received or already-sent documents still show the existing download/Finder flow.
- Confirm compose attachments do not change.

## Risks

- View reuse could leak stale upload subscriptions if binding cleanup is incomplete.
- State resolution could regress received-document behavior if pending-upload detection is too broad.
- Cancel flow must not remove non-pending messages; it should remain gated to pending sends.

## Non-goals for this change

- Unifying document and video transfer state machines
- Extracting a generalized transfer overlay system
- Adding progress UI to compose attachments
- Changing server or transaction semantics
