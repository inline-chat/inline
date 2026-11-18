# @inline/link

Carries the core protocol (`@inline/core-protocol`) between contexts. A UI context calls `connectCore` and gets a `CoreEndpoint`; link makes it work whether the core runs in this tab's dedicated worker, in another tab that leads, or (later) in an Electron utility process. Depends on `@inline/core-protocol` and `@inline/log` only. No DOM globals at module top level, no view framework.

## Public API

| Export | What |
| --- | --- |
| `connectCore(options)` | Joins the account's election and returns a `LinkedCore`: a `CoreEndpoint` plus `contextId`, `role` and `onRole`. |
| `browserPlatform()` | Web Locks, `BroadcastChannel`, the system clock and page lifecycle, for `connectCore`. |
| `workerCore(createWorker)` | A `StartCore` that runs the core in a dedicated worker. |
| `serveCore(port, createCore)` | The worker side: serves a core on a port. `createCore` returns one `CoreEndpoint` (shared through `multiplexEndpoint`) or a `CoreContexts` that opens contexts itself. |
| `connectCarrier(port)` | The UI side of `serveCore`; returns a `CoreHandle`. |
| `inProcessCore(createCore)` | A `CoreHandle` for a core in the same context (tests; Electron later). |
| `multiplexEndpoint(core)` | Shares one core endpoint between contexts (see "Contexts"). |
| `CoreProxy` | The endpoint a UI holds; survives route changes (see "Proxy"). |
| `watchBrowserSignals(target)` | Sends `online`, `visibility` and `wake` signals; only touches `window`/`document` when called. |
| `PortLike`, `ChannelLike`, `LockManagerLike`, `Clock`, `LifecycleSource` | The platform interfaces. `Worker`, `MessagePort`, `BroadcastChannel` and a worker's global scope fit `PortLike` (type-tested). |
| `linkNames(account)` | Lock and channel names. |
| `@inline/link/testing` | `FakeWorld` (locks, channels, virtual clock, lifecycle, killable tabs), `FakeCore`, `FakeDurable`, `RecordingUi`. |

