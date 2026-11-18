# Architecture

How the web and desktop client is put together: the layers, what each module owns, and the contract between the UI and the account core. Read this before adding a module or moving code between modules.

One TypeScript codebase under `web/` produces three things:

| Surface | What | Runtime |
| --- | --- | --- |
| App | The signed-in client at `app.inline.chat` | Client-only single-page app |
| Desktop | Windows and Linux apps, and an optional Mac build | The same bundle inside Electron |
| Public pages | Shared threads and public spaces on `inline.chat` | Server-rendered, sharing the message rendering module |

## Layers

```
app            web/src            boot, region views, wiring, service worker
ui, chat-ui    packages           UI kit; message rendering              views are framework-bound
view           package            view models, navigation, commands      framework-free
reactive       package            signals, view store, bindings          framework-free core
platform       package            capability interface; web and Electron implementations
link           package            carries the core protocol between contexts
core           package            transport, sync, store, outbox, queries, media   no DOM
core-protocol, protocol, ids, log, config        shared leaf packages; plain data and helpers
```

`core-protocol` is a leaf: plain types and pure helpers that both the core and the UI import. It is how the two sides agree without importing each other.

The dependency rules:

1. Imports point down only. `link` is the one place that knows both sides: its worker entry starts the core, and its client proxy is what the UI holds.
2. `core` never imports the DOM or a view framework. It runs in a worker, and unchanged in Node tests.
3. The UI thread never imports `core` internals or the protobuf runtime. It sees `core-protocol` types only.
4. Plain `.ts` files are framework-free. A view framework is imported only by view files (`.tsx`) and by the binding entry of `reactive`.

Rules 2 and 3 are what let the core move between a worker, a leader tab and an Electron window without the UI noticing. Rule 4 is what keeps the view framework replaceable (see `views.md`).

Enforcement today: lint enforces rule 4 (`.oxlintrc.json`). Rules 2 and 3 are not yet mechanical: every package still compiles with the DOM library, and `tsconfig.json` allows deep imports into the client package. The work that builds the core host adds the checks: a worker-only TypeScript configuration for the core, package `exports` that hide internals, and import restrictions that keep the client package, the protobuf runtime and SQLite out of UI code.

## Modules

| Module | Owns | Does not own |
| --- | --- | --- |
| `core` (today `packages/client`) | Connection and session, transports, sync, SQLite store and migrations, outbox, update handling, query materialization, media transfers and cache, local search, retention, and the host object that owns one account's store and connection | Anything visual; anything that needs a window |
| `core-protocol` | The message contract: command and query descriptors, patch format, view row types | Behavior |
| `link` | The worker entry that starts a core host, leader election, the follower channel, the Electron carrier, the UI-side client proxy, resync | Data semantics; the host's lifecycle logic |
| `reactive` | Signal primitives, batching and scheduling, the view store (rows, lists, resources), framework bindings | Domain logic |
| `view` | View models and controllers: timeline, composer model, sidebar, workspace and navigation, command registry and keyboard, selection, media viewer, search, sign-in | Rendering |
| `ui` | The UI kit: tokens, themes, headless controllers, views, the UI lab | Chat concepts |
| `chat-ui` | Message rendering: a framework-free render model (entity runs, link safety, block layout) and views over it. Used by the app and by public pages | Store access |
| `platform` | One capability interface with web and Electron implementations: notifications, badge, window chrome, file save, external links, updater, tray, deep links | UI |
| `web/src` | Boot, region views, wiring view models to views, service worker | Logic |
| `web/desktop` | Electron main and preload | App code |

Each module is a package under `web/packages`, with a `README.md` stating its public API and invariants. Two parts of `view` are packages of their own for now, because they are large and were built separately: `composer` (the editor model and its DOM binding) and `timeline` (the message list controller). They follow the same rules as `view`: framework-free, tested in Node.

Put a new piece of code in the lowest layer that can own it. If a view needs data, add a query. If a view model needs behavior from the core, add a command. Do not reach across a layer to save time.

### Adding a package

- Directory `web/packages/<name>`, package name `@inline/<name>`, `"private": true`, `"type": "module"`.
- A `package.json` with `exports` that name the public entry points only, and a `test` script. `bun run test:packages` runs every package under `web/packages` that has one.
- A path entry in `web/tsconfig.json`, next to the existing ones.
- A `README.md` with the public API and the invariants.
- Tests sit beside the code as `*.test.ts`. Browser, end-to-end and performance suites live in `web/tests`.

## Data flow

