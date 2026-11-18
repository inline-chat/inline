# @inline/core-protocol

The contract between a UI context and the account core. Plain, structured-cloneable data and a few pure helpers. Both sides import this package; neither imports the other. Branded ID strings from `@inline/ids`, never protobuf types.

The core host (`@inline/client`, `src/host/`) is the only implementation of the core side today. `link` carries the same interface across a worker, between tabs and between Electron windows.

## Shape

```
UI ── Command ──▶ CoreEndpoint ──▶ core
UI ◀── CoreMessage (hello | snapshot | patch) ── core
```

- **`CoreEndpoint`**: `post(command)`, `subscribe(listener)`, `close()`. Delivery is ordered. `post` never throws for a well-formed command; failures arrive as data. `close` may return a promise: for an endpoint that owns the core it resolves once storage and the connection are released.
- **Commands**: `hello`, `session` (`start` with `{ userId, token }`, `signOut`), `signal` (`online`, `visibility`, `wake`), `subscribe`, `unsubscribe`, `ensure` (`older`, `newer`, `latest`, `{ around }` for a `chatWindow`), `intent` (with a UI-chosen `tx`), `resync`, `trimWindow` (`{ sub, keep: { from, to } }`: release rows of the window outside the inclusive range; the core may keep more, and a core that does not implement it ignores it).
- **Queries** (`QueryDescriptor`): `core` (resource only), `me`, `sidebar(mode, spaceId?)`, `chatWindow(chatId, anchor)`, `chat`, `user`, `draft`, `newMessages`. Each subscription gets an ordered list of row keys (except `core`) and, for `core` and `chatWindow`, a resource.
  - `sidebar` carries, with each dialog, the rows its row view needs: the chat (`ChatRow.lastMessageRowId` names the last message's row, by client key for a send from this device), the peer user, the last message and its sender, the draft, the space and a reply thread's parent chat.
  - `newMessages` lists incoming messages that arrived live after the subscription started, oldest first, append-only, bounded; each with its chat, dialog and sender rows (and space, parent chat, replied-to message and thread anchor when on the device). `NEW_MESSAGES_RULE` states the rule (Mac `MacNotifications` gating): delivered by an update (live push or catch-up page; never history paging, a repair or a local read), first insertion, incoming, not silent, unread when it arrived, at most `maxAgeSeconds` (120) old; at most `limit` (50) entries, each released `retainSeconds` (300) after it arrived.
  - `chatParticipants(chatId)`: group grants first (`userGroup` rows by name), then `member` rows by display name and user ID (the Mac's `ChatInfo`), each with its user row; `roster` resource (`complete`, `loading`, `failed?`). Fetched from the server on first subscribe in a session unless the device's list is complete.
  - `spaceMembers(spaceId)`: the account first, then by join date (the Mac's member management); `roster` resource; fetched like participants.
  - `userGroups(spaceId)` (by name), `spaces()` (by name), `userSettings()` (zero or one `settings` row; fetched once if absent), `dialogFolders()` (pinned first by `pinnedOrder`, then `order`).
  - `media(ref, priority?)`: a `media` resource, no list. `ref` is a message's media (`size`: a photo size type; `thumbnail` for a video's or document's thumbnail) or a local attachment. The subscription is a claim: `visible` (default, within auto-download limits) or `opened` (first, no limits).
  - `composeActions(chatId?)`: a `compose` resource (who is composing, in one chat or all), the list carries their user rows. Never stored.
  - `searchMessages(request)`, `findInChat(request)`, `countMessages(request)`: local search as request and answer (`search` resource, no list). Subscribe the same `sub` again with a new request to replace it, unsubscribe to cancel; a replaced or cancelled request never delivers.
  - `chatMedia(chatId, filter)`: a chat's shared `photosVideos`, `photos`, `videos`, `files`, `voice` or `links`; message rows newest first with their senders, and a `chatMedia` resource (`loading`, `hasMore`, `fetched`, `failed?`). The device's messages first; while connected the server's first page follows, and `ensure { sub, range: "older" }` fetches the next. Server pages are committed to the replica, so listed rows are on disk.
  - `searchServerMessages(request)` (`SEARCH_MESSAGES` in one chat: hits with ranges, `nextOffsetId`, or the exact count with `countOnly`) and `searchUsers(request)` (`SEARCH_USERS`): server search as request and answer (`remoteSearch` resource, no list), same replace and cancel rules as local search. Not written to the replica; people come as `UserRow` values inside the resource. Offline they fail at once with `offline`.
  - `chat(chatId)` also carries the chat's dialog row (not in the list) when the account has one.
- **Rows**: `UserRow`, `SpaceRow`, `ChatRow`, `DialogRow`, `MessageRow`, `DraftRow`, `MemberRow` (`memberRowId`), `UserGroupRow`, `FolderRow`, `SettingsRow`, keyed in the view store by `rowKey(kind, id)`. Rows are immutable snapshots shaped for views.
- **Resources**: `CoreResource` (phase, connection, storage, build ID, user, `signingOut?`, `erased?`, `stalledSync?`: sync scopes that stopped retrying, as `SyncStall { scope: account | space | chat, spaceId?, chatId?, peerUserId?, reason: retryLimit | repairUnavailable }`) and `WindowResource` (`hasOlder`, `hasNewer`, `atLatest`, `loading`, `unreadBoundary`, `certifiedThrough`: the newest message ID up to which the window's history is known to be contiguous; read state must not advance past it).
- **Intents** (17 November additions): `updateUserSettings`, `setDialogNotifications`, `setDialogFollow`, `setDialogPinned`, `setDialogArchived`, `markUnread`, `readAll` (all durable); `attachFile`, `discardAttachment`, `sendMedia` (durable), `retrySend`; `mediaHints` (nearby assets per context); `composeAction` (ephemeral, `confirmed` at once).
- **Intents**: `sendText`, `editText`, `deleteMessages` (`messageIds`, and `clientKeys` for sends from this device: deleting one still sending cancels it), `react`, `markRead`, `saveDraft`, `setDialogOpen`, `retrySync` (retry stalled sync now), `invokeAction` (a bot button), `submitForm` (a form block, with `FormSubmissionValue[]`). Results (`IntentResult`) arrive in `Patch.settled`: `accepted`, then `confirmed`, `rejected` (with a reason) or `uncertain`. A confirmed `invokeAction` or `submitForm` carries the bot's `answer` (`ActionAnswer`: toast or alert) when it answered within `ACTION_ANSWER_TIMEOUT_MS`.
- **Two kinds of intent.** Replay-safe ones (`sendText`, `markRead`, `setDialogOpen`, `saveDraft`, the settings and dialog-state intents, `sendMedia`) are durable: `accepted` means committed on the device, and they wait offline. The others (`editText`, `deleteMessages`, `react`, `invokeAction`, `submitForm`) have no server idempotency key: they need a connection (offline: `rejected` with `offline`, before anything shows), are sent once, are not restored after a restart, and settle `uncertain` if the connection drops with them in flight. For these, `accepted` means admitted and shown in this session.

## Media: what the UI does with a `Blob`

A ready `MediaResource` carries `blob`: a handle to bytes the core keeps (an OPFS file in the browser). Structured clone shares the handle between the worker and the UI thread; the bytes are not copied through the patch stream.

- Make one object URL per blob shown (`URL.createObjectURL`), and revoke it when the view stops showing it or a later resource for the same subscription carries a different blob (compare `size` and identity).
- The blob is readable while the subscription that delivered it is held: the core pins the cached file for every subscription. After unsubscribing, the file may be evicted and the blob may stop reading; an image already decoded keeps painting.
- A local send's row (`MessageRow.upload`) shows its bytes through `media({ kind: "attachment", attachmentId })`, which also carries `attachment` (kind, name, dimensions, tiny JPEG preview) and `upload` (progress). `optimisticMediaRow(intent, attachment, fromId, date)` is the row the core commits for a `sendMedia`, so the UI's overlay row is identical.
- Sending: `newAttachmentId()`, post `attachFile` with the `Blob` (an intent, so carriers need no change), then `mediaSendIntents(...)` (one message per attachment, text on the first, the Mac way), one `sendMedia` per item. Deleting a send by client key cancels its upload; a failed one is retried with `retrySend`.

## Invariants

1. **A context's first message is a `snapshot`** (possibly empty), before any patch.
2. **Revisions are contiguous per context.** Every patch names its `base`; `base` equals the previous revision and `revision` is `base + 1`. A patch whose `base` is ahead of the context's revision means one was lost: send `resync` and replace the store with the snapshot that follows. A patch at or before the current revision is stale: ignore it. `classifyPatch` and `applyPatch` implement exactly this.
3. **A row in a patch is on disk.** The core publishes committed state only, with one exception: the display of open intents that are not replay-safe (a pending reaction, edit or delete) is applied on top of committed rows in memory. The base is on disk; the display is recomputed from it and the open intents, never undone (core invariant 4).
4. **Rows are released.** When no subscription of a context needs a row any more, the patch that ends the need carries a `remove` for it. A view store stays bounded without its own GC.
5. **Message rows keep their identity.** A message sent from this device is `sentMessageRowId(chatId, clientKey)` (`${chatId}:r${clientKey}`) for the whole session, including after the server assigns its ID (`MessageRow.messageId` appears then). A received message is `receivedMessageRowId(chatId, messageId)`.
6. **Local echo is shared.** `optimisticMessageRow(intent, fromId, date)` is the row the core commits for a `sendText`; pass `intent.date` so the core uses the same date and both sides build an identical row. The overlay entry is dropped when a patch carries that row key or settles the `tx`.
7. **`accepted` means durable.** A composer may clear, and a draft may be dropped, only after `accepted` (or `confirmed`, which implies it). `uncertain` is never shown as failed or delivered.
8. **Intents are idempotent by `tx`.** Re-posting a `tx` the core already knows returns its latest result instead of applying it again; `sendText` is also idempotent by `clientKey`.
9. **`Snapshot.settled`** carries the latest result of every intent the context issued that the core still tracks, so results lost in a gap are not lost. Treat a missing field as empty.
10. **Same build on both sides.** No compatibility matrix: contexts exchange `hello` with build IDs (`isNewerBuild`); the newest build leads and older contexts reload.

## Helpers

- `rowKey`, `rowKeyOf`, `sentMessageRowId`, `receivedMessageRowId`.
- `isClientKey(value)`: a canonical positive 64-bit decimal (the wire random ID). `newClientKey()` makes one.
- `optimisticMessageRow(intent, fromId, date, tx?)`, `optimisticMediaRow(intent, attachment, fromId, date, tx?)`, `localMedia(attachment)`, `mediaSendIntents(...)`.
- Reference reducer: `createProtocolState`, `applyPatch` (returns `applied`, `stale` or `gap`), `applySnapshot`, `dropSubscription`, `classifyPatch`. The `reactive` view store is the production consumer; these are for tests and for `link`.

## Status by query and intent

| | Core host |
| --- | --- |
| `core`, `me`, `sidebar`, `chatWindow`, `chat`, `user`, `draft`, `newMessages`, `chatParticipants`, `spaceMembers`, `userGroups`, `spaces`, `userSettings`, `dialogFolders`, `media`, `composeActions`, `searchMessages`, `findInChat`, `countMessages`, `chatMedia`, `searchServerMessages`, `searchUsers` | materialized |
| any other query kind | stays an empty list with no resource |
| `sendText`, `markRead`, `saveDraft`, `setDialogOpen`, `editText`, `deleteMessages`, `react`, `retrySync`, `invokeAction`, `submitForm`, `updateUserSettings`, `setDialogNotifications`, `setDialogFollow`, `setDialogPinned`, `setDialogArchived`, `markUnread`, `readAll`, `attachFile`, `discardAttachment`, `sendMedia`, `retrySend`, `mediaHints`, `composeAction`, `addChatParticipants`, `removeChatParticipant` | implemented |
| any other kind | rejected with reason `unsupported` |

## Changes on 17 November (contract-2, all additive and optional)

Each addition, and the feature that asked for it:

| Addition | Asked by |
| --- | --- |
| Intents `addChatParticipants { chatId, userIds, groupIds? }` and `removeChatParticipant { chatId, userId? \| groupId? }`: durable, idempotent by `tx` (also across a restart), sent once connected; a refusal refetches the roster instead of guessing a rollback | `features/mentions` (rule 14 auto-add and Undo), `features/chat-info` (members list) |
| Query `chatMedia(chatId, filter)`, `ChatMediaFilter`, `ChatMediaResource`; `ensure older` pages it | `features/chat-info` (Media, Files, Voice, Links tabs), `features/media` |
| `ChatRow.dialogId` on every chat row; the `chat` query carries the dialog row | `features/notifications`, `app` (one dialog index), `view/features` (`dialogFor`, chat model's read state) |
| Queries `searchServerMessages` and `searchUsers`; `ServerMessageSearchRequest`, `UserSearchRequest`, `ServerMessageHit`, `RemoteSearchResource` | `features/find` (second source for find in chat), `features/quick-search` (remote source: people) |
| `PhotoInfo.preview` (a complete tiny JPEG); `localMedia` puts the attachment's preview on a sending photo and, as `thumbnail.preview`, on a sending video | `features/media` (the box is not blank while sending) |
| `attachFile.preview` (a poster frame the UI made, at most `ATTACHMENT_PREVIEW_MAX_BYTES`); a video's `width`, `height` and `duration` now reach the server with the upload, so the sent message keeps the sending row's size | `features/media` |
| `sendText.draftRevision` and `sendMedia.draftRevision` (`mediaSendIntents({ draftRevision })` puts it on the first send): the draft is deleted in the send's own commit when its revision is at most this | `features/media`, `view/features` (`sendText` cannot consume the draft) |
| `CoreResource.signingOut?: true` (intents refused, erase in progress) and `CoreResource.erased?: "complete" \| "failed"` on the `signedOut` that follows a sign-out or revocation: the page closes only after `signedOut` | security review (sign-out could leave the replica on disk) |
| `MessageRow.tx`: the UI's transaction ID on a send still in the outbox, kept durably across reloads and handoffs; `optimisticMessageRow(..., tx?)` and `optimisticMediaRow(..., tx?)` build the identical row | `view/features`, `reactive` store (match an optimistic row to its outbox row after a reload or handoff) |

Version skew: an older core refuses the new intents with `unsupported` and keeps the new queries empty; it ignores `draftRevision` and `preview` (the draft stays; no preview). An older UI ignores `dialogId`, `tx` and `preview`. The UI and core normally run the same build (link makes the newest lead); these are the transient cases.

## Changes on 17 November (host data, all additive and optional)

- New file `data.ts`, re-exported: membership, settings and folder rows; `RosterResource`, `MediaResource`, `ComposeResource`, `SearchResource`; `MediaRef`, `AttachmentInfo`, `UploadProgress`, `MessageUpload`; `UserSettingsValue`, `UserSettingsPatch`; `COMPOSE_ACTION_RULE` (3 s refresh, 6 s expiry); search request and hit types (`SearchMessageHit` is Quick Search's `MessageHit`); helpers `memberRowId`, `isAttachmentId`, `newAttachmentId`, `mediaSendIntents`.
- `RowKind` adds `member`, `userGroup`, `folder`, `settings`; `SpaceRow` adds `handle?`, `creator?`, `photoUrl?`; `MessageRow.upload?`.
- `QueryDescriptor` adds `chatParticipants`, `spaceMembers`, `userGroups`, `spaces`, `userSettings`, `dialogFolders`, `media`, `composeActions`, `searchMessages`, `findInChat`, `countMessages`.
- `ResourceValue` adds `roster`, `media`, `compose`, `search`; `CoreResource.searchIndex?` (`building` with progress, `ready`, `failed`).
- `Intent` adds the settings, attachment, media and compose intents above.
- `optimisticMediaRow`, `localMedia`.
- Still no new `Command` kind: commands that carry data (a Blob, hints, compose activity) are intents, and requests that need cancelling (search) are subscriptions, because `link` routes commands exhaustively.

## Changes on 17 November (host features, all additive and optional)

- `ChatRow.lastMessageRowId?`, `ChatRow.createdBy?`.
- `DialogRow.followMode?`, `notificationMode?`, `unreadMentionsCount?`, `unreadReactionsCount?`, `folderId?`.
- `MessageRow.mentioned?`, `MessageRow.silent?`.
- `QueryDescriptor` adds `{ kind: "newMessages" }`; `NEW_MESSAGES_RULE`.
- `CoreResource.stalledSync?` and `SyncStall`.
- `Intent` adds `retrySync`, `invokeAction`, `submitForm`; `deleteMessages.clientKeys?`; `FormSubmissionValue`, `ActionAnswer`, `ACTION_ANSWER_TIMEOUT_MS`; `IntentResult.answer?`.
- `IntentRejection` adds `"offline"`.
- No new `Command` kind: carriers route commands exhaustively (`link`), so the sync retry is an intent.

## Changes from v0 (17 November 2026, all additive)

- `MessageRow` adds `media`, `groupedId`, `attachments`, `forward`, `replyQuote`, `replies`, `via`, `service`, `actions`, `blocks` and their types (`content.ts`); `hasUnsupportedContent` narrows to what is still not represented.
- `WindowResource.certifiedThrough?`.
- `Command` adds `trimWindow`.

- `Intent.sendText.date?`: the UI's date for the overlay row.
- `Snapshot.settled?`.
- `IntentRejection` adds `"unavailable"` (the core failed, is outdated, or is stopping).
- `Entity` adds `groupId`, `spaceId`, `title`, `botUserId`, `agentId`, `display`; `UserRow` adds `email`.
- `CoreEndpoint.close()` returns `void | Promise<void>`.
- Helpers: `rowKeyOf`, `isClientKey`, `newClientKey`, the reference reducer.
- `optimisticMessageRow` omits an empty `entities` array, as the core's rows do.

## Message content (`content.ts`)

`MessageRow` carries everything a message can hold as optional, plain, structured-cloneable data (branded ID strings, string unions for enums, `Uint8Array` for small byte payloads). A field the proto calls "unspecified" is omitted; a oneof this build does not know is `{ kind: "unknown" }` where the UI must know something was there. The core fills the fields in `client/src/queries/content.ts`; `chat-ui` builds render models from them.

| Field | From `proto/core.proto` | Notes |
| --- | --- | --- |
| `media` | `Message.media` (`MessageMedia`: photo, video, document, voice, nudge) with `is_sticker` as `sticker` on photo and video | `PhotoInfo` keeps every stored size except `s`, whose bytes are `stripped` (rebuild with `chat-ui` `strippedJpeg`). `VideoInfo.animated` is a GIF. |
| `groupedId` | `grouped_id` | Album identity across consecutive media messages. |
| `attachments` | `MessageAttachments` (`UrlPreview` with typed media and layout hints, `MessageAttachmentExternalTask`) | Unknown kinds are `{ kind: "unknown", id }`. |
| `forward` | `fwd_from` | Peer, original sender, original message. |
| `replyQuote` | `reply_quote` | `replyToMessageId` stays the reference; the quote is text. |
| `replies` | `subthread` (`MessageSubthread`) when present, else `replies` (`MessageReplies`) | `kind` `reply` or `subthread`, count, unread, recent user IDs, title. |
| `via` | `via` (`MessageVia`) | `app` (agent ID) or `bot` (user ID), with the name sent. Messages group only when `via` matches. |
| `service` | `service_message` | `threadBacklink`, `pinnedMessage`, `gridTranscript`, `unknown`. Service rows never group. |
| `actions` | `actions` (`MessageActions`) | Rows of buttons: `callback` (invoked by `actionId`; the bot's opaque payload is not carried), `copyText`, `openUrl`, `openLink`, `compose`, `unknown`; `style`, `confirm`, `requiredGrant`. |
| `blocks` | `block_content` (`BlockContent`) | Every `Block` kind with its fields and `BlockStatus` / `BlockDecisionState`. Text is `TextRange` (UTF-16 offset and length into `text`, plus the server's `rtl`). Unknown kinds are `{ kind: "unknown" }`. Ranges are not checked against the text here; the render model does that. |

Rules:

- **URLs are as sent.** Every URL in content (previews, buttons, task links, external video) is untrusted; the UI passes it through `chat-ui`'s `safeLink`.
- **`cdnUrl` is signed and expires.** A row built from the replica may carry an expired one. It is a hint, never a cache key; the media layer refreshes by `fileUniqueId` (`getFilePart`) or by fetching the message.
- **Form secrets.** A secret text field (`FormInput.style: "secret"`) never carries a default on the row, whatever the sender sent.
- **Widgets carry no HTML.** `blocks[].kind === "widget"` has the widget ID, title, height hint, images and `htmlLength`, not the HTML. Widgets render only in a sandboxed frame on a separate origin; the frame's host will get the HTML through its own query, so HTML never travels in ordinary rows and cannot reach a DOM sink by accident.
- **`hasUnsupportedContent`** still means "something here is not represented on the row": unknown or unreadable media, an unknown attachment, service event or button kind. Unknown block kinds do not set it: they are on `blocks` and fall back to their text.

Not carried yet, and why:

- `agent_session`, `counts_as_unread`, `unread_mention`, `unread_reactions`, `has_link`: not content; they belong to read state and the agent surfaces. (`mentioned` and a silent `send_mode` are on the row as `mentioned` and `silent`, for notifications; `counts_as_unread` is not stored by the replica.)
- The replica does not store `block_content`, `reply_quote`, `via` or `subthread` yet (`realtime/transactions/mappers.ts` `messageModel` drops them). The row mapping reads them when present, so `blocks`, `replyQuote`, `via` and subthread summaries appear once storage keeps them. Until then those fields are always absent on real data.
- Upload progress is not on rows (it would churn them); it is on the attachment's `media` resource.
