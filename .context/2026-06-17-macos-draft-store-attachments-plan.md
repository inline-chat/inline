# Drafts2 macOS Pilot

## Problem

macOS compose currently relies on debounced writes to `Dialog.draftMessage`. That makes draft correctness depend on timing: a user can type, navigate away, reopen the chat, and see stale or missing text because the delayed DB write has not completed. Attachments are worse because they live in `ComposeAppKit` view state and are not part of the draft model at all.

## Direction

Create `Drafts2` as a separate local-only draft implementation and pilot it on macOS first. Do not replace the existing `Drafts` implementation globally yet. iOS can continue using the current path until the macOS pilot proves the model.

`Drafts2` should own the source of truth for macOS compose drafts:

- Text
- Message entities
- Attachments
- Revision/update time

The compose view should render from `Drafts2`, write to `Drafts2`, and stop loading from `dialog.draftMessage`.

## Data Model

Keep the first version intentionally simple: one local table, no attachment join table.

`draft2`

- `peerKey` text primary key, using the existing normalized peer/dialog key format
- `text` text not null default `""`
- `entities` blob nullable, serialized `MessageEntities`
- `attachments` blob nullable, serialized `[Drafts2Attachment]`
- `updatedAt` integer not null, seconds
- `revision` integer not null

`Drafts2Attachment`

- `id` string, stable UI/local id
- `media` `FileMediaItem`
- `createdAt` integer

Why this shape:

- `FileMediaItem` already represents local photos, videos, documents, and voice content.
- It is already `Codable` and already used by send transactions.
- It already resolves local files through `FileCache`.
- A blob keeps the migration and query surface small for a macOS pilot.
- Attachment ordering can be the array order.

Do not store `SendMessageAttachment` in the draft. It contains send-transaction state such as upload/random id. Drafts should store reusable media items, and the send path can convert `[FileMediaItem]` into the existing transaction input.

## Attachment Materialization

Drafts2 should persist only materialized attachments: attachments whose files have already been copied into the app cache and represented as `FileMediaItem`.

Reuse the existing materialization helpers:

- `FileCache.savePhoto(image:preferredFormat:)`
- `FileCache.saveVideo(url:thumbnail:)`
- `FileCache.saveDocument(url:)`
- existing voice `FileMediaItem.voice` path

The reliability change is ownership. Long-running materialization must not be owned only by `ComposeAppKit`, because compose teardown currently cancels pending image/video tasks. For Drafts2:

- `ComposeAppKit` may still show immediate placeholders.
- The materialization task should be owned by `Drafts2` or a small `Drafts2AttachmentWriter`.
- When materialization succeeds, `Drafts2` appends/replaces the attachment in the draft row.
- If the compose view is gone, reopening the chat observes/loads the materialized attachment from `Drafts2`.
- If materialization fails, Drafts2 records no attachment and the current visible compose can show the existing error behavior.

For the first pilot, it is acceptable that a just-dropped large video is not durable until the copy finishes, but the copy task itself must survive navigation. That is the key difference from the current view-owned task model.

Voice recordings use the same `FileMediaItem.voice` model. The production behavior is:

- Active recording is not a draft until the user pauses into review.
- Review-state voice is materialized through `FileCache.saveVoice`, stored in Drafts2, and restored into the existing voice review UI on navigation back.
- Cancelling voice removes the Drafts2 attachment but does not delete shared cache files.

## Write Semantics

Every edit increments `revision`.

Text path:

1. On text change, write plain text to `draft2` quickly.
2. Debounce only entity extraction from attributed text.
3. Entity writes include the revision they were derived from and are ignored if stale.
4. Explicit rich actions such as mention/thread insertion and formatting save entities immediately.
5. Navigation teardown performs one immediate entity save and flushes queued Drafts2 writes.

Attachment path:

1. Add placeholder in UI immediately.
2. Start materialization in Drafts2-owned work.
3. On success, append `Drafts2Attachment(media: FileMediaItem)` to the current draft revision.
4. On remove, update the attachment array immediately and increment revision.
5. Background completion for a removed placeholder must not resurrect it.

Clear path:

- If text is empty and attachments are empty, delete the `draft2` row.
- Clearing after send should happen only after the send transaction has accepted ownership of the text and media items.
- Normal app termination flushes pending Drafts2 writes before returning `.terminateNow`.

## API Shape

`Drafts2` should live in `InlineKit` and expose a small macOS-friendly API:

- `load(peer:legacyDraftMessage:) -> Drafts2Snapshot?`
- `observeAttachmentResults(peer:onComplete:)`
- `updateText(peer:text:)`
- `updateEntities(peer:entities:forRevision:)`
- `addImage(peer:image:url:)`
- `addVideo(peer:url:thumbnail:)`
- `addFile(peer:url:)`
- `removeAttachment(peer:id:)`
- `clear(peer:)`
- `flush()` / `flushBlocking()`
- `prepareSend(peer:) async throws -> Drafts2SendSnapshot`

`Drafts2Snapshot`

- `peer`
- `text`
- `entities`
- `attachments: [Drafts2Attachment]`
- `revision`
- `updatedAt`

`Drafts2SendSnapshot`

- `text`
- `entities`
- `mediaItems: [FileMediaItem]`

`prepareSend` should read one consistent DB snapshot. Compose then passes `mediaItems` into the existing `TransactionSendMessage` initializer.

## macOS Pilot Scope

Replace draft behavior only in macOS compose:

- `ComposeAppKit.loadDraft()` loads from `Drafts2`.
- `textDidChange` updates `Drafts2` text immediately.
- Formatting changes schedule debounced entity updates.
- `attachmentItems` becomes a render/cache of `Drafts2Snapshot.attachments`, not the source of truth.
- add/remove image/video/file paths write through `Drafts2`.
- send reads a Drafts2 snapshot for ordered attachments.
- successful send clears `Drafts2`.

Leave old `Drafts` and `Dialog.draftMessage` in place for:

- iOS
- any legacy reader not part of this pilot
- migration fallback from old local text drafts

## Migration and Compatibility

On first macOS compose load for a peer:

1. If `draft2` has a row, use it.
2. Else if `dialog.draftMessage` has text, import it into `draft2`.
3. Else load empty.

Do not write back to `Dialog.draftMessage` from macOS Drafts2. During the pilot, macOS compose itself is the source of truth. Sidebar/global draft previews should prefer a cache-only Drafts2 reader when available and fall back to `Dialog.draftMessage`; a full GRDB observation can come later if preview freshness needs to survive app relaunch before opening a chat.

## Cleanup

Because Drafts2 stores `FileMediaItem` pointing at `FileCache`, do not delete cached files when an attachment is removed from a draft. Add a later cleanup pass for orphaned draft cache files if storage becomes a concern. The pilot should prioritize correctness and simple ownership.

## Tests

Add tests for:

- Text write is immediately visible through `Drafts2.load`.
- Debounced entity write for old revision is ignored.
- Plain text staging preserves existing entities until a replacement entity snapshot arrives.
- Empty text clears entities even when attachments keep the draft alive.
- Import from `dialog.draftMessage` happens only when no Drafts2 row exists.
- `[FileMediaItem]` attachment blob round trips.
- Flush persists the latest staged text.
- Clear removes the stored row after flush.
- Attachment removal preserves remaining order.
- Voice attachments round trip through storage.
- `prepareSend` returns text, entities, and media items from one snapshot.

Follow-up tests after deeper attachment UX coverage:

- Background materialization completion does not restore an attachment removed before completion.
- Successful send clears the row only after send ownership is established.

## Decision

Drafts2 should be a macOS-only pilot with a simple single-row data model. Reuse `FileMediaItem` for attachments and avoid a dedicated attachment table until there is a proven need for querying attachment drafts independently.
