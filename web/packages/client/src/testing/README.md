# Core test harnesses

The fixtures every core test builds on, so nobody writes a private one. They run in Node under Vitest: the real store on in-memory SQLite, the real `RealtimeClient` (connection manager, protocol client, sync engine, outbox) and a scripted server end, under fake time. No sleeps; no mocks of the code under test.

| File | What it is |
| --- | --- |
| `virtual-clock.ts` | Deterministic time: `VirtualClock` (injected) and `useFakeTime()` (global timers), one driving API. |
| `event-loop.ts` | `realTurn()`: one real event-loop turn, for code that does real I/O under fake timers. |
| `scripted-transport.ts` | `ScriptedTransport`: the server end of the client's `Transport`, driven frame by frame. |
| `server-model/` | `ServerModel`: an in-memory Inline server for one account; `ModelServerEndpoint` wires it to a transport. |
| `core-harness.ts` | `CoreHarness`: a whole core against the model, with restart and crash, `heal()` and `snapshot()`. |
| `crashable-disk.ts` | `CrashableDisk`: one SQLite replica shared by successive "processes", with crashes at commit checkpoints. |
| `model-sync/` | Seeded random schedules (`schedule.ts`) and the convergence properties (`compare.ts`). |
| `fault-matrix.ts` | `describeFaultMatrix`: one scenario under every fault of `docs/testing.md`'s matrix. |
| `seed-account.ts` | `generateSeedAccount`: a deterministic, streaming, realistic account at any scale. |
| `rng.ts` | `SeededRandom`, `seedFromEnv`. |
| `faultable-sqlite-store.ts` | (Existing) in-memory SQLite store that fails the next write. |

Example tests, one per harness, read as documentation: `virtual-clock.test.ts`, `scripted-transport.test.ts`, `server-model.test.ts`, `model-sync.test.ts`, `fault-matrix.test.ts`, `seed-account.test.ts`, `known-bugs.test.ts`.

Run them from `web/packages/client`: `bunx vitest run src/testing`.

## Virtual clock

```ts
const time = useFakeTime()          // fakes setTimeout/setInterval/Date; setImmediate stays real
await time.advance(10_000)          // runs due timers in order, flushing promises between them
await time.settle({ progress })     // until `progress()` stops changing (frames, commits)
await time.runUntil(() => cond, { stepMs: 100, maxMs: 60_000 })  // the deterministic waitFor
time.dispose()                      // in afterEach
```

`VirtualClock` has the same driving API plus `now`, `setTimeout`, `clearTimeout`, `nextDeadline`, `runAll` for code that takes a clock as a dependency. It never touches globals.

`settle` also yields real event-loop turns: SQLite WASM loads with real I/O, and fake timers do not control that.

**What would need a clock injected to be deterministic without global fakes.** Today every class below reads the global `setTimeout` or `Date.now`, which is why `useFakeTime` exists. To drive them with an injected `VirtualClock` (the `apple/InlineRealtimeCore` shape), each needs a `clock` option:

- `ConnectionManager`: backoff, auth timeout, background grace and wake-probe timers; default backoff uses `Math.random` past attempt 8.
- `PingPongService`: its sleep loop and ping timestamps.
- `ProtocolClient`: RPC timeouts; message IDs from `Date.now()`.
- `SyncEngine`: retry timers and discovery delays (it takes `now` for dates only).
- `RealtimeClient`: result-settlement retries, message-action answer timeouts, outbox `createdAt`.
- Transaction helpers: `generateTempId` and transaction IDs (`Date.now`, `Math.random`), `SendMessageTransaction`'s send date, `ReservedChatIDPool`.
- `Db`: the unsubscribe clean-up `setTimeout`; `sah-pool-registry` retry sleeps.

## Scripted transport

A fake server end for `Transport`. Every frame crosses a real protobuf encode and decode.

