# Feature models (`@inline/view/features`)

The models between the core's query results and the views: the app, the signed-in account, the sidebar and each chat. Framework-free TypeScript over `@inline/reactive` signals; every model is created by an owner, disposed by it, and tested in Node against a scripted core (`@inline/reactive/testing`) with a manual clock.

```
AppModel                       booting | signedOut(signIn) | signedIn(session) | signingOut
 ├─ registry, keyboard         one for the app's life
 └─ AccountSession             one per signed-in account
     ├─ connection, client     injected connector (web/src/core/connect.ts)
     ├─ status, connection     core resource + rule 15 display delay
     ├─ health, retrySync()    offline / connecting / stalled sync, for an indicator
     ├─ me, workspace          workspace restored per account
     ├─ sidebar                SidebarModel (visible mode) + a hidden `all` list for the badge
     ├─ chats                  ChatCache → ChatModel per chat, a few kept resident
     ├─ intents                IntentTracker: actions' final outcomes
     ├─ dialogFor(chatId)      a chat's dialog row, through ChatRow.dialogId
     └─ actions                SessionActions: message commands, row and sidebar menus
```

## AppModel (`app-model.ts`)

```ts
const app = new AppModel({
  authStore,                         // AuthStore from @inline/auth (structural: getState, subscribe, logout)
  createSignIn: () => createSignInModel({ api, authStore, clock: systemClock, signOut: () => app.signOut(), provider }),
  session: {
    connect: connectAccount,         // web/src/core/connect.ts
    buildId: BUILD_ID, protocol: CORE_PROTOCOL_VERSION,
    clock: browserClock(),           // @inline/reactive
    storage: localStorage,           // workspace persistence, keyed by account
    opener: (destination, target) => window.open(toAppUrl(destination)),
  },
  eraseAccountData: (userId) => eraseBootSnapshotAndCaches(userId),   // idempotent
  signOut: () => signOut({ authStore, api, clock: systemClock }),     // @inline/auth/flows, WITHOUT eraseAccountData
  platform: detectPlatform({ navigator, desktop: false }),
  onTypeToFocus: () => focusComposer(),
})
```

- `phase`: a signal of `{ kind: "booting" }`, `{ kind: "signedOut", signIn }`, `{ kind: "signedIn", session }` or `{ kind: "signingOut", userId }`. The root view switches on it and nothing else.
- `session`: the session while signed in. `registry`, `keyboard` (`KeyboardDispatcher`): live for the app's life; a session registers its commands into `registry` and removes them when it ends.
- `signOut()`: runs the injected sign-out. The account ends when the auth store reports it, so a sign-out here, in another tab (the auth persistence broadcasts) and a revocation reported by the core (`connection: "sessionRevoked"`, on which this model calls `authStore.logout()`) take one path: dispose the session (which posts `session signOut`, so the core erases the replica), clear the account's saved workspace, await `eraseAccountData(userId)`, then `signedOut` with a fresh sign-in model. A login that lands while erasing waits for it.
- `idle()`: resolves when a teardown finished. `dispose()`: closes everything without erasing (app shutdown).

## AccountSession (`account-session.ts`)

Created by `AppModel`; construct it directly only in tests or a lab. On construction it connects, posts `hello` (when `buildId` is given) and `session start`, and subscribes to `core`, `me`, `sidebar(inbox)` and `sidebar(all)`.

