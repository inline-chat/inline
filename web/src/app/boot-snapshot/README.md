# Boot snapshot (`web/src/app/boot-snapshot`)

What was on screen, saved when the page hides, painted synchronously on the next start before the worker, WASM and SQLite exist, then replaced by the core's answer without a flash. Background: `web/docs/reactivity.md` ("Boot snapshot"), `web/docs/performance.md` (warm start, first paint of sidebar and last chat in 150 ms), `web/docs/decisions.md` (kept in `localStorage`).

## Files

| File | What |
| --- | --- |
| `format.ts` | `BootSnapshot`, the constants (key, version, budget, how many rows), `parseBootSnapshot` (checks every structural field; never throws). |
| `storage.ts` | `readBootSnapshot`, `writeBootSnapshot`, `eraseBootSnapshot`: synchronous, never throw; an unusable snapshot is removed when read. |
| `capture.ts` | `captureBootSnapshot(session, options)`: what is on screen, cut to the budget. |
| `restore.ts` | `provisionalData(snapshot)`: the exported subscriptions with the chat window asked for again where the reader was. |
| `deferred-endpoint.ts` | `DeferredEndpoint`: the core endpoint of a session painted from the snapshot, queueing until the auth store confirms. |
| `hinted-auth.ts` | `hintedAuthStore`: the auth store as the app model sees it until the real one has read IndexedDB. |
| `saver.ts` | `attachBootSnapshotSaver`: when to save, and erasing on what the core reports. |
| `*.test.ts`, `test-support.ts` | Node tests (below). |

Wired by `../boot.ts` (read), `../runtime.ts` (provisional session, confirmation, saver, erase) and `../App.tsx` (the paint mark, the silent teardown frame). Model-side support is in `@inline/view/features` (`AccountConnection.provisional`, `AccountSession.exportProvisional`, `relatedRowKeys`, the models' `subscribe` option) and `@inline/reactive` (the view store's provisional layer).

## Format

One `localStorage` key, `inline:boot-snapshot`, holding JSON:

```ts
{
  format: "inline.boot-snapshot",
  version: 1,                 // BOOT_SNAPSHOT_VERSION: this format and the row types
  build: "<build ID>",        // the build that wrote it
  user: "<user ID>",          // the account; also the synchronous sign-in hint
  savedAt: 1763340000000,     // wall clock, ms
  chat?: { chatId, around? }, // the chat whose window is included, and the message it was cut around
  client: ClientSnapshotData  // StoreClient.exportSubscriptions: queries + { lists, rows }
}
```

`client` holds three subscriptions and the rows they need (`relatedRowKeys`: a dialog brings its chat, peer and draft; a chat its peer and last message; a message its sender, chat and draft):

