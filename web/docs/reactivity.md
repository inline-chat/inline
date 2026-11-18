# Reactivity

The `reactive` package decides what re-renders and when. Read this before writing a view model, binding a view to data, or touching the view store.

## Goals

- A change to one message re-renders one row. A change to list membership re-renders no rows.
- No frame shows mixed revisions.
- First-frame reads are synchronous.
- Nothing here depends on a view framework, except the binding entry.

## Primitives

`signal`, `computed`, `effect`, `batch`, `untracked`, exported from `reactive` under our own names. Callers never import the underlying library.

The first implementation wraps `alien-signals`. Its own exports differ from ours (it has `startBatch` and `endBatch` rather than `batch`, and no `untracked`), which is one reason for the wrapper. A contract test suite pins the behavior we rely on: glitch-free reads, lazy computeds, batching, disposal. Because the API and the tests are ours, the implementation can be swapped. Solid 2's reactive core is published on its own as `@solidjs/signals`; when the app moves to Solid, `reactive` can be pointed at it so there is one reactive graph instead of two.

One difference to plan for: Solid 2 batches writes until the next microtask, and a read does not see the new value until then unless `flush()` is called. Our sync lane promises that a local echo is readable and painted in the same task. The contract tests state that promise, so a future implementation has to meet it (by flushing) rather than change it.

## View store

The UI-thread projection of what the core has published.

- **Rows** are immutable snapshots keyed by kind and ID. A row gets a signal only when something observes it. An unchanged row keeps its identity, so `===` is a valid "did it change" check.
- **Lists** are one signal of ordered IDs per subscribed query. Lists hold IDs, never rows.
- **Resources** hold per-subscription state such as "has older", "at latest", "loading", and the core's phase and connection state.
- `applyPatch` checks the base revision, installs every row, list and resource of the patch inside one `batch`, then notifies. Observers never see half a patch.
- **Overlay.** Optimistic rows the UI predicted for its own intents, keyed by row and by transaction. Reads see the overlay on top of the revisioned state. `applyPatch` drops an overlay entry in the same batch as the patch that confirms or settles it. See "Local echo" in `architecture.md`.
- The store can export and import a snapshot of chosen subscriptions as plain data. The boot snapshot is built on that.

This shape is what makes the first goal hold: a list view observes IDs, each row view observes its own row, and a row update does not touch the list.

## Scheduling

| Lane | Used for | When it runs |
| --- | --- | --- |
| Sync | Local echo of an intent: send, react, mark read, draft | In the same task as the input event |
| Frame | Patches from the core | Coalesced to the start of the next frame |
| Idle | Prefetch, warming, snapshots | When the main thread is idle |

A burst of patches inside one frame is applied as one batch. Work in the idle lane must be interruptible and must yield to input. `requestIdleCallback` and `scheduler.postTask` are not available in every supported browser, so the scheduler carries its own fallback.

## Derived state

Derived state lives in view models as computeds, not in views: timeline items (sender runs, day separators, the unread divider fixed for the visit), sidebar sections, titles, unread totals, "can send". A computed must be pure and cheap to re-run; anything that scans a large list belongs in the core as part of a query.

## Bindings

The binding entry is the only framework-specific part of `reactive`.

- `useSignal(signal)` reads a signal and re-renders the component when it changes.
- `useModel(factory)` creates a view model or controller for the component's lifetime and disposes it on unmount.
- `useElement(controller)` hands a DOM element to a controller and tells it when the element goes away.

In React these sit on `useSyncExternalStore`, ref callbacks and effects. This is the one place effects are written (see `views.md`). In Solid each is a few lines.

Views read signals only through these bindings, never by calling a signal directly during render. The React Compiler cannot see a bare signal read and may memoize around it; a hook read looks like ordinary state to it.

## Boot snapshot

When the page hides, the UI thread saves a small snapshot of the sidebar and the last open window. On the next start it paints from that snapshot synchronously, before the worker, WASM and SQLite are ready, then reconciles with the first patch. The snapshot holds view rows only and is deleted on sign-out.

It has to be readable synchronously at start, which in a browser means `localStorage`; keep it well under the storage limit and treat a missing or unreadable snapshot as normal. The reaction engine provides the export and import; storing it and wiring it into boot is the start-up work in Phase 3.

## Render budget tests

A harness counts renders per component. These must hold, and run in CI:

- A reaction on one message renders exactly one row.
- Typing in the composer renders no timeline component.
- A presence change renders only the components that show presence.
- Appending a message at the bottom renders the new row and nothing above it.

Add a budget test with every list-like or high-frequency surface. A budget that fails is a bug in the data flow, not a number to raise.

## Rules of thumb

- Read signals as late and as narrowly as possible. Pass an ID down and let the row read its own data.
- Do not copy store data into component state or into another signal. Derive it.
- Do not create effects that write signals in response to other signals when a computed would do.
- Every `effect` and every view model has an owner that disposes it. A leaked subscription to a closed chat is a memory bug.
