# Instructions for web

## Scope

- `web/` is the Inline web app, served on its own origin (`app.inline.chat`). The same bundle ships in Electron for Windows and Linux, and later as an optional Mac build.
- `web/src` is the app shell. `web/packages/client` is the account core: SQLite store, sync, outbox and realtime client. `auth`, `ids`, `log` and `config` are small shared packages; `landing/` also uses `config`.
- It uses Vite and StyleX. Views are React with the React Compiler for now. Solid 2 is the intended view framework once it has a stable release.
- The bar is the native Mac app: instant from local data, complete from the keyboard, correct under bad networks and crashes. Compare against it for anything a user can feel.

## Start here

1. The maintainers' planning notes, in the private `secret-sauce` repository checked out beside this one: `../../secret-sauce/.context/2026-11-16-inline-web-program/README.md` (path from `web/`). They say what to build next, what done means, what you may decide yourself, and where to record work. Without access to them, the guides below still stand on their own.
2. The guides in `docs/`. Read the ones your work touches before you start:

| Guide | Read before |
| --- | --- |
| `docs/architecture.md` | Adding a module, moving code between modules, changing the UI-to-core contract |
| `docs/core.md` | Touching sync, storage, the outbox, or adding data or an action |
| `docs/reactivity.md` | Writing a view model or binding a view to data |
| `docs/views.md` | Writing a `.tsx` file or a UI primitive |
| `docs/timeline-and-composer.md` | Touching the message list, the message input or media in messages |
| `docs/performance.md` | Anything a user can feel |
| `docs/testing.md` | Starting any work package |
| `docs/security.md` | Adding a dependency, rendering user content, handling links, changing headers |
| `docs/desktop.md` | Working on the Electron shell or the `platform` interface |
| `docs/decisions.md` | Wanting to do something differently from the guides |

## Hard rules

- **Layers.** Imports point down. The core never imports the DOM or a view framework. UI code never imports the core's internals, the protobuf runtime or SQLite; it talks to the core through commands and query results. Plain `.ts` files are framework-free.
- **Views.** No `useEffect` or its variants, no `Suspense`, and no heavy use of context or component state. Logic and state that matters live in view models and controllers. No React-bound router, data or state library. Details and the reasons are in `docs/views.md`.
- **Core invariants.** The numbered invariants in `docs/core.md` are tests. Do not land a change that breaks one.
- **First frame from local data.** A spinner or empty flash for data that is on the device is a bug. Rows are pure. A draft or intent is dropped only after its durable commit.
- **Security.** Production runs under a strict CSP with Trusted Types (`vite.config.ts`). No inline scripts, no third-party scripts, no raw HTML sinks. Do not weaken the policy.
- **Styling.** StyleX only, with tokens from `*.stylex.ts` files.
- **Dependencies.** A new runtime dependency needs a recorded reason and size in `docs/decisions.md`.
- **Tests.** The client package's tests are its specification. Keep them passing and extend them with the behavior you change. A bug fix starts with a failing test.
- **Sign-off.** Server, wire protocol and schema changes are called out before commit, as the root `AGENTS.md` says. That includes the web replica's own SQLite schema.

## Room to decide

The guides say what must be true. How you get there is yours. `docs/decisions.md` marks each decision as fixed or as a default; a default can be changed with a recorded reason. If you are blocked, pick the option that is easiest to reverse and keeps the layers, record it, and keep going.

## Checks

From `web/`: `bun run typecheck` (covers the packages), `bun run lint`, `bun run test`, `bun run test:packages`, `bun run build`. `bun run dev` serves on port 8001, which the API's CORS allow-list includes.

Verify UI work in a browser before calling it done: light and dark, keyboard only, and a narrow window. Measure with a production build.

Supported browsers are the `browserslist` entry in `package.json`.