- `me`: the signed-in user.
- `sidebar` for the visible mode: the first `SNAPSHOT_SIDEBAR_ITEMS` (60) dialogs, more than a 1600 px window shows.
- `chatWindow` of the focused pane's chat (a `chat` or `thread` destination; a message link reopens at its message instead): `SNAPSHOT_WINDOW_ROWS` (60) rows, from `SNAPSHOT_ROWS_ABOVE_PLACE` (10) above the saved reading place's message, or the newest 60 when the reader was at the end. Its window resource is rewritten to what the cut window can say: `hasOlder`/`hasNewer` set where rows were cut, `atLatest` false if the newest were cut, `loading: "none"`, and no `unreadBoundary` (it was fixed for the visit that ended; the core's window brings the current one).

Not in it: the core resource (the phase must come from the core), other chats, settings, the workspace and layout (already kept per account under `inline:workspace:<id>` and `inline:layout:<id>` and read synchronously by the session and the shell), tokens or keys. The test "keeps what is on screen" checks the token never appears in the text.

**Reading.** Anything unreadable (not JSON, not our shape, a row without a kind, a list that is not keys), from another schema version, or from another build is removed and ignored. A snapshot for a user the auth store already rules out is removed by the runtime.

**Other builds are discarded.** Row types live in `core-protocol` and change between builds without a version bump: the UI and the core always come from the same build, so the protocol has no compatibility story (`architecture.md`). A row of an older shape can break a view in its first frame, where there is no recovery. The cost of discarding is one cold start after each deploy. `version` still matters in development, where the build ID is fixed for a server's life while the code changes.

## Budget and measured cost

`BOOT_SNAPSHOT_BUDGET` is 196,608 UTF-16 code units (192 Ki) of JSON, what `localStorage` counts against its quota of about 5 million per origin (about 4% of it). A typical snapshot is 40 to 70 thousand: 60 sidebar items at about 0.6 to 1 K each (dialog, chat, user, last message) and 60 messages at about 0.3 to 0.6 K. The cap is there for pathological text (a pasted log as the last message of several chats); it also bounds the synchronous parse on the start path and the write in `pagehide`. Over budget, the chat window is dropped first (the sidebar is what every start shows), then the sidebar list is halved until it fits; if even the user alone does not fit, nothing is stored.

Measured in Node 24 on an M-series Mac (V8, as Chromium), with the account fixtures in `test-support.ts` (sidebar last messages of 160 characters):

| Account | Snapshot | Capture + `JSON.stringify` | `JSON.parse` + checks |
| --- | --- | --- | --- |
| 60 chats, 60 messages of 120 characters | 50 K | 0.54 ms first call, 0.10 ms warm | 0.22 ms first, 0.09 ms warm |
| 300 chats, 200 messages of 400 characters | 67 K | 0.21 ms first, 0.11 ms warm | 0.11 ms first, 0.09 ms warm |
| 2,000 chats, 500 messages of 200 characters | 55 K | 0.14 ms first, 0.09 ms warm | 0.11 ms first, 0.08 ms warm |

The export selects rows before collecting them (`ExportOptions.select`), so a 2,000-chat sidebar costs the same as a 60-chat one. With the 4x CPU throttle that is about 2 ms for a cold save and 1 ms for the read, plus `localStorage.setItem`/`getItem` of 50 K (not measurable in Node; Chromium copies the string and writes to disk off the main thread). That fits a `pagehide` handler. The coordinator should confirm both in a browser (below).

## When it is saved

`attachBootSnapshotSaver`, one per session, from the runtime:

- `visibilitychange` to hidden (the platform's `lifecycle.visible`) and `pagehide`: one write per hide (a tab close fires both); showing the page again re-arms it. `beforeunload` and `unload` are not used: browsers skip them on mobile, on bfcache and on crashes.
- In the idle lane at most every 30 s (`SNAPSHOT_IDLE_INTERVAL_MS`) while something it shows changed (the store's revision, the focused destination, the sidebar mode), so a crash loses at most that.
- Only while the core reports `phase: "ready"`: before that, what is stored is as new as anything in memory.
- Erased (and not saved) when the core reports `outdated`, `signedOut` (the replica was erased) or `storage: "memory"` (the replica is not kept; neither is the snapshot).

## Boot ordering

`boot.ts`, in the entry module's first task:

1. `readBootSnapshot(localStorage, { buildId, signedOut })` before any `await` (also before the demo's dynamic import) and before a core exists. `signedOut` reads the auth persistence's logout tombstone (`inline-web-session:logout-pending`, synchronous): a sign-out that did not finish erases the snapshot unread.
2. The auth store is created; it reads IndexedDB asynchronously. **The user ID cannot be known synchronously from it** (`userIdHint` is also only known after hydration), so the snapshot's `user` is the hint.
3. `AppRuntime` with `bootSnapshot.initial`. If the auth store has already answered for another user or none (the demo logs in synchronously), the snapshot is erased. Otherwise the app model gets `hintedAuthStore`: until the real store hydrates it reports the hinted user with `PENDING_TOKEN`, so the app model starts the session in this task.
4. The session's connector call reaches `#connectProvisional`: a `StoreClient` over a `DeferredEndpoint`, with `provisionalData(snapshot)`. The session posts `hello` and `session start` (queued), restores the snapshot (`client.restore`), and its models take the restored subscriptions over (`#subscribe` matches by query; a chat window matches by chat unless asked for a message). The sidebar, the user and, when the pane opens its chat, the chat window are readable now. **The real connector has not been called.**
5. Phase `signedIn`: the effect in `boot.ts` requests the shell chunk; `App` renders `ShellGate`, which shows the neutral frame until the chunk is there (the service worker's cache after the first visit), then the shell with the provisional sidebar and chat. `inline.boot.snapshot-paint` is marked after that paint.
6. The auth store answers. Same user with a token: `#confirmProvisional` calls the real connector, disposes the connector's own store client (the session reads through the provisional one), and attaches the deferred endpoint, which sends the queue in order with `session start` carrying the confirmed token (a stand-in never leaves the endpoint). Otherwise the app model tears the session down in that same task (phase `signingOut`, a silent neutral frame, no "signed out elsewhere" notice), and the snapshot is erased; for another user, that user's session then starts normally.

So the worker starts only after the auth store answers (a few ms of IndexedDB). Starting it in parallel would need the core to accept subscriptions before `session start` without answering them as signed out; it is listed under "Next" in the report, not done.

## Reconciliation

- **Provisional rows.** `importSnapshot` puts rows in the view store's provisional layer, under the core's rows, and marks the restored subscriptions provisional (`store.provisionalSubs`). The core's first message to a new context is a snapshot sent before anything is computed; it names no list and does not remove provisional rows. A provisional list is replaced when the core sends that subscription's list. A core row equal to the provisional one takes its object (`installRow` keeps identity), and an equal list keeps its array, so confirmation re-renders nothing; a changed row re-renders its own row only (tested: one sidebar item of two re-renders). When no provisional list is left, provisional rows the core did not send go.
- **The chat window.** The restored window is asked for again around the saved place's message (`{ around }`), so the core's window contains the message the timeline holds (`restoring` mode); without a saved place (the reader was at the end) with the session's default `unread` anchor, whose window reaches back from the unread boundary to rows the snapshot had. If the reader was at the end and messages arrived meanwhile, they arrive below like live messages, and the list follows them only when it is pinned to the bottom. The unread line comes from the core's window, not the snapshot.
- **Unclaimed restored subscriptions** (a chat window whose pane shows another chat) are released when the core is ready.
- **Drafts.** The composer does not start from a restored draft: the last keystrokes are flushed to the core on `pagehide`, after the snapshot read the store, so the restored draft can be older. `ChatModel.draft` hides a provisional draft row; the composer gets the core's draft through `followDraft` unless the user typed first. The sidebar shows the restored draft meanwhile.
- **Intents in the gap.** Typing is kept: the composer works on provisional state and its `saveDraft` intents queue in the deferred endpoint. Sending: the message row appears in the same frame (overlay, `sending`), the intent queues and reaches the core after `session start`, and the composer clears on `accepted` as always; until then the text stays in the composer and the row shows as sending, so nothing looks frozen and nothing is lost if the core is slow. Read marks and paging requests queue the same way. If the auth store rules the session out, the queue is dropped with the session (nobody is signed in to send as).

`inline.boot.snapshot-reconciled` is marked after the paint following the last provisional list's confirmation.

## Erasing

`eraseBootSnapshot` runs: in the runtime's erase hook on every end of an account (sign-out here, revocation, sign-out in another tab: all take `AppModel`'s one path); when the auth store rules out a provisional session; when the core reports an outdated, erased or unkept replica; when a read finds it unusable; on a refused write. A tab that saves between another tab's sign-out and its own teardown can leave one behind; the next start erases it when the auth store (or the logout tombstone) says signed out, before or right after the first paint.

## Privacy

The snapshot holds message text, names and drafts of what was on screen in plain form in `localStorage`, exactly as the replica holds them in OPFS (`security.md`): readable by script on this origin and by anyone with the device profile, and erased on sign-out with the replica. It never holds the session token or any key (the session start's token is never part of the store's rows or queries), and it holds only the first screens of the sidebar and one chat's window.

## Tests

`bunx vitest run src/app/boot-snapshot` from `web/` (Node, scripted cores, in-memory storage, a manual clock):

- `storage.test.ts`: reading this build's snapshot; damaged JSON, a foreign value, another version, another build, a malformed user, row or list are ignored and removed without throwing; the logout tombstone; blocked and full storage.
- `capture.test.ts`: what is captured and that the token is not; the cut around the saved place and the matching `{ around }` request; the newest rows at the end; the sidebar's first screens; the budget dropping the chat window first, then halving the sidebar, then giving up; a chat window not loaded yet.
- `deferred-endpoint.test.ts`: order, the session substitution, no stand-in forwarded, close.
- `gate.test.ts` (the whole runtime): a tab saves, the next start paints an identical view in the same task with no connector call, and the connector is called only once the auth store confirms, with the provisional state already there; the core's empty first snapshot changes nothing; equal rows keep identity and changed ones re-render alone; the window around the saved place; signed out at hydration tears down at once and erases; another user; a snapshot ruled out up front; one write per hide, within budget; idle saves throttled; no save before ready; erase on sign-out, revocation, another tab's sign-out, outdated, erased and unkept replicas.

Also: `@inline/reactive` (`view-store.test.ts`, "provisional state" and "bounded export") and `@inline/view` (`account-session.provisional.test.ts`: export, restore to an identical view, identity on confirmation, the draft rule, releasing an unclaimed window, a message link not adopting the restored window).

## What to measure in a browser

Production labs build (`tooling/vite.labs.config.ts`, which defines `__INLINE_DEMO__`), served with `vite preview`, Chromium, DevTools CPU throttling 4x for the budget:

1. Open `/?demo=small` (OPFS storage, the default), open a chat, scroll somewhere in it, wait a second, reload. Then reload a few more times.
2. In the console: `__inlineApp.measures`. Compare `inline.boot.snapshot-paint` with `inline.boot.sidebar-rows`, `inline.boot.chat-rows`, `inline.boot.core-ready` and `inline.boot.snapshot-reconciled`. Expected: `snapshot-paint` under 150 ms throttled; `chat-rows` at about the same time (the chat pane's first rows are the snapshot's now); `sidebar-rows` at or before it (that mark follows the first frame after rows exist, even if the shell chunk has not painted yet); `snapshot-reconciled` after `core-ready`. Without a snapshot (first visit, after a deploy, `localStorage.removeItem("inline:boot-snapshot")` before reloading) there is no `snapshot-paint` and the other marks show the cold path to compare with.
3. Watch the reload: no blank sidebar, no blank chat, no jump of the message list when the core answers (scroll position held at the saved place); a chat that was at the bottom stays at the bottom.
4. `JSON.parse(localStorage["inline:boot-snapshot"])`: no token; the size (`localStorage["inline:boot-snapshot"].length`) is in the tens of thousands.
5. Performance panel, one reload: the `getItem` + parse in the entry task, and the `pagehide` handler's cost (capture + `setItem`); the log ring buffer also has "boot snapshot saved" with `chars` and `ms`.
6. Sign out: `localStorage["inline:boot-snapshot"]` is gone. In two tabs, sign out in one: gone, and the other's next start shows sign-in with no shell flash.
7. Delete the IndexedDB session record by hand (Application panel) and reload: the shell may paint for the moment IndexedDB takes, then the sign-in screen, with no notice, and the snapshot gone.

In demo mode `boot.ts` connects the demo account (its link election and core worker) before the first render, to learn the demo user (development path, unchanged), and the auth store is in memory and answers at once; so the demo starts its worker earlier than a real account would and its `snapshot-paint` includes that main-thread work. A real account reads IndexedDB first and connects after.
