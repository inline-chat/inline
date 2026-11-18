# Testing

What gets tested at which level, and the harnesses to use. Read this before starting a work package; each package's "done" includes tests at the level this guide assigns.

The architecture is shaped so that most behavior can be tested without a browser and without a view framework. Use that. A bug in sync, ordering, navigation or keyboard handling should be reproducible in a Node test in milliseconds.

## Levels

| Level | What it covers | Tool |
| --- | --- | --- |
| Unit | State machines, codecs, render models, view models, navigation, UI controllers, signal contracts | Vitest in Node, virtual clock |
| Core integration | The real core over in-memory SQLite and a scripted transport, with the fault matrix below | Vitest in Node |
| Model-based sync | Random delivery orders, duplicates and drops against a small in-memory server model; the replica must converge to the model | Vitest, seeded |
| Render budgets | Render counts per interaction (see `reactivity.md`) | Vitest with the counting harness |
| Components | Focus, keyboard, ARIA and layering of UI primitives in a real browser | Vitest browser mode |
| Browser end to end | Sign-in, send, reload, offline, multi-tab handoff, upgrade with old tabs open, against a local server with seeded data | Playwright on Chromium, WebKit and Firefox |
| Performance | The budgets in `performance.md`, with traces kept | Playwright with CPU throttling |
| Visual | UI lab screenshots: light and dark, left-to-right and right-to-left | Playwright |
| Desktop | Launch, deep link, notification, update check | Playwright for Electron |

Everything above "Render budgets" runs without a view framework. Render budgets count renders of real components, so they are written per framework. The browser levels drive the DOM, so they keep working when the view framework changes.

## Principles

- **Test the mechanism, not a mock of it.** Core tests run the real store on in-memory SQLite and the real sync code against a scripted transport. Do not mock the thing under test.
- **Deterministic time.** State machines take a clock. Tests use a virtual clock; no test sleeps.
- **Seeded randomness.** A model-based or fuzz test prints its seed on failure and can be re-run from it.
- **Invariants are tests.** Each numbered invariant in `core.md` has at least one test named after it.
- **A bug fix starts with a failing test** at the lowest level that can show it.
- **The client package's tests are its specification.** Keep them green and extend them with the behavior you change.
- **Injected platform functions hide a class of bug.** A default such as `options.defer ?? queueMicrotask`, stored on an object and called as a method, runs the platform function with the wrong `this`. Node and the test DOM accept that; browsers throw "Illegal invocation". Tests that inject their own function never see it. Wrap the default (`(fn) => queueMicrotask(fn)`), and the same for `setTimeout`, `requestAnimationFrame`, `fetch` and `matchMedia`. This crashed the page once when media rows unmounted, and only a lab in a real browser caught it.

## Fault matrix for the core

Every durable path is run against these, alone and in combination where it makes sense:

- The acknowledgement is lost after the server applied the request.
- The same update arrives twice; updates arrive out of order; a sequence gap appears.
- The process dies at each commit checkpoint: before the intent commit, after it and before send, after send and before the acknowledgement, during an update batch.
- The connection drops mid-request and comes back; the device sleeps and wakes.
- The session is revoked; the user signs out with intents pending.
- Storage fails: quota exceeded, a write error, a replica from a newer schema.
- The leader tab closes mid-send; two tabs start at once.

The fault-injecting SQLite store in `packages/client/src/testing` covers the storage checkpoints. Extend it rather than adding a second mechanism.

## Fixtures

- **Scripted transport.** A fake server end that a test drives step by step: deliver, delay, drop, duplicate, disconnect.
- **Server model.** A small in-memory model of chats, messages and buckets that produces valid updates and answers sync requests. It is the oracle for model-based tests.
- **Seeded account.** A generator for a realistic account: thousands of chats, hundreds of thousands of messages, long threads, media, mixed scripts including right-to-left. Performance and end-to-end tests use it.

## Browsers

- Chromium is the primary engine for end-to-end and performance runs.
- Playwright's WebKit is not Safari. Storage, OPFS and service worker behavior must also be checked in real Safari before a release claims Safari support.
- Firefox runs the end-to-end suite; it is the engine most likely to differ on Trusted Types and editing behavior.

## What a UI change needs

- Unit tests for the controller or view model.
- A UI lab entry, which gives it a visual test.
- A component test when it has focus or keyboard behavior.
- A render budget test when it is a list or updates often.
- An end-to-end test when it is a user journey that must not break: sign-in, send, reload, offline.

## Running

From `web/`: `bun run typecheck`, `bun run lint`, `bun run test`, `bun run test:packages`, `bun run build`. Browser and performance suites are added by the test infrastructure package and documented here when they exist.
