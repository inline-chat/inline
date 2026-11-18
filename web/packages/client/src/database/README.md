# database

The account's resident store (`Db`) over the SQLite replica. Invariants are numbered as in `web/docs/core.md`.

## Writes (invariants 1 and 6)

- Every write goes through one ordered queue: `commit(fn)`, `batch(fn)` and the bare `insert`, `replace`, `update`, `delete`, `clearMessagesForChat`, `storeNonResidentObject` (a bare write is a one-statement batch).
- Memory changes when the write is accepted, so the caller reads its own write synchronously. Storage transactions run one at a time, in acceptance order.
- `commit(fn)` waits for every write accepted before it to settle, runs `fn` on committed state, and resolves after its transaction commits. It rejects with `DatabaseCommitError` on a storage failure.
- `batch(fn)` returns at once. A storage failure is reported by the next `flushPersistence()`.
- On a storage failure, the failed write and every write queued behind it that persists something are undone, newest first. Memory then equals disk. Observers never hear of undone writes.
- Observers hear of a write only after its transaction commits. A write with nothing to persist and nothing queued ahead of it publishes synchronously.

## Observing

- `subscribeToResidentChanges(listener)`: committed changes in commit order, with a revision one higher per batch. Each change carries the value its write committed. The exact guarantee is in the method's doc comment.
- `residentSnapshot(kinds)`: the committed view at the last delivered revision. Accepted writes that have not committed are left out.
- `subscribeToObject` and `subscribeToQuery` fire at the same points but read live memory.

## Reads (invariant 13)

- Each disk read (`hydrate`, `hydrateKinds`, `hydrateMessageWindow*`, `loadLocalWindowAround*`, `hydrateObjects`, `hydrateDeferredUpdatesForMessageKeys`, `readStoredObjects`) registers a `DbReadAdmission` (`read-admission.ts`) when it starts.
- The admission is seeded with every accepted write that has not committed, and it is stamped by every write accepted while the read is in flight.
- Rows are admitted in one synchronous step after the read's last await:
  - a resident row wins;
  - a stamped key takes its stamped value, or is dropped if it was deleted or rolled back;
  - messages of a chat cleared meanwhile are dropped.
- A latest-window read keeps window members written during the read.

## History coverage (invariant 5)

