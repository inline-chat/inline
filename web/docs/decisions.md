# Decisions

What has been decided for the web and desktop client, why, and how firm each decision is. Read this when you want to do something differently from the guides.

- **Fixed** decisions come from the project owner or protect something that is expensive to get wrong. Do not change them. If you think one is wrong, write the case and ask.
- **Default** decisions are the best current answer. Change one when you have a reason: update the row, add a line to the change log at the bottom, and carry on. Asking first is not required.

Facts about libraries and browsers here were checked in November 2026. Re-check before relying on one.

## Product and scope

| Decision | Status | Why |
| --- | --- | --- |
| One codebase for the web app, the Electron app and public pages | Fixed | One client to make excellent instead of three |
| The app lives on `app.inline.chat`; public pages on `inline.chat` | Fixed | Keeps session keys on an origin with no other content |
| Electron for Windows and Linux first; an optional Mac build after | Default | Those platforms have no native client |
| We own the core: store, sync, outbox, networking | Fixed | It is where reliability and speed come from, and it must be tunable |
| We own the UI kit; no third-party component kit | Fixed | Desktop-grade behavior and a framework-neutral base |
| We own the composer and the timeline | Fixed | The two surfaces users judge the app by |
| The native Mac app is the behavioral reference | Fixed | It already encodes the product's rules |
| Strings are English; no translation framework yet | Default | Not needed for launch; right-to-left content already works |
| A phone-first layout is not a gate | Default | The single-pane layout must be usable, no more |

## Architecture

| Decision | Status | Why | What would change it |
| --- | --- | --- | --- |
| The layer rules in `architecture.md` | Fixed | They are what makes the core portable and the view framework replaceable | |
| The core is TypeScript, not Rust compiled to WASM | Default | The TypeScript core exists and is tested; the Swift engine is the semantic reference, not shared code | A measured hot path that TypeScript cannot fix |
| The core runs in a dedicated worker; the UI sees commands and patches only | Fixed | Keeps the main thread for input and paint | |
| Named queries materialized by the core; no arbitrary SQL from the UI | Default | Bounded, testable, cheap to diff | A real need for ad hoc queries |
| Any number of tabs, one leader chosen by a Web Lock | Default | One writer and one socket per account | If following proves too costly, ship one active tab with takeover first and record it |
| No Effect in the web client | Default | Keeps the core small and its control flow explicit | A part that clearly benefits, such as the media scheduler |
| Our own navigation; no router library | Default | Panes and windows need custom navigation, and a framework-bound router blocks the move to Solid. This reverses an earlier choice of TanStack Router | If our own navigation costs more than a few hundred lines to keep correct |

## Storage and transport

| Decision | Status | Why | What would change it |
| --- | --- | --- | --- |
| SQLite WASM on the OPFS SAH-pool VFS | Default | Fastest VFS, needs no cross-origin isolation headers, single connection matches one writer | A requirement for independent connections; then measure the Web Locks VFS |
| Forward-only migrations; never reset a replica | Fixed | A replica can hold unsent work | |
| IndexedDB only for the session record | Default | Tiny, and needed before SQLite opens | |
| The boot snapshot is kept in `localStorage` | Default | It must be readable synchronously before anything else loads | Size limits, or a faster synchronous source |
| V3 secure transport is the target, V2 the fallback | Default | Matches the native clients | |
| In Electron, the same WASM SQLite in a hidden window | Default | One code path | The spike in `desktop.md` failing; then native SQLite in a utility process |

## Views and UI

| Decision | Status | Why | What would change it |
| --- | --- | --- | --- |
| Solid 2 is the target view framework; React is interim | Fixed | Owner's preference. Solid 2 had no stable release when this was written (`latest` was 1.9; 2.0 was a release candidate) | |
| In React views: no effects, no Suspense, no heavy context or component state | Fixed | Owner's rule. Keeps the React layer thin and the port cheap | |
| No React-bound router, data or state library | Fixed | Same reason | |
| The stricter habits in `views.md` (portable JSX, per-region mounts) | Default | A direction, not a rule | |
| React Compiler on | Default | Removes hand-written memoization | Build instability; turn it off rather than work around it |
| StyleX for styling | Fixed | Owner's choice; compiles to static CSS, works under the content policy, ports to Solid | |
| Signals through our own API, first implemented on `alien-signals` | Default | Small, fast, stable release. Solid's own reactive core is published separately and is the natural base once Solid 2 is stable | Contract tests exposing a problem, or the move to Solid |
| Top layer, `<dialog>` and the Popover API for layering; our own positioning function | Default | CSS anchor positioning is newer than the browser floor | Raising the floor |
| A bounded window of real rows for long lists; no virtualizer library | Default | Selection, find in page and variable heights work natively; one scroll owner | Measured failure to meet the scroll budget |
| One `contenteditable` composer with a model; no editor library | Default | We own input behavior; EditContext is not available in every engine | |

## Platform and tooling