| Member | What |
| --- | --- |
| `coreResource` | The core's `CoreResource` (phase, connection, storage) or undefined until it answers |
| `connection` | The connection state to show now: shown at once on cold start, after 1 s on a reconnect, hidden at once on `connected` (rule 15, Mac `RealtimeState`) |
| `status` | `SessionStatus`: `starting`, `outdated`, `superseded`, `failed`, `signedOut`, `storageFull`, `connecting`, `updating`, `waitingForNetwork`, `storageNotKept`, `ready`, in that priority. Unchanged; stalled sync is in `health` |
| `health` | `SessionHealth`, for an indicator beside `status`: `starting`, `stopped` (see `status`), `refused` (session revoked), `offline` (no network: actions needing one are refused `offline`, sends wait), `connecting` (has network, reaching the server), `updating`, `syncStalled` (`{ stalls, retryable }`: some sync scopes stopped retrying; their data may be behind; `retryable` when a retry may help), `ok`. Connection kinds follow the rule 15 delay, like `connection` |
| `stalledSync` | `CoreResource.stalledSync`, empty when none. `isSyncStalledFor(stalls, { chatId, spaceId?, peerUserId? })` says whether one covers a chat (for a quiet "may be behind" note in the chat) |
| `retrySync()` | Posts `retrySync`; returns an `ActionHandle` (the core confirms at once; `health` clears when the stalls do) |
| `dialogFor(chatId)` | The chat's `DialogRow` signal: the chat row's `dialogId` (set on every chat row the core publishes) to the dialog row, both read from the store, one cached computed per chat; undefined while either is not on this context. Chat models take their `readState` from it |
| `intents` | The `IntentTracker` the chat models and actions share |
| `actions`, `attachActions(hooks)` | `SessionActions` (below) and its view hooks; `attachActions` returns a detach function |
| `revoked` | The core reported `sessionRevoked` |
| `me` | The signed-in user's row |
| `workspace` | Restored from `storage` under `inline:workspace:<userId>`; saved on every change and on `flush()` |
| `registry` | Navigation commands registered and wired: back and forward (through the history binding when set), previous and next chat (sidebar), focus, quick search, toggle sidebar, settings, close pane; and the message commands (`SessionActions`) |
| `sidebar` | `SidebarModel` for the visible mode |
| `badgeCount` | Prominent unread chats over every non-archived chat (its own `all` list) |
| `chats`, `openChat(chatId, anchor?)` | The resident chat cache; `openChat` returns a lease `{ model, release }` |
| `setHistory(binding)` | Give Back and Forward the history binding once the app created it for `workspace` |
| `attachView(hooks)` | `focusRegion`, `openQuickSearch`, `toggleSidebar`, `openSettings?`; returns a detach function. Default no-ops |
| `flush()` | Save the workspace now (call on `pagehide`) |
| `exportProvisional({ chatId?, select? })` | The boot snapshot's data: `me`, the visible sidebar list and, with `chatId`, that resident chat's window, with the rows each needs (`relatedRowKeys`); `select` keeps part of each list before rows are collected. Overlay rows are not exported |
| `restoredFromSnapshot` | The session started from `AccountConnection.provisional` |
| `end({ erase })`, `dispose()` | Teardown; `AppModel` calls them. `end` posts `session signOut` and releases the models at once; when the core was seen running a session, it keeps the connection and the `core` subscription until the core reports `phase: "signedOut"` (which it does only after the erase; `erased: "complete" | "failed"`), or `signOutWaitMs` (`SIGN_OUT_WAIT_MS`, 10 s) passes. It resolves with a `SignOutOutcome` (`erased`, `eraseFailed`, `timedOut`, `notRunning`, `interrupted`), also on `signOutOutcome`. `dispose()` during the wait closes at once |

### Starting from the boot snapshot

A connector may return `provisional` (a `ClientSnapshotData` from `exportProvisional`, see `web/src/app/boot-snapshot/README.md`). The session posts `hello` and `session start`, then restores it into its client (`client.restore`, which posts the subscriptions again), and its models take the restored subscriptions over instead of subscribing: `SidebarModel` and `ChatModel` take a `subscribe` option, and the session's matches a restored subscription by query (a chat window by chat, unless the model asks for a message). So the sidebar, the user and a chat's window read the snapshot's rows in the same task. Restored subscriptions nobody took are released at once, except chat windows, which wait for their pane until the core is ready. While a chat's draft row is still provisional, `ChatModel.draft` is undefined: the composer starts from the core's draft (the restored one can be older), the sidebar shows the restored one.