Browser wiring (the coordinator's, not in this package):

```ts
// core.worker.ts
serveCore(self, () => createCoreHost(...))

// UI
const core = connectCore({
  ...browserPlatform(),
  account: { origin: apiOrigin, userId },
  buildId: BUILD_ID,
  startCore: workerCore(() => new Worker(new URL("./core.worker.ts", import.meta.url), { type: "module" })),
})
const stopSignals = watchBrowserSignals(core)
```

## Roles

`connecting` → `leader` | `follower`; `handoff` while a new core is being chosen; `superseded` and `closed` are terminal.

## Decisions

- **Revisions are per context.** In the app the core host opens contexts itself (`serveCore(self, () => ({ open: () => host.openContext(), close }))`), so the core namespaces subs and numbers each context's revisions, and the multiplexer is not in the path. `serveCore` falls back to `multiplexEndpoint` when the factory returns a single `CoreEndpoint`: it gives each (context, sub) a fresh core sub, routes list and resource changes to the owning context and intent results (in patches and snapshots) to the posting context, and numbers each context's revisions from 0.
- **The fallback sends rows to every context.** A patch does not say which sub a row belongs to (a sidebar's chat and user rows are not list keys), so the multiplexer cannot route rows exactly. It sends every row change to every open context and keeps a mirror of published rows that a late context receives first.
- **The proxy renumbers what it delivers.** The UI sees one contiguous stream across handoffs, and link can insert its own patches (`failed`, `superseded`). Core-side revisions are only used for gap checks.
- **The follower relay runs in the leader window**, not the worker: it keeps the worker a plain `serveCore` and is testable in Node. Moving `LeaderRelay` into the worker is possible (it is DOM-free) if leader main-thread load matters.
- **Liveness is lock state.** No heartbeat. Locks per account: `leader` (election, FIFO), `term/<id>` (held for one leadership; followers wait on it, and its grant means the leader is gone), `context/<id>` (held for a context's life; the leader waits on its followers' and closes a dead follower's context). A follower checks an announced term with `tryAcquire` before following, so a late announcement for an ended term is ignored.
- **Freeze**: a context about to freeze (`freeze`, or `pagehide` into the back-forward cache) leaves the queue, and a leader terminates its core and releases at once; on `resume` it rejoins. A leader frozen without that event keeps its lock and followers wait: that is the accepted gap.
- **Graceful stepdown** (close, version skew) waits up to `shutdownTimeoutMs` for the core to close before releasing the locks, so the next leader does not open storage the old worker still holds. Once a `session signOut` has passed through the context (posted there, or relayed from a follower while it leads) the wait is `signOutShutdownTimeoutMs` (`SIGN_OUT_SHUTDOWN_TIMEOUT_MS`, 30 s), because the core erases the replica during sign-out and a terminated erase leaves files behind (the client's boot sweep removes them at the next start). Freeze and core death terminate at once.
- **Core death**: the leader steps down and runs again after a backoff (500 ms, doubling, max 30 s; reset after 60 s up). A queued follower takes over meanwhile.
- **Start failure is visible.** When `startCore` throws, or the core exits, the proxy delivers `phase: "failed"` with a short user-safe `failure` (`START_FAILURE`, `EXIT_FAILURE`) on every `core` subscription, once per reason, including subscriptions made while failed. The next core that attaches replaces it. Retries continue with backoff.
- **Commands are handled exhaustively.** A new `Command` member is a type error in the proxy and the multiplexer until handled. At run time the proxy forwards an unknown command untouched (never replayed); the multiplexer forwards it only if it names no sub. `trimWindow` is routed like `ensure` but is advisory: dropped while detached, never replayed.

## Message flows

- **Worker.** UI `open(ctx)`, `cmd(ctx, command)`, `close(ctx)`, `shutdown`; worker `msg(ctx, message)`, `down`, `failed(reason)`. One port, ordered.
- **Leader.** Wins `leader`, takes `term/<ctx>.<n>`, starts the core, attaches its own proxy to `core.open(ctx)`, broadcasts `leader{term, build}`. Answers each `hello` with `leader`. Relays `open`/`cmd`/`close` addressed to its term to `core.open(follower)` and sends `msg` back on the channel.
- **Follower.** Broadcasts `hello{build}`, queues for `leader`. On `leader{term}` with the same build: checks the term lock is held, then attaches a `FollowerRoute` (sends `open`), and waits on the term lock.
- **Handoff.** The leader closes, dies or steps down; its term lock frees. Followers' waits are granted: they detach (`handoff`) and say `hello`. The first queued context gets `leader`, starts a core, announces; the others attach. Each proxy replays hello, session, last online/visibility, subscriptions, `resync`, queued `ensure`s and intents not yet reported; withholds patches until the snapshot; delivers the snapshot. The snapshot's `settled` restates the latest result of each intent the core still tracks, so results in withheld patches are not lost.
- **Intent during handoff.** Kept by the proxy until the core reports any result for its `tx`, re-sent on the new route. The core is idempotent by `tx`; the proxy drops repeated or older statuses, so the UI sees `accepted` once.
- **Version skew.** Every `hello` and `leader` carries the build. A context that sees a newer build is superseded: a leader steps down gracefully, every older context leaves the queue, its proxy reports `phase: "superseded"` on each `core` subscription and stops. A newer context that sees an older leader says `hello` again and waits for the lock.
- **Revision gap.** The proxy withholds a patch whose `base` is not the last revision it received, asks for `resync`, and delivers the snapshot. The multiplexer also checks the core's stream and resyncs every context on a gap.
- **Close.** The proxy closes its route; a leader steps down gracefully; the context releases its presence lock, its queue position and its channel.

## Invariants (tested)

- Commands and patches round-trip in order through the worker carrier, structured-cloned (`carrier.test.ts`).
- Two contexts using the same sub IDs stay isolated, each with contiguous revisions (`multiplex.test.ts`, `connect.test.ts`).
- One leader among contexts starting together; a leader that closes or is killed mid-session is replaced, and followers' subscriptions are restored (`connect.test.ts`).
- An intent posted during a handoff reaches the new core once; one committed by a dead leader is applied once and reported once (`connect.test.ts`, `proxy.test.ts`).
- A newer build takes leadership; older leaders and followers report `superseded` and stop (`connect.test.ts`).
- A base mismatch triggers resync; intent results arrive with the snapshot (`proxy.test.ts`).
- A core that cannot start shows `failed` on `core` subscriptions and clears when a start succeeds (`proxy.test.ts`, `connect.test.ts`).
- `trimWindow` is rewritten per context, sent only while attached, never replayed (`multiplex.test.ts`, `proxy.test.ts`).
- A dead follower's context is closed on the core; core death restarts with backoff; freeze steps down (`connect.test.ts`).
- Closing the last context releases every lock, queue entry, channel, timer and core (`connect.test.ts`).

## Browser coverage

Exercised by hand in Chromium by the coordinator, in a dev build and in a production build under Trusted Types, with the app's worker entry (core host opening its own contexts, so the multiplexer is not in the path): one leader, a second tab following, a follower's write appearing in the leader, and takeover when the leader tab closes.

Not exercised in a browser yet, only with the fakes in `@inline/link/testing`:

- Freeze and resume (`freeze`/`resume`, the back-forward cache), and a leader frozen without a `freeze` event.
- Version skew between two real builds.
- Safari (no `freeze` event) and Firefox.
- Measured handoff time, and SAH pool reopen timing after a takeover.
- Worker death after start (`error` event), a tab killed mid-send, and the wake detector under real sleep and background throttling.
- `multiplexEndpoint` with real contexts (it is now a fallback).

The carrier is also tested over a real Node `MessageChannel`.

## Known limits

- Session: each context replays its last `session start` on a new core; the core must treat a repeated start for the same user as a no-op.
- `ensure` posted during a handoff is replayed after resubscription; earlier window extensions are not (the window restarts from its anchor).
