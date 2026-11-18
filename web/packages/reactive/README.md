# @inline/reactive

Decides what re-renders and when: signal primitives, the scheduling lanes, the view store with its overlay for local echo, the client that connects the store to the core, and the React bindings. Everything except `src/react/` is framework-free. Background: `web/docs/reactivity.md` and `web/docs/architecture.md` ("Core protocol", "Local echo").

## Entry points

| Import | What |
| --- | --- |
| `@inline/reactive` | Primitives, scheduler, view store, store client |
| `@inline/reactive/react` | `useSignal`, `useModel`, `useElement` |
| `@inline/reactive/react/testing` | Render counter and `mount` for render budget tests |
| `@inline/reactive/testing` | Scripted core endpoint and synthetic rows, for tests in other packages |

A Solid binding goes beside the React one as `src/solid/` when Solid 2 is stable.

## Primitives (`src/signals.ts`)

- `signal(value, { equals? })`: `get()` tracks, `peek()` does not, `set(v)`, `update(fn)`. A write of an equal value (`Object.is` by default) notifies nobody.
- `computed(fn, { equals? })`: lazy and cached. With `equals`, an equal recomputation keeps the previous value and its identity. If `fn` throws, every read rethrows until a source changes.
- `effect(fn)`: runs now and on every change; `fn` may return a cleanup. Errors go to `setErrorHandler`'s handler, never into the write that triggered them, and do not stop other effects in the same flush.
- `batch(fn)`, `untracked(fn)`, `isTracking()`.
- `scope(fn)` returns a disposer for every effect and nested scope created inside; `scoped(fn)` also returns `fn`'s value; `onDispose(fn)` runs at the owner's disposal. Cleanups run in reverse order of creation.
- `observedSignal(value)`: a signal with `observed()`, used by the store to release row signals.

The contract is `src/signals.contract.test.ts`. An implementation swap (for example to `@solidjs/signals`) must pass it unchanged.

## Lanes (`src/schedule.ts`)

`createScheduler({ clock, frames?, idleSource?, isHidden? })`; `browserScheduler()` wires the real APIs; `manualTime()` is a deterministic clock, frame source and idle source for tests.

- `sync(fn)`: now, in one batch. Local echo.
- `frame(fn)`: everything queued before the next frame runs in one batch at its start. Uses `requestAnimationFrame` with a 100 ms safety timer; a 16 ms timer while the page is hidden or when the API is missing.
- `idle(task)`: `requestIdleCallback` where it exists, 8 ms timer slices otherwise (Safari). A task returns `true` to yield and be called again; other tasks run between its slices.

## View store (`src/store/view-store.ts`)

`new ViewStore()`:

- `row(kind, id)`, `rowByKey(key)`: a `ReadSignal` of the row as views see it (the overlay's prediction, else the core's row). `peekRow(key)`.
- `list(sub)`: one signal of row keys per subscription; `resource(sub)`.
- `applyPatch(patch)` returns `{ ok: true }` or `{ ok: false, reason: "gap" }`. `replaceAll(snapshot)`.
- `addOverlay(tx, rows)`, `dropOverlay(tx)`, `waitFor(tx)`, `settle(results)`.
- `exportSnapshot(subs, { expand?, select? })` (`select` keeps part of each list before rows are collected), `importSnapshot(data, mapSub?)`: provisional state, below.
- `provisionalSubs` (tracked), `isProvisional(key)`, `dropProvisional()`.
- `sweep()`, `stats()`, `dispose()`.

## Store client (`src/store/client.ts`)

`createStoreClient({ endpoint, scheduler })`:

- `subscribe(query)` allocates a sub ID, posts `subscribe`, and returns `{ sub, list, resource, ensure(range), unsubscribe() }`.
- `intent(intent, optimisticRows?)` allocates a transaction ID (`<random context id>-<n>`), installs the rows in the overlay in the sync lane, then posts the command. It returns a `Promise` of the first `IntentResult`, with `tx` on it.
- `patch` and `snapshot` messages are queued and applied in the frame lane. On a gap it posts one `resync` and drops patches until the snapshot arrives.
- `exportSubscriptions(handles)` and `restore(data)`: subscriptions as plain data with their queries, restored under new sub IDs with `subscribe` posted again.

## React (`src/react/`)