```
input event ─▶ view model ─▶ intent ─▶ link ─▶ core: commit intent + optimistic rows (SQLite) ─▶ send
                   ▲                                         │
                   │                                         ▼
      views ◀─ signals ◀─ view store ◀─ patch ◀─ link ◀─ query materializer (diff)
```

- The core is the only writer of durable state. The UI holds a read-only projection of the queries it subscribed to.
- An intent is committed with its optimistic rows before any request is sent.
- Updates from the server commit to SQLite first and are published after.
- The patch stream is the only way the core's data reaches the UI.

### Local echo

A round trip to the worker can take longer than a frame, and a sent message must paint in the frame of the keypress. So the UI keeps a small overlay of its own:

- The UI creates the intent's transaction ID and the row's client key, builds the optimistic row with a pure function from `core-protocol` (the core uses the same function, so both sides produce the same row), and installs it in the view store's overlay in the sync lane.
- Overlay rows sit beside the revisioned state, not in it. They do not change the revision and are not part of resync.
- When a patch arrives that carries a row with the same key, or lists the transaction in `settled`, the overlay entry is dropped in the same batch. The row keeps its identity, so nothing flickers.
- If the core rejects the intent before committing it (storage full, for example), `settled` says so and the overlay entry is removed and the composer keeps its text.

The overlay is the UI's own prediction, never a second channel from the core. This is the starting design; the packages that build the core host and the reaction engine finalize it together.

## Core protocol

The one contract between a UI context and the core. Everything on it is structured-cloneable plain data. This is the starting shape; the package that builds the core host finalizes it.

```ts
// UI to core
type Command =
  | { kind: "subscribe"; sub: number; query: QueryDescriptor }
  | { kind: "unsubscribe"; sub: number }
  | { kind: "intent"; tx: string; intent: Intent }      // send, edit, react, markRead, saveDraft, ...
  | { kind: "ensure"; sub: number; range: "older" | "newer" | "latest" | { around: MessageId } }
  | { kind: "resync" }

// core to UI
type Patch = {
  base: number                  // revision this patch applies to
  revision: number
  rows: RowChange[]             // upsert or remove, keyed by kind and id
  lists: ListChange[]           // replace or splice, keyed by sub
  resources: ResourceChange[]   // per-sub window state
  settled: IntentResult[]       // durably accepted, rejected, by tx
}
```

- Queries are named and typed, for example `sidebar(scope, mode)`, `chatWindow(chatId, anchor)`, `thread(messageId)`, `members(chatId)`, `user(id)`, `search(text)`. The core materializes each one, diffs it and sends row upserts and list operations. The UI cannot send arbitrary SQL.
- Row types (`MessageRow`, `ChatRow`, `UserRow` and so on) are shaped for views and defined in `core-protocol`. They carry branded ID strings from `ids`, never protobuf classes.
- Every patch names its base revision. On a gap the UI asks for a resync and the view store is replaced by a snapshot.
- Core phase and connection state travel on the same channel as a resource, so views render them like any other data.
- The UI and the core always come from the same build, so the protocol has no compatibility matrix. Contexts compare build IDs when they connect; the newest build leads and older ones reload. The build ID is a constant injected at build time (build time plus commit), so it orders builds.

## Running in more than one context

- **Tabs.** Every tab runs the UI. One tab's dedicated worker is the leader, chosen with a Web Lock; it holds SQLite and the socket. Other tabs are followers and speak the same protocol to the leader. When the leader goes away a follower takes over and the others resubscribe. Intents are idempotent, so a command lost in a handoff is retried safely.
- **Version skew.** The newest build leads. Older tabs show "Inline was updated" and reload.
- **Electron.** One long-lived context is the permanent leader and every visible window is a follower. There is no second code path (see `desktop.md`).
- **Accounts.** Locks, storage directories, database files and channels are keyed by server origin and user ID so more than one account can run and one account's failure cannot touch another's files. The first UI shows one account at a time.

## Public pages

- Server-rendered from a public read API and cached at the CDN.
- They import `chat-ui` and `ui` only. They never load the core, SQLite or the worker.
- Signed-in members get "Open in Inline", which hands off to the app at the same destination.

## Related guides

- `core.md`: sync engine invariants, storage, queries, how to add an intent.
- `reactivity.md`: what re-renders and when.
- `views.md`: view layer rules and the UI kit.
- `timeline-and-composer.md`: the two hardest surfaces.
- `performance.md`, `testing.md`, `security.md`, `desktop.md`.
- `decisions.md`: what is fixed, what is a default, and how to change a default.
