# Demo core

A full, realistic account with no server: the production core (`CoreHost`, `Db` on SQLite, the realtime client, sync engine and outbox, the query materializer) in its own dedicated worker, with only the wire replaced by a simulated server running in that worker. Views, performance tests and browser tests can use it exactly like a real account. Development only: `main.tsx` never imports anything here, and the production build does not include it.

## Files

| File | What |
| --- | --- |
| `connect-demo.ts` | `connectDemoAccount(options)`: the UI side. Same shape as `connectAccount` plus `demo`. |
| `demo.worker.ts` | The worker: `serveCore` with a real `CoreHost` whose `createTransport` returns the world's transport, whose media core keeps its files under the demo's namespace and whose media `fetch` refuses every request (demo files come over the simulated socket), and whose world starts at its scale's activity preset. |
| `control.ts` | `DemoControl`: the control channel's UI side. |
| `opfs-world-store.ts` | Where the simulated server saves its state in OPFS. |
| `../../lab/demo/main.ts`, `/lab-demo.html` | The demo lab page. |

The simulated server lives in the client package's test infrastructure, so Node tests run the same code (`web/packages/client/src/testing/`):

| File | What |
| --- | --- |
| `demo-account.ts` | `createDemoAccount({ seed, scale, anchor })`: the account plan. Structure from `generateSeedAccount`, texts from a corpus it generates, people and membership from `demo-people.ts`, content from `demo-content.ts`; every seeded message a pure function of (seed, chat, message ID). |
| `demo-people.ts` | Users (first and last names in five scripts, usernames, avatar or not), space rosters with roles. |
| `demo-content.ts` | Message content: media specs and their wire encoding (memoized), entities, emoji-only, forwards, edits, bot blocks, buttons and forms, seeded holes; JSON for the saved state. |
| `demo-bytes.ts` | Bytes made on demand: palette PNGs with stored deflate (size known from the dimensions alone), stripped thumbnails (a small JPEG encoder against the clients' fixed header), WAV voice notes, ASCII documents, seeded noise, avatar `data:` URLs. No canvas. |
| `demo-transfers.ts` | `DemoTransfers`: the upload state machine (create, parts, state, finish with processing and failures, cancel) and `GET_FILE_PART` for seeded and uploaded files. |
| `demo-peers.ts` | Direct messages on the wire: user peers in, thread peers inside, user peers out. |
| `demo-lazy-messages.ts` | `DemoLazyMessages`: a chat's messages as a `Map` that produces seeded messages on demand, skipping seeded holes. |
| `demo-server-model.ts` | `DemoServerModel extends ServerModel`: everything the core asks for (list below), content on every message it encodes, save and restore. |
| `demo-world.ts` | `DemoWorld`: model + `ScriptedTransport` + `ModelServerEndpoint`, chunked seeding, the controls, background activity, samples, persistence, housekeeping. |
| `demo-protocol.ts` | The control channel's types, validators, `demoNames`, `parseDemoConfig`, `DEMO_USER_ID`, activity presets. No imports. |
| `demo-core.test.ts`, `demo-server-model.test.ts`, `demo-features.test.ts`, `demo-features-core.test.ts` | Node tests (run with the client suite): the model RPC by RPC, and the real core against the world. `demo-timings.test.ts` measures the scales (opt in with `DEMO_TIMINGS=1`). |

## Using it from a view

```ts
import { connectDemoAccount } from "~/core/demo/connect-demo"

const { core, client, demo, userId, close } = connectDemoAccount({ scale: "large", seed: 1, storage: "opfs" })
// core, client: as from connectAccount(userId). The session is already started.
const sidebar = client.subscribe({ kind: "sidebar", mode: "inbox" })

await demo.send({ kind: "agent", action: "start", chatId: "1004", updatesPerSecond: 60, durationMs: 20_000 })
demo.status.get() // DemoStatus | undefined, a ReadSignal: bind it like any signal
```

Options (all optional): `scale` `"small" | "medium" | "large"` (default `medium`), `seed` (default 1), `storage` `"opfs" | "memory"` (default `opfs`).

- **`opfs`** (default): the replica is a real OPFS SQLite replica under the namespace `demo-<scale>-<seed>-opfs`, and the simulated server saves its own state to `inline-demo/<namespace>.json` in OPFS. Reload, offline, multi-tab and leader takeover behave as in production.
- **`memory`**: an in-memory replica and server; every load starts fresh.

Names never touch a real account: the link origin is `inline-demo://<scale>-<seed>-<storage>` (locks and channels are keyed by it), the replica namespace is the demo's own, and the user is the fixed `DEMO_USER_ID` (`"1"`). Two demos with different scale, seed or storage are independent.

To start over, sign out (`core.post({ kind: "session", action: "signOut" })`, which erases the replica), send `{ kind: "resetServer" }`, and reload. The lab's "Reset this demo" button does exactly that.

## Control channel

A `BroadcastChannel` named `inline-demo/v1/<scale>-<seed>-<storage>/control`, beside the core protocol and never inside it. Any tab of the demo can drive it; the leader tab's worker answers. In the app (`?demo=small`) the control is `globalThis.__inlineDemo`, so every call below runs as written in the page's console or from a browser test: `await __inlineDemo.send({ ... })`. Commands (`DemoCommand` in `demo-protocol.ts`; IDs are decimal strings):

| Command | Effect |
| --- | --- |
| `{ kind: "deliver", chatId?, text?, fromId?, content? }` | One incoming message now. Defaults: a recent inbox chat, a member, a text in the chat's script. `content`: `text`, `photo`, `tallPhoto` (about 1:3.6), `widePhoto` (5:1), `squarePhoto`, `video`, `document`, `voice`, `entities` (one of mention, bold, italic, code, code block, link, text link, email, underline or strikethrough), `mention` (mentions the account), `code` (a code block), `emoji` (emoji only), `rtl` (Arabic, Hebrew or mixed direction), `long` (several paragraphs), `reply` (to the latest message), `forward` (from another chat), `blocks`, `buttons`, `form` (the agent's rich content). |
| `{ kind: "stream", action: "start", ratePerSecond, chatId? }` / `action: "stop"` | Incoming messages at 0.1 to 200 a second, into one chat or spread over the recent ones. |
| `{ kind: "agent", action: "start", chatId?, updatesPerSecond?, durationMs? }` / `action: "stop"` | The agent user posts a message and edits it in place 20 to 60 times a second (default 40) for the duration (default 10 s), growing its text. |
| `{ kind: "typing", chatId?, userId?, ms?, action? }` | A member shows a compose action for `ms` (default 4,000, at most 60,000), refreshed every 3 s as clients do, then stops (`NONE`). `action`: `typing` (default), `uploadingPhoto`, `uploadingDocument`, `uploadingVideo`, `recordingVoice`, `working`, or `stop` to end it now. `detail.userId` names who. |
| `{ kind: "activity", level }` | Background activity: `off`, `low` (someone types somewhere every 12 s or so), `normal` (every 4 s), `busy` (every 2 s, and half of them then send a message, some photos). Presets: small `low`, medium and large `normal` (typing only). Send `off` before measuring. |
| `{ kind: "media", uploadLatencyMs?, downloadLatencyMs?, processingRounds?, failNext?, inlineData? }` | Transfers: delay added to upload results (default 250 ms) and to file parts (default 0), finishes that answer `processing` (1 s) first, the next finishes failing (retryable), and whether a one-part file may finish inside its create call (default off, so every upload shows progress). |
| `{ kind: "actions", failNext?, failureRate?, answerDelayMs? }` | Bot buttons and forms: the next N invocations fail (`INTERNAL_ERROR`), a share fails at random, the bot answers after `answerDelayMs` (default 600). |
| `{ kind: "participants", action: "add" \| "remove", chatId, userId? }` | A member adds someone to a private thread (default: a space member outside it) or removes one (default: a member). |
| `{ kind: "otherDevice", action, chatId }` | The account's other device: `pin`, `unpin`, `archive`, `unarchive`, `markUnread`, `mute`, `mentionsOnly`, `unmute`, `open`, `close`. User-bucket records, as from another session. |
| `{ kind: "otherUser", action: "read" \| "react" \| "edit" \| "delete" \| "pin" \| "unpin", chatId, messageId?, emoji?, text? }` | Another member reacts to or pins (default: the latest message), edits or deletes (default: their latest message), unpins (default: the latest pinned). `read` is the account's other device reading the chat to its end. |
| `{ kind: "network", online }` | Offline: the server drops the connection and refuses new ones. Online: it accepts again, and the core is told to retry now (`wake`). |
| `{ kind: "faults", latencyMs, lossRate }` | Every RPC acknowledgement and result is delayed by `latencyMs` (0 to 30,000) and dropped with probability `lossRate` (0 to 1). Pushes are not affected. |
| `{ kind: "resetServer" }` | Forget the server's saved state; this world saves nothing more. |
| `{ kind: "requestStatus" }` | Broadcast `status` now. |