| Decision | Status | Why |
| --- | --- | --- |
| Browser floor: Chrome and Edge 123, Firefox 128, Safari 17.5 | Default | Covers OPFS, Popover, `light-dark()`; revisit at launch |
| Features missing in some supported engines need a fallback: `requestIdleCallback`, `scheduler.postTask` and `yield`, native scroll anchoring, EditContext, the Long Animation Frames API | Default | They are absent in Safari or Firefox at the floor |
| Vite, Vitest, Playwright, oxlint | Default | Already in use in the repository |
| electron-builder with `electron-updater` | Default | Self-updating Linux packages; see `desktop.md` |
| Remote telemetry off; local logs and a redacted diagnostics export | Default | Until the owner decides otherwise |
| Static hosting on Cloudflare; hashed assets immutable; `index.html` and the service worker never cached | Default | |
| A service worker precaches the shell; a new version waits and the app offers to reload | Default | Code is never swapped under a running session |

## Runtime dependencies

Every runtime dependency of the app is listed here with its reason. Add a row before adding a dependency.

| Package | Used by | Reason | Size (gzip) |
| --- | --- | --- | --- |
| `react`, `react-dom` | views | Interim view framework | in the 69 KB shell |
| `@stylexjs/stylex` | views | Styling runtime (small; most work is at build time) | in the shell |
| `@sqlite.org/sqlite-wasm` (3.54.1 or later: it needs `preserveOnInitFailure`) | core | Storage | about 400 KB WASM, loaded in the worker |
| `@protobuf-ts/runtime` | core, through `@inline-chat/protocol` | Wire format | worker only |
| `@msgpack/msgpack` | core | Row encoding in the replica | worker only |
| `@noble/hashes`, `@noble/ciphers` | core, through `@inline-chat/protocol` | V3 transport crypto | worker only |
| `alien-signals` | reactive | Signals implementation | about 1 KB |

State the dependency rule here only; other guides point to this table.

## Open questions

These are waiting on the project owner and are tracked outside this repository: the public sharing model (what can be shared, by whom, indexing defaults), Windows code signing, and whether to add remote error reporting.

## Change log

Newest first. One line each: date, what changed, why.

- 2026-11-17: Initial JavaScript budget reworded after the first canonical measurement (`bun run size`): 200 kB gzip on the target view framework, 235 kB while views are React (React and ReactDOM are about 67 kB of it), 160 kB signed out. The earlier single figure of 200 could not be met on React without deferring code the first frame needs. Measured 245.8 kB signed in on that day.
- 2026-11-17: Sign-out erases first. The core marks the account's storage, erases it and only then reports `signedOut`; the server logout is sent and never waited for; the page keeps the connection open until that report (bounded); an interrupted erase is finished before that storage is opened again; a sweep at boot removes storage no signed-in account owns.
- 2026-11-17: A V3 revocation that arrives as a plain WebSocket close no longer erases local data on the web (the frame is outside V3's cryptography). Stricter than the Apple client; an authenticated revocation notice is a wire decision for the owner.
- 2026-11-17: A jump to a row taller than the uncovered viewport puts the row's top at the top instead of centering it.
- 2026-11-17: The composer's own clipboard format is honored only when this document wrote that exact payload; a web page could otherwise plant a mention pointing at any user.
- 2026-11-17: Every package under `web/packages` except `client` declares `"sideEffects": false`. Without it, anything reachable through a package's index landed in the initial chunks even when only a deferred chunk used it; the initial JavaScript went from 249 KB to 206 KB gzip. A module in those packages must not rely on being imported for an effect.
- 2026-11-17: Content policy: `trusted-types default` became `trusted-types inline-script-url`, one named policy that returns same-origin script URLs only, used for the core worker and the service worker. No default policy.
- 2026-11-17: The web replica's SQLite schema went from version 2 to 5: history coverage (3), models for members, participants, user groups, folders and user settings (4), the message search index (5). Client-side only; forward migrations.
- 2026-11-17: The appearance pre-paint script is a small same-origin classic script in `<head>` (`appearance-boot.js`), because the content policy forbids inline scripts.
- 2026-11-17: The boot snapshot is discarded when the build changes (row shapes change between builds without a version bump): one cold start per deploy.
- 2026-11-17: SQLite WASM raised to 3.54.1; one storage pool per account, installed so that a failed installation keeps the files and can be retried. The earlier setup could delete every account's replica during a tab takeover.
- 2026-11-17: `composer` and `timeline` are their own packages instead of directories inside `view`. They were built in parallel; fold them in later only if it helps.
- 2026-11-16: React view rules loosened from "JSX and prop reads only" to three bans (effects, Suspense, heavy context or state). Owner's request.
- 2026-11-16: Solid 2 set as the target view framework; React interim. Owner's preference.
- 2026-11-16: TanStack Router removed in favor of our own navigation. Framework-bound, and panes need custom navigation.
- 2026-11-16: Base UI dropped in favor of our own UI kit. Owner wants our own UI module.
- 2026-11-16: IndexedDB replica store removed; SQLite is the only persistence.