- `HistoryCoverage` (one row per chat in `message_history_coverage`, schema version 3): the inclusive message-ID ranges the server has certified complete, sorted and merged; the open top is `HISTORY_TOP`. No row means nothing is certified. Cached message rows never certify anything.
- `history-coverage.ts` is the pure arithmetic: `provenRanges` (what one `getChatHistory` page proves, after InlineKit's `provenCoverages`: a short page reaches message 1 or the top, an empty page proves its whole side, a page that does not match its request proves nothing), `certifyRanges`, `isCertified`, `certifiedRangeAt`, `certifiedReadMaxId`, `windowEdges`.
- One reducer, `Db.admitHistoryPage(chatId, ranges, returned, knownMaxId)`, runs inside the commit that stores the page's rows. It deletes stored server rows in the proven ranges that the page did not return (up to the newest message known when the request was made), then adds the ranges. Rows and coverage commit or roll back together.
- `Db.resetHistoryCoverage(chatId)` forgets a chat's coverage. It runs on `clearMessagesForChat`, on a chat-bucket repair (which then certifies its own latest page), and for every chat in a user-bucket repair. Deleting a message keeps coverage. Releasing rows from memory (window release, `trimWindow`) never touches it.
- Coverage is hydrated with the default kinds, so it is resident whenever a page commits.
- `MessageWindowOptions.minMessageId` / `maxMessageId` keep a local page inside one certified range.
- `promoteResidentMessageWindowToLatest` (an accepted send, `ensure latest`): a window at latest only gains the local sends, in the same step; a window elsewhere is replaced once by the latest page from disk, kept inside the latest certified run when there is one. It no longer anchors on `chat.lastMsgId`, which is the send's temporary ID right after its optimistic commit (that collapsed the window to the send for a patch).
- `Db.scanChatMessages(chatId, match, { limit, maxScanned, beforeMessageId })`: a chat's stored messages with server IDs that pass `match`, newest first, by a backwards walk of the `message` primary key, decoding each row; admitted under invariant 13. `chatMedia` uses it. 100,000-message chat, 5% photos: first 50 photos 4.5 ms (1,077 rows); 2,000 rows with no match 7.3 ms; the whole chat 387 ms (`__tests__/chat-scan.test.ts`, `INLINE_CHAT_SCAN_TIMING=1`).
- The read transaction cuts a requested frontier at the first uncertified ID once a chat has coverage (`certifiedReadMaxId`); a chat with no coverage yet is read as asked.

## Models for formerly raw update kinds (schema version 4)

| Model (`DbObjectKind`) | Table | Key | Written by |
| --- | --- | --- | --- |
| `SpaceMember` (`SM`) | `space_member` | `${spaceId}:${userId}`; `memberId` is the membership generation | `spaceMemberAdd/Update/Delete`, `joinSpace`, `GET_SPACE_MEMBERS` (roster, sets `Space.memberRosterSeq`), `GET_SPACE`, space repair |
| `ChatParticipant` (`CP`) | `chat_participant` | `${chatId}:${userId}` | `participantAdd/Delete`, `userAddedToChat`, `GET_CHAT_PARTICIPANTS` |
| `ChatParticipantGroup` (`CPG`) | `chat_participant_group` | `${chatId}:${groupId}` | `participantGroupAdd/Delete`, `userAddedToChat`, `GET_CHAT_PARTICIPANTS` |
| `UserGroup` (`UG`) | `user_group` | group ID | sidecar user groups, `GET_CHAT_PARTICIPANTS` |
| `DialogFolder` (`DF`) | `dialog_folder` | folder ID | `dialogFolder`, `getChats.folders` (the list is complete) |
| `UserSettings` (`US`) | `user_settings` | `0` | `updateUserSettings`, `GET_USER_SETTINGS`, `UPDATE_USER_SETTINGS` |

Payload-only fields added at the same time: `Dialog.notificationMode`, `folderId`, `translationEnabled`, `unreadMentionsCount`, `unreadReactionsCount`, `unreadMentionIds`, `unreadReactionIds`; `Chat.participantRosterComplete`; `Space.handle`, `seq`, `photoFileUniqueId`, `photoUrl`, `isPro`, `gridEnabled`, `memberRosterSeq`, `memberRosterComplete`; `Message.blockContent`, `replyQuote`, `via`, `subthread`. `deferred_update` gained an indexed `update_type` column, backfilled from each row's payload by the migration.

All six kinds are hydrated with the default kinds: their updates are applied synchronously and need the stored row (a member's generation, a grant being removed).

Semantics follow InlineKit (`Updates.swift`, `Member.swift`):

- A member event with an older generation, a removal of an older generation (or, without `memberId`, one dated before the stored join) and a space-bucket event at or below the last roster's sequence are ignored.
- A grant whose chat is not local is not stored; one whose user or group is not local marks `Chat.participantRosterComplete = false`.
- A dialog-, space- or chat-scoped update whose target is not stored changes nothing: the snapshot that later stores it carries the current value.
- Access loss (`userRemovedFromChat`, `deleteChat`, the account's own `participantDelete`/`participantGroupDelete` on a private thread it no longer reaches, its own `spaceMemberDelete`, losing `canAccessPublicChats`) purges in the caller's write: messages, coverage, dialogs, grants, the chat, its cursor; for a space also its chats, members, groups and cursor. Drafts stay. A grant later in the same page cancels the purge. A page or repair in flight for a purged bucket is fenced (`SyncBucketAccessLost`) until the chat or space is stored again.
- An edit replaces `blockContent` (absent clears it); other message snapshots keep it; `via`, `subthread` and `replyQuote` are kept when omitted.

Raw rows of these kinds written before version 4 replay into the models on the first sync connection (`replayProjectedDeferredUpdates`, oldest first, one commit per row; malformed rows stay).

## Local message search index (schema version 5)

`message_search` (FTS5, contentless) and `message_search_doc`, with triggers that remove entries when a `message` row is deleted. `SQLitePersistenceStore.writeTransaction` writes the entry for every message `put` in the same transaction; `readSearchIndex` / `writeSearchIndex` serve the search engine; `Db.readThroughAdmission` lets its disk reads go through read admission. Design, measurements and API: `src/search/README.md`.

## Update kinds still stored raw (invariant 7)

- `acknowledgement` (read receipts): no web model yet.
- The six agent kinds (`agentSessionState`, `agentParticipation`, `agentGrant`, `agentRuntime`, `agentSettings`, `agentSessionControl`): out of this package's scope.
- Any kind this build does not know, and any projected kind whose payload is malformed (for example `spaceMemberAdd` without a member).

## Schema (invariant 9)

- `migrateInlineSqlite` is forward-only, one transaction per migration.
- A replica from a newer schema throws `InlineSqliteSchemaTooNewError` before anything is written, and the store never opens it. Detect it with `isInlineSqliteSchemaTooNew(error)`.

## Tests

- `__tests__/write-ordering.test.ts`: invariants 6 and 1.
- `__tests__/read-reconciliation.test.ts`: invariant 13, on `__tests__/gated-store.ts`, the real SQLite store with reads and writes a test can hold.
- `sqlite/schema-guard.test.ts`: invariants 5 and 9, and upgrades from every earlier schema version.
- `realtime/__tests__/update-coverage.test.ts`: every newly projected kind through the sync engine on SQLite (order, duplicates, a gap, round trip) and replay from raw rows; `membership-updates.test.ts` (generations, rosters, access-loss purges, the fence), `dialog-state-updates.test.ts`, `deferred-replay.test.ts` (retention, upgrade from every earlier schema), `message-rich-content.test.ts`.
- `__tests__/history-coverage.test.ts`: invariant 5 (a stored row does not close a hole, empty pages, failed pages, the read frontier, deletion and clear-history). Repairs are in `realtime/sync/sync-recovery.test.ts`; the window edges, paging without stitching, trimming and repeated `ensure` in `host/__tests__/history-window.test.ts`.