The world answers every command with `{ kind: "result", id, ok, error?, detail? }` (`detail` names the chat, message or user it created or touched) and broadcasts `{ kind: "status", ... }` after every change, at most four a second while something runs. `DemoControl.send` assigns IDs, holds commands until a worker has reported, and resolves `ok: false` if none answers in 15 s (for example during a leader handoff).

The status also carries `activity`, `typing` (who shows what now), `media` (the transfer settings, `uploadsCompleted`, `partsServed`), `actions`, `ownCompose` (the account's latest compose action as the server saw it) and `samples`: where each kind of content is (`photo`, `tallPhoto`, `widePhoto`, `video`, `document`, `voice`, `entities`, `forward`, `buttons`, `form`, `blocks` as `{ chatId, messageId }`; `directChatId`, `publicThreadId`, `privateThread: { chatId, outsiderUserId }`, and `search: { chatId, query, messageId }`, a word in a message older than the latest page). Samples are computed 1.5 s after seeding.

### A script that exercises every behavior

In the app at `?demo=small` (production labs build), with `d = __inlineDemo` and `s = d.status.get().samples`:

1. Media: open `s.photo.chatId` and scroll to `s.photo.messageId` (blurred preview first, then the image); same for `s.tallPhoto`, `s.widePhoto`, `s.video` (poster; the file does not play, see below), `s.document`, `s.voice` (plays). New ones: `await d.send({ kind: "deliver", chatId: s.photo.chatId, content: "tallPhoto" })`, then `"widePhoto"`, `"video"`, `"document"`, `"voice"`.
2. Uploads: `await d.send({ kind: "media", uploadLatencyMs: 1500, processingRounds: 1 })`, attach a file in the composer and send: the ring advances part by part, waits a second processing, then the row shows the sent photo. `{ kind: "media", failNext: 1 }` then send: the upload fails and offers Resend.
3. Typing: open a chat, `await d.send({ kind: "typing", chatId: <open chat>, ms: 10000 })`; in the sidebar, `await d.send({ kind: "typing", chatId: d.status.get().recentChatIds[2], action: "recordingVoice" })`; `{ kind: "activity", level: "busy" }` for a lively account. Typing in the composer shows in `d.status.get().ownCompose`.
4. People: open `s.directChatId` (a direct message), `s.publicThreadId` and `s.privateThread.chatId` (chat info lists members with roles and usernames); in the private thread, type `@` and the first letters of `s.privateThread.outsiderUserId`'s name for the outside-the-thread rule; add them from chat info, or `await d.send({ kind: "participants", action: "add", chatId: s.privateThread.chatId })`, then `action: "remove"`.
5. Content: open `s.entities`, `s.forward`, `s.buttons` (Approve answers with a toast after 600 ms), `s.form` (submit closes the form); `await d.send({ kind: "actions", failNext: 1 })` and press a button again to see the failure; `deliver` with `content` `"mention"`, `"code"`, `"rtl"`, `"long"`, `"emoji"`, `"reply"`, `"forward"`, `"blocks"`.
6. Dialog actions: pin, archive, mark unread, mute and notification settings from the sidebar menu or chat info; reload: they stay. From the other device: `await d.send({ kind: "otherDevice", action: "archive", chatId: <id> })`, `"pin"`, `"markUnread"`, `"mute"`. Settings change in Settings and survive a reload.
7. Search: find in chat in `s.search.chatId` for `s.search.query`: the server's hits include `s.search.messageId`, older than the loaded window. Quick search over people uses `SEARCH_USERS`.
8. Others: `await d.send({ kind: "otherUser", action: "pin", chatId: <open chat> })` (pinned bar), `"react"`, `"edit"`, `"delete"`, `"read"`.

## Scales and timings

| Scale | Chats | Messages | Plan + seed | First sidebar rows | Latest page of the first chat |
| --- | --- | --- | --- | --- | --- |
| small | 20 | 2,000 | 40 to 55 ms | 95 to 120 ms | under 20 ms |
| medium | 500 | 50,000 | 35 to 45 ms | 125 to 160 ms | under 10 ms |
| large | 3,000 | 300,000 | 70 to 80 ms | 440 to 520 ms | under 15 ms |

On 17 November, with people and content added: planning costs about 10 ms more at every scale (names, memberships, the content of a message is computed only when the message is), and the large account's first sidebar rows about 80 ms more, mostly the bigger `getChats` (1.9 MB: avatars as small `data:` URLs, stripped previews of the latest photos). Making a photo's 800 px size takes about 8 ms, on demand (`mediaMs` in the timings output).

Measured in Node (`DEMO_TIMINGS=1 bunx vitest run src/testing/demo-timings.test.ts` in `web/packages/client`), real time, the real core on in-memory SQLite, a fresh replica, on an M-series Mac. "First sidebar rows" runs from creating the world to the first inbox rows, through the core's real first sync (`getUpdates` on the user bucket, `TOO_LONG`, then the `getChats` snapshot repair). No chat is materialized by any of it; the large account's server holds the plan, not 300,000 messages. Browser numbers (OPFS, worker start, WASM load) are not measured yet; the lab records them in `__demoLab.timings` and as `performance.mark`s (`demo-lab:core-ready`, `demo-lab:sidebar-first-rows`, `demo-lab:window-first-rows`).

Seeding never freezes the worker: the plan is computed in one go (tens of milliseconds), chats are installed 500 per event-loop turn, and no message exists until something reads it. A chat is generated in full only when something iterates it (a sync page's sidecar, for example); the busiest large chat has about 25,000 messages and takes about 16 ms.

After the first sync the core discovers the chats active in the last five days (the real `getUpdatesState` discovery) and repairs each with `getChat` and the latest 50 messages, in the background, four at a time.

## What the simulated server answers

`getMe`, `getUpdatesState`, `getUpdates`, `getChats`, `getChat` (with pinned message IDs), `getChatHistory` (every mode), `getMessages`, `sendMessage` (text, entities, uploaded media), `editMessage`, `deleteMessages`, `addReaction`, `deleteReaction`, `forwardMessages`, `pinMessage`, `readMessages` (with or without a max ID, clearing a mark), `markAsUnread`, `updateDialogArchived`, `updateDialogOrder` (pin and order), `updateDialogOpen`, `showInChatList`, `updateDialogNotificationSettings`, `updateDialogFollowMode`, `getUserSettings`, `updateUserSettings`, `getChatParticipants`, `addChatParticipant`, `removeChatParticipant`, `getSpaces`, `getSpace`, `getSpaceMembers`, `sendComposeAction`, `invokeMessageAction` (buttons and forms), `searchMessages` (words, every filter, count), `searchUsers`, `createUpload`, `saveUploadPart`, `getUploadState`, `finishUpload`, `cancelUpload`, `getFilePart`, `reserveChatIds` and `logOut`. Anything else is `BAD_REQUEST`.

Dialog and settings changes are user-bucket records (`dialogArchived`, `chatOpen`, `markAsUnread`, `dialogNotificationSettings`, `dialogFollowMode`, `updateUserSettings`) answered without a sequence and pushed to the account's other sessions, as the server does; pins and membership are chat-bucket records (`pinnedMessages`, `participantAdd`, `participantDelete`). Reactions and compose actions are realtime only, as on the server.

## What differs from a real server

- **Content.** Seeded threads and direct messages carry photos of six shapes, videos, documents, voice notes, entities, forwards, edits, emoji-only, right-to-left and long texts, replies, and in about one space thread in seven the agent's blocks, buttons and forms. Not modeled: reply threads and subthreads, folders, user groups (group mentions and grants), link previews and external tasks, stickers and GIFs, service messages, chat creation, translation, agent sessions.
- **Media bytes.** Seeded files are made on demand from their file ID and the last eight are kept; photos are palette PNGs (gradients with a disc), documents are text or CSV (the `.zip` is noise), voice notes are 8 kHz WAV. **Video files are seeded noise and do not play**; their posters are real. No message carries a URL: every byte comes over the simulated socket (`GET_FILE_PART`), and the worker's media `fetch` refuses everything, so nothing leaves the worker. Uploaded files keep their bytes in memory only: after a reload a sent file is served from the client's cache, not by the server. Uploaded photos get no stripped preview (the server would make one); a video uploaded without a poster gets a drawn one; a voice note without a waveform gets a seeded one.
- **People.** Space rosters are fixed by the plan except through the controls; the account cannot leave or be removed. Public threads list their space's members as participants. User groups are not modeled.
- **Read state.** The protocol has no read receipts from other people (only acknowledgements, which the web core stores raw); `otherUser` `read` is the account's other device.
- **Drafts** do not sync: the protocol has no draft RPC or update.
- **Sync of chats the replica never synced.** A fresh replica's chat cursors start at 0 and every seeded journal is pruned, so the first event in such a chat repairs it (`getChat` and the latest page) instead of replaying; a membership change that arrives that way is not refetched by the core (the participants list catches up on its next fetch). Open the chat, or wait for one message to arrive, before scripting membership changes.
- **Persistence.** The server saves within a second of a change (the user bucket at once): chats' new and changed messages with their content and reactions, dialog changes, pins, participants, settings. On reload it restores that state and moves every touched chat's sequence and next message ID 10,000 past what it saved, so events from the last unsaved second are never reused: the replica repairs the chat instead. A message the server lost that way stays in the replica but not in windows, which follow the server. Without a saved state (first run, a lost or unreadable file, or one written by an earlier version: the format is versioned, version 2 now, and an older one is ignored) it assumes an unknown past and moves every sequence and ID about a million past anything an earlier session could have reached; the first sync is then a repair, as for a new device. Sequences stay within 32 bits until about 2030.
- **Dates** are anchored when the demo is first created and do not move on reload; seeded activity ends at that moment.
- **Time and order.** Latency applies to acknowledgements and results only, and keeps their order; loss drops them, and the client recovers through its own timeouts (15 s for RPCs).
- **Offline** is the server refusing connections. The browser's own `online` signal still goes to the core as usual.
- **Housekeeping.** Every 5 s the world empties its frame logs and keeps the last 5,000 journal records per bucket; a replica further behind gets `TOO_LONG` and repairs, as with the server's retention.

## Known limits

- The unread-count fixes to sync and update handling (core-hardening) change what reconnects show; until they land, unread counts after a reconnect may differ from the server's.
- The demo server reaches `ServerModel`'s private `journal` and `broadcast` through a checked cast (it fails loudly at construction if they are renamed); they should become `protected`.
- The lab page and the worker are not run in a browser by any test yet.