### Resident chats (`chat-cache.ts`)

`chats.open(chatId, anchor?)` creates or reuses a `ChatModel` and returns a lease. Chats shown in a pane (their current destination) and leased chats are never released and do not count against the capacity; of the others the `capacity` most recent (default 5) stay subscribed, so switching back paints from memory. A released model whose send is still in flight stays alive until the send's first result. Opening a resident chat at `{ around }` moves its window there.

## SidebarModel (`sidebar-model.ts`)

The `sidebar` query carries every row an item reads (chat, peer, last message and its sender, draft, space, parent chat), so every item has its preview from the first result, open window or not.

- `items`: ordered dialog row keys, exactly the core's order (rules 6 and 7 are the core's). A list view observes only this. After `setMode`, the previous mode's list until the core answers the new one.
- `ready`: true when `items` is the current mode's list as the core answered it (an empty answer counts) or as the boot snapshot restored it; false on first load until the answer, and while a mode switch holds the previous list. Wiring: pass it as `SidebarView`'s `ready`; show the empty state only when ready. It needs option `core` (the session passes its endpoint); without it `ready` is "non-empty or restored" and `setMode` does not hold.
- `item(key)`: one cached computed per key, a `SidebarItem` with `title` (DM: the peer's display name; thread: trimmed title, else "New thread"; else "Chat"), `emoji`, `avatar` (`{ kind: "user", userId, seed, photoUrl? }` or `{ kind: "chat", chatId, seed, emoji? }`), `preview`, `date`, `unreadCount`, `unreadMark`, `hasUnread`, `prominent` (rule 9), `pinned`, `selected`, and (always set by the model, optional in the type so hand-built items stay valid) `open`, `archived`, `temporary` (inbox only: not open and not pinned, shown because selected, rule 7: italic row, "Close from Sidebar" and "Keep in Sidebar"), `unreadMentionCount` and `unreadReactionCount` (the `@` and reaction badges; 0 when none or unknown), `followMode`, `notificationMode`. It keeps its identity while nothing it shows changes: a change to one chat re-runs that item's computed only; a reorder re-runs none; selecting a chat re-runs a tiny per-item flag and the two items whose flag changed.
- `preview`: `{ kind: "draft", text }` before `{ kind: "message", text, outgoing, sender? }`, else `none`. The last message is `ChatRow.lastMessageRowId` (a send from this device by client key), else `lastMessageId`. `sender` is the sender's short name for threads (render "Grace: text", Mac `HomeChatListItemSnapshot.preview`), absent in DMs. Text without text: a document's "📄 name", else "Photo", "Video", "Sticker", "Voice message", "Nudge", "Message" (`messagePreviewSource`).
- `prominentUnread` (`{ keys, indices }`, indices into `items`), `prominentUnreadKeys`, `prominentUnreadCount`: the items with prominent unread, from each dialog and chat only, never the selection, so a chat switch recomputes nothing here. The badge reads the count; "unread below" reads `indices` (or keys) without peeking every item.
- `subscription`: the current mode's subscription (exported by the boot snapshot). Option `subscribe` replaces `client.subscribe`.
- `open(key, intent?)`, `selectAdjacent(-1 | 1)` (stops at the ends; with nothing selected, next is the first and previous the last), `setMode(mode)`, `canSelectAdjacent`, `selectedChatId`, `dialogFor(chatId)`.
- Prominence (rule 9): a DM, or `DialogRow.followMode === "following"`. `hooks.isFollowing({ dialog, chat })` can add more.

## ChatModel (`chat-model.ts`)

| Member | What |
| --- | --- |
| `rowKeys` | Message row keys, oldest first. A sent message is at the end in the same task |
| `row(key)` | The row signal of one message. Each row view observes its own row |
| `window` | `{ ready, hasOlder, hasNewer, atLatest, loading, unreadBoundary?, certifiedThrough? }`; `ready` is false until the core answers (`loading: "initial"` then). Pass `certifiedThrough` to the timeline controller's window as `contiguousThrough` |
| `chat`, `peer`, `header` | Header inputs: `title`, `emoji`, `avatar`, `isDirect`, `peerUserId`, `peerIsBot`, `spaceId`, `parentChatId` |
| `draft` | The saved draft row, for the composer's `initial` and `setDraft` |
| `readState` | `{ unreadCount, readMaxId }` from the chat's dialog, for the timeline's `setReadState` |
| `ensureOlder/Newer/Latest/Around`, `request(range)` | Window paging; `request` is the timeline controller's `request` option |
| `send(text, entities?, replyTo?, { draftRevision? })` | Builds `sendText` with a fresh client key, the wall-clock date and `draftRevision` (the core deletes the draft in the send's own commit), installs `optimisticMessageRow` with the intent's `tx` (the same row the core shows while the send is in the outbox) in the overlay (appended to the window only when it is at latest; otherwise the window moves to latest), and returns a `SendHandle`: a promise of `SendResult` with `tx`, `rowKey` and `clientKey` readable at once |
| `sendFromComposer` | The composer's `send` option: maps `SendResult` to `{ status: "accepted" }` or `{ status: "rejected", reason }` (`uncertain` is a rejection with reason `uncertain`: keep the text) |
| `saveDraft(text, entities, revision)` | The composer's `saveDraft` option |
| `markRead(maxId)` | The timeline's `markRead` option. One frontier in flight, higher ones coalesced, never lower than one sent; retryable failures back off 0.5 s → 8 s with ±20% jitter (Mac `UnreadManager`). Clamped to `window.certifiedThrough` when the core gave it |
| `trimWindow({ from, to })` | The timeline trimmed its rendered range: posts `trimWindow` on the window's subscription so the core releases rows outside it (inclusive message IDs). Not sent when it would release nothing, or when it repeats the last range before the window moved (any `request`/`ensure*` resets that). Returns whether it posted. Needs option `post` (the session passes the endpoint's) |
| `trimToRows(keys)` | `trimWindow` for the row keys the timeline keeps (its rendered slice of `rowKeys`): from the oldest to the newest of them with a server ID. Wiring: when the controller's `range` shrinks, call `model.trimToRows(rowKeys.slice(range.start, range.end))` (map timeline item keys to message row keys first) |
| `edit(messageId, text, entities?)` | `editText`. The new text shows in the same task (UI overlay, see below) |
| `delete(messageIds, { clientKeys? })`, `deleteRows(rowKeys)` | `deleteMessages`. `deleteRows` names each row by server ID, or by client key for a send from this device without one; deleting a message still sending cancels it. Rows go with the core's patch (no UI prediction: the overlay cannot remove rows) |
| `react(messageId, emoji)`, `unreact(...)`, `toggleReaction(...)` | `react` add or remove; `toggleReaction` reads the row's `mine` (a chip click). Shown in the same task (UI overlay) |
| `invokeAction(messageId, actionId)`, `submitForm(messageId, formId, values)` | A bot button and a form block; `outcome` carries the bot's `answer` |
| `resend(rowKey)` | `retrySend` with the failed send's client key |
| `abilities(rowKey)`, `lastEditableMessageId()` | `messageAbilities` of a row for the viewer; the viewer's newest editable message (Up in an empty composer, rule 10) |
| `retain()`, `users`, `dispose()` | Counted users; at zero the model unsubscribes. The cache and sends hold counts |
| `windowSubscription` | The window's subscription (exported by the boot snapshot). Option `subscribe` replaces `client.subscribe` |
| Options `intents`, `post` | The session's `IntentTracker` (final outcomes) and its endpoint's `post` (for `trimWindow`); `dialog` is `session.dialogFor(chatId)` |

`SendResult`: `accepted` (durable; the composer may clear), `rejected` with `reason` (`storageFull`, `unavailable`, `invalid`, ..., or `disposed`) and `retryable`, or `uncertain` with `retry()`. A retry, or a new send of the same `draftRevision` and text, reuses the client key, which the core and server deduplicate, so it cannot double the message.

`sendFromComposer` also takes the composer's edits (`kind: "edit"` with `edit.messageId`): `accepted` once the core admitted the edit, else `rejected` with the reason (`offline`, `uncertain`, ...), which keeps the text.

### Actions and their outcomes (`intent-outcome.ts`)

Every action returns an `ActionHandle`: a promise of its first result and, at once, `outcome`, a promise of its final one. Neither rejects.

- First (`ActionResult`): `accepted` (admitted and shown in this session; for edit, delete and react nothing is durable until the server answers), `rejected` (`reason`, `retryable`, `notice`), or `uncertain` (`notice`).
- Final (`ActionOutcome`): `confirmed` (with `answer?` for buttons and forms), `rejected`, or `uncertain`.
- `notice: ActionNotice` is what a view shows without guessing: `kind` `offline` ("You're offline": needs a connection, retryable), `storageFull`, `refused` (the server refused it, `server`; not retryable), `unavailable` (the core is not running), `uncertain` (tone `warning`: "Not confirmed yet"; never shown as failed or done), `failed`; with `tone`, `title` and `text`. `actionNotice(what, reason)` builds one.
- `IntentTracker` resolves a final result once the store applied the patch that carried it, also when acceptance and outcome arrive in the same frame. The session shares one; a `ChatModel` without option `intents` falls back to the next result the store delivers, which can miss that case.
- What the user sees meanwhile is the core's overlay of open edits, deletes and reactions. The model adds a UI prediction only for reactions and edits, installed in the same task as the input and dropped with the core's row or the settlement: the core's overlay arrives a worker round trip later, which can be a frame after the click or key (reactivity.md lists react as a sync-lane echo). An unrelated patch carrying the same message before the core's (another user's reaction) drops the prediction for that frame.

`messageAbilities(row, viewerId)` (`message-abilities.ts`): `reply`, `edit` (own, sent, with an ID, not a service message or an upload), `delete` (anything not still sending, by ID or client key; others' messages too, as on the Mac: the server refuses what the viewer may not), `cancel` (sending with a client key), `react`, `resend` (failed with a client key), `copyText`, `copyLink`. Also `canEditMessage`, `canDeleteMessage`.

## SessionActions (`session-actions.ts`)

`session.actions`. The message commands, a message row's actions and a sidebar row's menu, from the Mac (`MessageView.createMessageMenu`, `SidebarNativeRowView`). What only a view can do comes through `session.attachActions(hooks)`:

| Hook | Used by |
| --- | --- |
| `reply(target)`, `edit(target)` | Reply, Edit: put that chat's composer in reply or edit mode (`target`: `{ chatId, rowId, key, messageId?, row }`) |
| `copyText(text, target)`, `copyLink(destination)` | Copy Text; Copy Message Link (`{ kind: "message" }`) and the sidebar's Copy Link (`{ kind: "chat" }`) |
| `openReactionPicker(target, anchor?)` | Add Reaction…; the picker then calls `session.actions.toggleReaction(target, emoji)` |
| `notify(notice)` | A refused or uncertain action, once (a toast) |
| `answer(answer)` | A bot's answer to `invokeAction` (toast or alert) |
| `isTextSelected()` | Copy Text's Cmd/Ctrl+C is disabled while text is selected, so the browser copies the selection |

An action whose hook is missing is left out of the lists and its command is disabled.

- **Commands** (`messageCommandIds`, scope `timeline`, never while typing), acting on `focused`, the message the list reports with `actions.setFocused(rowId | undefined)` (wire it to the row actions controller's keyboard focus): `message.reply` (Mac Cmd+R; unbound in a browser, which owns it), `message.edit` (Cmd/Ctrl+E), `message.addReaction` (no shortcut: the Mac menu gives it Cmd+E, which Edit has), `message.copyLink`, `message.copyText` (Cmd/Ctrl+C), `message.resend`, `message.cancel`, `message.delete` (Cmd/Ctrl+Backspace; cancels a message still sending, as the Mac's Delete key does). Each is enabled from the focused message's `messageAbilities` and its hook.
- **`actionsFor(rowId)`**: the row's actions in the shape `MessageActionsController` takes (`{ id, label, icon?, shortcut?, enabled, destructive?, quick?, group?, run }`): Reply, Edit, Add Reaction… (`quick`), Copy Message Link, Copy Text, Resend, then Cancel or Delete (`destructive`), only those that apply. Shortcut hints come from the registry for the session's `platform`. Delete, Cancel, Resend and Add Reaction are disabled when the chat is not resident. Wiring: `new MessageActionsController({ actionsFor: session.actions.actionsFor })`.
- **`sidebarActionsFor(item)`**: the sidebar's `SidebarAction` list: a temporary row gets Close from Sidebar, a separator, Keep in Sidebar; others Pin or Unpin (`setDialogPinned`), Mark Read (`readAll`) or Mark Unread (`markUnread`), Close from Sidebar when open (`setDialogOpen`), Archive or Unarchive (`setDialogArchived`), a separator, Notifications ▸ (a `submenu` of `radio` entries Default, All, Mentions, None, the dialog's `notificationMode` checked, absent is Default: `setDialogNotifications`) and, for a thread (no `peerUserId`), Follow Thread or Unfollow Thread (`setDialogFollow` with `following` or `unfollowed`); then Copy Link with the `copyLink` hook. `SidebarRowAction` is the sidebar's `SidebarAction` shape: actions, `radio`, `submenu` and separators. Wiring: `SidebarView`'s `actions={session.actions.sidebarActionsFor}` (replaces `basicActions`).
- `delete(target)`, `resend(target)`, `toggleReaction(target, emoji)`, `invokeAction(target, actionId)`, `target(rowId)`: the same, for a view's own controls (reaction chips, bot buttons); refusals go to `notify`.

## Pure helpers

- `chatTitle`, `chatAvatar`, `destinationChatId`, `compareMessageIds` (`helpers.ts`).
- `relatedRowKeys(row)` (`account-session.ts`): the rows a row needs to be drawn that are not in a list.
- `createConnectionDisplay`, `sessionStatus`, `sessionHealth`, `isSyncStalledFor`, `chatSubtitle` (connection, then typing, then bot status) (`connection-status.ts`).
- `sidebarPreview`, `messagePreviewSource`, `isProminentUnread`, `prominentUnreadCount` (`sidebar-model.ts`).
- `predictReactions` (`chat-model.ts`); `actionNotice`, `actionOutcomeOf`, `actionHandle` (`intent-outcome.ts`); `messageAbilities` (`message-abilities.ts`); `chatIdOfRowId` (`session-actions.ts`). `AccountSession.dialogFor(chatId)` reads `ChatRow.dialogId` (no index of its own).
- `ReadMarker`, `readRetryDelayMs` (`read-marker.ts`).
- `addedKeys`, `isUnread`, `messageNotificationFacts` (feeds `decideMessageNotification` from `@inline/platform`; reads the row's `mentioned` and `silent` and the dialog's `notificationMode`, which `chatMode` overrides), `notificationDestination` (`notifications.ts`).

## Wiring the views (`web/src`)

1. Create one `AppModel` at boot (above) and keep it for the page's life. Call `app.dispose()` only on shutdown.
2. Root view: `useSignal(app.phase)`; render sign-in with `phase.signIn`, the shell with `phase.session`, a plain splash for `booting` and `signingOut`.
3. Keyboard: one `keydown` listener on `window` calling `app.keyboard.handleKeyDown(event)` (see `commands/keyboard.ts`); regions call `app.keyboard.setFocusScopes([...])` on focus changes.
4. History: in the shell, `const binding = bindWorkspaceToHistory(session.workspace, createBrowserHistory(window))`, then `session.setHistory(binding)`; dispose the binding with the shell.
5. View hooks: `session.attachView({ focusRegion, openQuickSearch, toggleSidebar })` from the shell; call the returned function on unmount.
6. Badge and title: an app-level controller (not a view) runs `effect(() => platform.badge.set(session.badgeCount.get()))` inside the session's lifetime, and `immediate: true` on sign-in and sign-out.
7. Sidebar: the list view reads `session.sidebar.items`; each row gets a key and reads `session.sidebar.item(key)`; click and Enter call `sidebar.open(key, intent)`. Pass `ready={session.sidebar.ready}` and `actions={session.actions.sidebarActionsFor}`; "unread below" can read `sidebar.prominentUnread` (`indices`) instead of counting items itself.
8. Pane: for a destination with a chat, take `session.openChat(chatId, anchor)` from a model created with `useModel` (release the lease in its `dispose`). Feed the timeline controller from `model.rowKeys`, `model.row(key)`, `model.window` (with `contiguousThrough: window.certifiedThrough`) and `model.readState`, with `request: (r) => model.request(r)` and `markRead: (d) => model.markRead(d.maxId)`; when its rendered range shrinks, `model.trimToRows(keptRowKeys)`. Feed the composer with `send: model.sendFromComposer` (sends and edits), `saveDraft: (t, e, r) => model.saveDraft(t, e, r)` and `initial` from `model.draft.peek()`; Up in an empty composer edits `model.lastEditableMessageId()`.
9. Status: the chat subtitle is `chatSubtitle({ connection: session.connection.get(), isDirect, peerIsBot })`; window chrome shows `session.status` for `outdated`, `superseded`, `failed`, `storageFull` and `storageNotKept`; a quiet indicator shows `session.health` `syncStalled` with a Retry button calling `session.retrySync()` (only when `retryable`).
10. Actions: once in the shell, `session.attachActions({ reply, edit, copyText, copyLink, openReactionPicker, notify, answer, isTextSelected })`, routing reply and edit to the pane that shows `target.chatId`; call the returned function on unmount. The message list's row actions controller takes `actionsFor: session.actions.actionsFor` and reports keyboard focus with `session.actions.setFocused(rowId)`; reaction chips call `session.actions.toggleReaction(target, emoji)`, bot buttons `session.actions.invokeAction(target, id)`.
11. Lifecycle: on `pagehide`, `session.flush()` (and the composer's `flushDraft`).

### What a view must not do

- Call a signal directly in render; read through `useSignal`.
- Reorder `sidebar.items` or filter rows out of `model.rowKeys`.
- Post intents or subscriptions itself; go through the models.
- Clear the composer on anything but `accepted`.
- Predict an edit, delete or reaction itself; the model and the core's overlay do.
- Keep a `ChatModel` without a lease, or dispose a model it got from `openChat` (release the lease instead).
- Show `uncertain` as failed or delivered.

## Needs from others (`TODO(contract)` in the code)

- **Chat to dialog.** `session.dialogFor` reads `ChatRow.dialogId`; a chat whose dialog row never reached the context (an archived chat opened from a link, before any query carries its dialog) has no `readState` until one does.
- **`trimWindow` through the store client.** `StoreClient`/`SubscriptionHandle` (`@inline/reactive`) have no method for it, so `ChatModel` posts it through an injected `post` (the session passes the endpoint's).
- **Answered lists in the store.** The view store cannot tell an empty answer from no answer, so `SidebarModel.ready` listens to the endpoint itself (`core` option). A per-subscription "answered" flag in the store would replace that.
- `sendText` cannot consume the draft revision in its transaction.
- Account notification settings (`globalMode`, sound) come with the `userSettings` query, which these models do not read yet; typing and the peer's local time are other queries (`composeActions`) the chat model does not subscribe to yet.
- **Confirming a delete:** give `attachActions` a `confirmDelete(target, proceed)` hook and every delete path (row menu, quick action, the `message.delete` command, the command bar) asks first; `proceed` deletes, not calling it declines. A message still sending is cancelled without asking. Without the hook a delete runs at once.
- Reply in Thread, Quote, Forward, Select and Pin message are not in the message action set: the contract has no intents for them yet (thread creation, forward, message pin). Mute, follow and notification mode are not in the sidebar menu: the intents exist (`setDialogNotifications`, `setDialogFollow`) but the Mac's basic set does not have them; add them with the chat menu.

## Known limits

- `unreadBoundary` is the core's, captured when the window subscription opened; a resident chat reopened later keeps its first boundary.
- The Mac sidebar shows a DM's first name only; this uses the full display name.
- `actionsFor` decides "chat is resident" when called; a menu built while the chat is resident keeps Delete enabled if the chat leaves the cache while it is open (the action then does nothing).
- `SessionHealth` connection kinds use the rule 15 delay: a short drop after the first connection shows nothing.

## Tests

`bunx vitest run src/features` from `web/packages/view`: sidebar derivation, drafts, selection, single-item notification and reorder budgets, next and previous; send echo in the same task and confirmation under the same key, rejection, uncertainty and idempotent retry; mark-read coalescing, monotonic frontier and backoff; the resident cache; the rule 15 display delay; the session's wiring and teardown; starting from a boot snapshot (`account-session.provisional.test.ts`: export, restore to an identical view in the same task, identity kept on confirmation, the draft rule, releasing an unclaimed window, a message link opening its own window, ready and dialogs from the snapshot); the app model's boot, sign-in, sign-out here, in another tab (two `AuthStore`s over shared persistence) and by revocation, each checking no subscription is left and the endpoint is closed.

- `sidebar-model.rows.test.ts`: previews without an open window, the thread sender, a last message by client key, media labels; follow-mode prominence; counts, modes, open, archived, temporary; the prominent unread list independent of the selection; one chat re-runs one chat's derivations and a reorder none (counted through the follow hook); `ready` on an empty answer and from a snapshot; the hold across a mode switch (both subscribed, one list render, released on the answer, an empty answer, switching again and back, disposal).
- `chat-model.actions.test.ts`: edit (same-task text, accepted then confirmed, offline restores the row, uncertain), an outcome in the same frame as the acceptance, storage full and unavailable notices, delete by ID and client key, cancelling a send in flight, reaction prediction and toggling, a send found by server ID, buttons with the bot's answer and forms, resend, composer edits, the fallback without a tracker, abilities and the last editable message; the trim command's sub and range, no repeat, no-op ranges, reset after the window moves, `trimToRows`; `certifiedThrough` and the read clamp.
- `session-actions.test.ts`: the commands' shortcuts (none reserved, no conflicts), enabled states for the viewer's, someone else's, a sending and a failed message, with and without hooks, Copy Text and a selection, running delete and cancel, offline and uncertain notices and a bot's answer; action lists for each kind of message with shortcut hints per platform; the sidebar menu and its intents, the Notifications submenu (current mode checked, each mode's intent) and Follow or Unfollow (threads only), temporary rows, a refused pin; health (offline after the delay, connecting, stalled, retry, not retryable, revoked); `dialogFor` through `ChatRow.dialogId` (an archived chat, a chat row without one); the trim through the session; `ready` through the session.
- `notifications.test.ts`: `mentioned`, the dialog's mode and its override, silent sends.