- Connection: `connectPolicy` (`"manual"`, `"accept"`, `"refuse"`), `accept()`, `refuse()`, `disconnect()`, `open()` (accept, wait for `connectionInit`, send `connectionOpen`), `rejectConnection(reason)`, `kill()`.
- Client frames: `sent` (decoded `ClientMessage`s), `rpcs(method?)`, `pendingRpcs()`, `nextRpc()`, `requireRpc(method)`, `dropNextClientFrame(predicate)`, `onClientMessage(listener)`.
- Answers: `ack(call)`, `answer(call, result)`, `fail(call, code)`, `forget(call)`; helpers `answerGetUpdatesState`, `answerGetUpdates(call, page)`, `answerSendMessage(call, { messageId, seq, fromId })`, `pushUpdates(updates)`.
- Faults on server frames: `hold()`, `held()`, `release(order?)` (omit an index to drop it, repeat it to duplicate), `dropHeld(predicate)`, `deliverAfter(ms, frame)`. Frames for a connection that has ended go to `lost`, never to the next connection. Pings are answered at once unless `autoPong` is off.

## Server model

`ServerModel` holds users, thread chats, the account's dialogs, messages, and the user, space and chat buckets with sequences and journals. It answers like `server/src/functions/updates.getUpdates.ts` and `updates.getUpdatesState.ts`:

- pages of at most 100 records; every advanced sequence is an update or a skipped sequence (`IRRELEVANT_TO_BUCKET`);
- `TOO_LONG` past `replayLimit` (10,000) or across a pruned journal (`pruneJournal`, `setBucketHead`);
- chat pages re-read the current message (a deleted one replays as `chatSkipPts`) and carry sidecars: the chat and the dialog with its current unread count;
- discovery pushes `chatHasNewUpdates` / `spaceHasNewUpdates` for buckets changed at or after the date, before its result;
- `sendMessage` is idempotent by random ID; a retry answers with `updateMessageId` only;
- `readMessages` journals a user-bucket `updateReadMaxId` with the count at that moment and answers without a sequence; the sending session gets no push of its own send;
- reactions are realtime only, as on the server.

Events: `postMessage`, `editMessage`, `deleteMessages`, `addReaction`, `removeReaction`, `readOnOtherDevice`, `addSpaceMember`, `removeSpaceMember` (space bucket, with membership generations), `setNotificationMode` (user bucket `dialogNotificationSettings`), `addRawRecord` (a user-bucket `agentSettings` the client keeps raw), `addIrrelevantRecord`. Oracle additions: `spaceMembersThrough(spaceId, seq)`, `spaceMemberUserIds`. Bulk load: `importMessage`, `setReadMaxId`, `setBucketHead`. Oracle: `chatState(chatId)`, `unreadCount`, `bucketSeq`, `journalKinds`, `messagesWithRandomId`, `rpcLog`. RPCs answered: `getMe`, `getUpdatesState`, `getUpdates`, `sendMessage`, `readMessages`, `getChat`, `getChatHistory` (latest), `getChats`, `reserveChatIds`; anything else is `BAD_REQUEST`.

`ModelServerEndpoint(model, transport)` opens a model session on `connectionInit`, acks and answers RPCs, and forwards live pushes. Its `interceptor` decides each outgoing frame's fate (`deliver`, `drop`, `duplicate`, `deliver-then-disconnect`, `drop-and-disconnect`); `beforeRpc` runs when a request reaches the server, before it is answered.

Not modeled yet: direct messages (user peers), spaces' chats and member lists beyond one record kind, attachments, pins, chat creation, permission loss, multiple accounts.

## Core harness

```ts
const harness = CoreHarness.create()      // installs fake time; dispose() restores it
harness.model.addChat({ id: 10n, participants: [2n] })
await harness.boot()                      // Db on SQLite + RealtimeClient + endpoint, signed in
await harness.seedReplicaFromModel()      // rows and cursors written straight in
await harness.runUntil(() => harness.connected())
harness.model.postMessage({ chatId: 10n, fromId: 2n, text: "hi" })
await harness.heal()                      // faults off, fresh connection, outbox drained, sync idle
const replica = await harness.snapshot()  // durable rows read back from SQLite
await harness.dispose()
```