- `useSignal(signal)`: `useSyncExternalStore` with one stable subscribe function per signal; the snapshot is `peek()`, which for rows and lists is the immutable, identity-stable value.
- `useModel(factory, deps?)`: creates the model during the first render inside a `scoped` owner, so effects it creates are disposed with it, and calls its `dispose()` if it has one. Disposal waits one microtask and a remount cancels it, so StrictMode's simulated unmount keeps the same model. Changed `deps` create a new model and dispose the old one after the commit.
- `useElement(controller)`: a stable ref callback; the controller (`{ attach(el) }` or a function) returns a cleanup that runs when the element goes away.
- Testing: `countRender(name)` at the top of a component body; `createRenderCounter()`, `mount(node)`, `update(fn)`. Measure budgets without StrictMode, which renders everything twice.

Rows rendered from a list are wrapped in `memo`. Without it, a list change re-runs every row's body, and the React Compiler does not prevent that: the budget tests fail when `memo` is removed (checked).

## Invariants

1. **A write is readable in the same task.** A signal write, and a local echo installed with `addOverlay` or `intent`, is visible to `get`, `peek` and every computed immediately, inside or outside a batch, with no flush or microtask. Effects run at the end of the write or the outermost batch. (Solid 2's core defers writes to a microtask; an implementation built on it must flush to keep this.)
2. **Glitch-free.** No computed or effect sees a mix of old and new values.
3. **One patch, one batch.** `applyPatch` installs rows, lists, resources and overlay drops in one batch; the frame lane puts every patch of a frame in one batch. Observers never see half a patch.
4. **Gaps are refused.** A patch whose `base` is not the store's revision changes nothing; the client asks for a resync.
5. **Identity means equality.** A row, list or resource that did not change keeps its object, so `===` is a valid "did it change" check. A core row equal to the prediction it confirms takes the prediction's object, so confirmation renders nothing.
6. **Signals only while observed.** A row gets a signal when a tracked read happens (an effect, a computed, a binding). Untracked reads and `peek` never create one. Unobserved row signals are released by `sweep()`, which runs once they double past a floor (1024) and in the idle lane after an unsubscribe. Handles stay valid after a sweep.
7. **The overlay is the UI's own prediction.** Entries are keyed by row and by transaction; a newer prediction for a row replaces the older. An entry is dropped in the same batch as the patch that carries a row with its key (upsert or remove) or lists its transaction in `settled`, whatever the status; a rejection therefore removes it. Overlay rows never change the revision, are never exported, and survive a resync except where the snapshot carries their row.
8. **Overlay rows in lists.** An optimistic row may name subscriptions in `appendTo`. Each such list reads as the core's keys followed by the appended overlay keys that are not already in the core's keys, in the order they were added. When the core's patch arrives with the row in the list, the overlay entry goes and the list is unchanged. This covers "a sent message appears at the end of its chat window"; it does not place a row anywhere else, and it has no tombstones (predicted removal).
9. **Effects have owners.** Every effect in a model is created inside `useModel`'s scope (or another `scope`) and is disposed with it.

10. **Provisional state (the boot snapshot).** `importSnapshot` puts rows in a provisional layer read under the core's rows (and the overlay) and marks the imported lists provisional. A provisional list is replaced only when the core sends that sub's list (a patch, or a snapshot naming it; a splice on it applies to an empty list, which is what the core believes the UI holds); a snapshot that does not name it, such as a context's first, keeps it and its rows. A core row equal to a provisional one takes its object, so confirmation renders nothing. A `remove` drops the provisional row too. When no provisional list is left (confirmed, or its sub dropped), the provisional rows the core did not send go. Exports include provisional rows.

## Known limits

- A computed that was evaluated (for example with `peek`) but never watched stays linked to its sources, and keeps an observed row signal alive, until a source changes. Read derived values through `useSignal` or an effect. Pinned by a contract test.
- A model created by a render that React discards (never commits) is not disposed. Views do not use transitions or Suspense, so this does not arise today.
- An A→B→A write sequence inside one batch may re-run observers once.
- `Snapshot` carries no `settled`, so results in patches dropped during a gap are lost and their waiters wait until the client is disposed. The store already reads `snapshot.settled` if the core adds it.
- The store never removes core rows on its own; the core sends `remove` for rows no subscription needs.

## Tests

`bun run test` runs two Vitest projects: `plain` (everything) and `compiler` (the React tests compiled by the React Compiler as the app compiles views; one test asserts the components really were compiled). React tests use happy-dom via `// @vitest-environment happy-dom`.

The lab page `web/lab-reactive.html` (`web/src/lab/reactive/`) runs 10,000 rows with two loads and reports scripting time per update as `reactive-lab:update` measures.