Also: `intercept(fn)`, `settle()`, `settleUntil(promise)`, `crash()` (no clean shutdown), `shutdown()`, `restart({ crash, crashRule })`, `recentLogs()`. Options: a fixed `backoffMs` (deterministic reconnects) and `wrapSyncStorage` (used to plant a bug).

## Crashable disk

`CrashableDisk.openStore({ crashRule })` gives each process a store over one shared in-memory SQLite database. A `CrashRule` names a checkpoint (`after-begin`, `before-commit`, `after-commit`) and a predicate on the write's operations; when it fires the write throws inside the transaction (rolled back, or kept after `COMMIT`) and the process is dead: its later writes fail before `BEGIN`. It uses the same `onWriteCheckpoint` mechanism as `faultable-sqlite-store.ts`.

## Model-based sync test

`model-sync.test.ts` runs fixed seeds (a schedule of 40 steps each, about 20 ms per seed). A step is a server event, a local intent (send, mark read) or a fault (duplicated frames, a reordered burst, a connection lost with its in-flight frames, a lost RPC result, refused reconnects, time passing). Faults follow what a socket can do: a lost frame takes its connection with it; reordering stays inside one instant.

After healing, `compareReplica` checks the properties listed at the top of `model-sync/compare.ts`: the message set and text per chat, reactions, no stuck or duplicated optimistic row, an empty outbox, read boundary, unread count, notification mode, last message, cursors never ahead, space members through the space cursor, unknown records retained, memory matching SQLite.

- `MODEL_SYNC_SEED=<n>` replays one seed; the failure report prints this line, the schedule, the divergences and the last core log events.
- `MODEL_SYNC_SEEDS=<count>` explores new seeds; `MODEL_SYNC_STEPS=<n>` changes the length.
- `MODEL_SYNC_STRICT=1` also fails on divergences labeled as a known bug.
- The planted-bug test (`plantBug: "cursor-ahead-of-projection"`) proves the test can see a divergence.

## Fault matrix

```ts
describeFaultMatrix({ name, setup, act, verify })            // one test per fault
describeFaultMatrix(scenario, { expectedFailures: { "<fault id>": "KB-n" } })
```

`faultMatrix` covers: lost acknowledgement after apply; connection lost before the ack; request lost on a dying connection; every frame duplicated; reordered updates with a sequence gap; offline while sending then online (with a wake); crash before the intent commit, after it, after send, and while committing the result; sign-out with the intent pending. Each case has an expected outcome (`applied-once`, `never-accepted`, `never-sent`), optional `before`/`after` hooks around the intent and an optional `afterVerify` for fault-specific checks on the healed run. A connected core sends an intent in the same turn it commits it, so a hook that counts server RPCs must take its baseline in `before`, not `after`. "Send text" in `fault-matrix.test.ts` is the worked example.

Not yet in the matrix: session revoked by the server, storage full and write errors (use `faultable-sqlite-store.ts`), a replica from a newer schema, leader-tab handoff and two tabs starting at once (browser level).

## Seeded account

```ts
for (const record of generateSeedAccount({ seed, ...SEED_ACCOUNT_SCALES.large })) { … }
seedServerModel(model, { seed, chats: 50, messages: 5_000 })
await writeSeedAccountToStore(store, { seed, ...SEED_ACCOUNT_SCALES.medium }, { batchSize: 2_000 })
```

Scales: `small` (20 chats, 2,000 messages), `medium` (500, 50,000), `large` (3,000, 300,000). Long-tail message counts per chat, short to multi-paragraph texts, Latin, Arabic, Hebrew, CJK and Cyrillic plus emoji, entities, replies, reply threads, photo metadata, outgoing messages and exact unread counts. Streaming: the large account generates in about a second on an M1 with under 20 MB of heap growth; the medium one writes to SQLite in about 0.6 s.

## Known bugs

`known-bugs.test.ts` keeps each core bug the harnesses found as an `it.fails` test with its seed and cause. The model-based test labels those divergences (`knownBug`) so it keeps catching new ones.
