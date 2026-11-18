# Performance

The budgets the app is held to, the rules that make them reachable, and how to measure. Read this before working on anything a user can feel: start-up, chat switching, the timeline, the composer, the sidebar.

Performance is a feature here, on the same footing as correctness. A change that breaks a budget is not done.

## Budgets

Reference machines: an M-series MacBook, and Chromium with 4x CPU throttling as the stand-in for a mid-range Windows laptop. Budgets are checked on the throttled profile. They are starting targets; the first measurement of each one is recorded and the number is then tightened or corrected with a note in `decisions.md`.

| Moment | Budget |
| --- | --- |
| Warm start, first paint of sidebar and last chat | 150 ms (from the boot snapshot) |
| Warm start, core live and interactive | 500 ms |
| Switch to a chat already in memory | Painted in the next frame |
| Switch to a chat that is only in SQLite | 100 ms from input to paint, no spinner |
| Send | Row painted within one frame of the keypress |
| Typing | No keystroke waits on store work; zero timeline renders |
| Incoming message at the bottom | Painted within one frame of the patch |
| Streaming message, 20 to 60 updates a second | Only that row's block updates; under 4 ms of scripting per update |
| Scroll and history paging | No frame over 32 ms; no visible anchor drift on prepend, resize and media load: under 1 px, and none that accumulates over repeated operations |
| Leader tab handoff | 1 s, with no lost or duplicated send |
| Memory | JS heap under 250 MB after a working day; DOM under about 15,000 nodes |
| Initial UI JavaScript (signed in, `bun run size`) | 200 kB gzip on the target view framework; 235 kB while views are React, of which React and ReactDOM are about 67 kB. Signed out: 160 kB. The worker and WASM load in parallel and are not counted |

## First measurements

From `web/lab-perf.html` (the real app in a production build, driven through scripted journeys against the demo core) on 17 November 2026. Chromium 156, an M-series laptop **without CPU throttling**, a small seeded account, a simulated server. These are a baseline, not the budget check: rerun with `?scale=large&cpu=4` and devtools CPU throttling at 4x before trusting a pass.

| Moment | Measured (median) | Budget | Result |
| --- | --- | --- | --- |
| Warm start, first paint from the boot snapshot | 54 ms | 150 ms | pass |
| Warm start, core ready | 137 ms | 500 ms | pass |
| Switch to a chat in memory | next frame | next frame | pass |
| Switch to a chat only in SQLite | 45 ms, worst 80 ms | 100 ms | inconclusive (the list was hidden while loading once in six) |
| Send | next frame; 1.5 ms from keydown to the row in the DOM | one frame | pass |
| Typing | no long task; no change under the timeline | none | pass |
| Incoming message at the bottom | 3 frames from the simulated server's acknowledgement | 1 frame from the patch | fail as measured; the UI side has no stage that waits a frame, so the remainder is the worker's commit and the wait for the next frame. Needs the `inline.patch.apply` mark to measure from the patch |
| Streaming at 20 to 60 updates a second | 0.3 to 0.5 ms per update | 4 ms | pass |
| Scroll and history paging | 13 ms frames, none over 32 ms | 32 ms | pass |
| JS heap after the journeys | 49 MB | 250 MB after a day | pass (minutes of use) |
| DOM size, worst | about 2,000 elements | about 15,000 nodes | pass |
| Initial UI JavaScript | 245.8 kB signed in, 154.7 kB signed out (canonical method below; 259.5 kB signed in before the bundle pass) | 235 kB on React, 160 kB signed out | signed in over by 10.8 kB; measured cuts that reach 230 kB are listed in the app README |

Anchor drift, measured by `web/lab-timeline.html`: 21 of 21 operations pass; at most 0.91 px in one operation; under 0.5 px accumulated over 100 prepends or resizes.

On the bundle: React and ReactDOM are about 67 kB of the signed-in set (measured by building with them stubbed out: 245.0 kB to 180.8 kB, plus React itself). The rest is what the first frame uses: session models and the workspace, the UI kit, timeline, sidebar, composer, message row, link, store. Earlier figures (206, 247, 258 kB) were taken three different ways; the numbers above and from now on use the one method below.

## Standing rules

These come from the native clients and apply here unchanged.

- **First frame from local data.** If the data is on the device, the first frame shows it. A spinner or an empty flash for local data is a bug.
- **Rows are pure.** Rendering a row does no store query, network call, measurement or date formatting that could have been prepared. The data a row needs arrives ready.
- **Durable before discarded.** A draft or an intent is dropped from memory only after its durable commit.
- **The main thread is for input and paint.** Parsing, protobuf decoding, SQLite, diffing, search and media decoding happen in workers.
- **One owner per scroll position.** Only the timeline controller corrects scroll. Nothing else writes `scrollTop`.
- **Read layout, then write.** Batch DOM reads before DOM writes in a frame. Never read layout in a loop that also writes.
- **Reserve space.** Media, avatars and embeds have their size before they load.
- **Bounded DOM.** Long lists keep a bounded window of real rows.
- **Nothing unbounded in memory.** Every cache has a budget and an eviction rule. Closing a chat releases its view model and subscriptions.

## Measuring

- Mark the moments in the budget table with `performance.mark` and `performance.measure`, using stable names. The performance tests and the developer overlay both read these marks.
- Performance tests run in Playwright on Chromium with CPU throttling, against seeded data large enough to be honest: thousands of chats, hundreds of thousands of messages, long messages, media.
- A performance test runs several times and compares a robust statistic to the budget. Keep the trace of a failing run as an artifact.
- Measure production builds. Development builds, StrictMode and devtools all distort timings.
- When you optimize, record before and after numbers in the progress log, with the machine and the data set.

## Measuring the initial JavaScript

One method, one script: `bun run size <build dir>` (`tooling/measure-initial-js.ts`). It builds nothing.

```
bunx vite build --outDir <scratch dir> --manifest      # the production config, never into dist
bun run size <scratch dir>                             # table; --json for machine-readable, --out <file> to save it
bun run size <scratch dir> --check                     # exits 1 when a set is over budget (--budget <kB>, default 200)
bunx vite build -c tooling/measure-analysis.config.ts --outDir <scratch dir>
bun run size <scratch dir> --modules --entries         # plus the per-module breakdown and the entry checks
```

What it counts. Every file gzipped alone at level 9; kB are 1,000 bytes (the table also shows KiB). JavaScript only: the stylesheet, the core worker, the SQLite WASM and the service worker load in parallel or later and are not in the budget.

- **Entry**: the classic and module scripts and the modulepreloads in `index.html` (the appearance script included), each followed through its static imports.
- **Signed in**: the entry plus every chunk the boot path requests before the shell's first paint, each followed through its static imports. Which chunks those are is not a list in the script: it is `firstPaint.signedIn` in `src/app/view-chunks.ts`, the table `boot.ts` itself loads from when the gate enters the phase. The script imports that table, reads each name's literal `import("...")` in the same file, resolves the specifier to its source path and the source path to its output file through the build's Vite manifest. Today: the shell chunk.
- **Signed out**: the entry plus `firstPaint.signedOut` (the sign-in screen and the auth flows), the same way.
- **Deferred**: every other chunk a dynamic import can reach, with its own cost: its static closure minus the signed-in set (a file two deferred chunks share counts in both). Marked "warmed after paint" when it is in `afterFirstPaint` (loaded right after the first paint), else "on first use".
- **Breakdown** (`--modules`, analysis builds only): `tooling/measure-modules-plugin.ts` writes each chunk's modules with their rendered size; the script shares each file's real gzip out to its modules in proportion to each module's own gzip size, and rolls them up by package (`react-dom`, each `@inline/*`, `src/app`, each `src/features/*`). An attribution, not a measurement of a module alone; the shares add up to the set.
- **Entry checks** (`--entries`, any build with the module map, the labs build included): `src/main.tsx` runs only for `index.html` and each `src/lab/<name>/main.ts(x)` only for its own page (no shared chunk swallowed an entry's top-level code); a production `index.html` can reach nothing under `src/lab/` or `src/core/demo/`.
- **Experiments**: `MEASURE_STUB=path,path` with the analysis config replaces those modules with empty stand-ins of the same exports, which shows what deferring them would save without changing their owners' code.

The script's own tests: `bunx vitest run -c tooling/measure-vitest.config.ts` (a small hand-written build in `tooling/measure-fixture/`).

First canonical numbers, 17 November 2026 (this tree, production config):

| Set | Before the bundle pass | After |
| --- | --- | --- |
| Entry | 145.4 kB, 21 files | 136.5 kB, 3 files |
| Signed in | 259.5 kB, 34 files | 245.8 kB, 14 files |
| Signed out | 163.7 kB, 25 files | 154.7 kB, 7 files |

Of the signed-in 245.8 kB, React and ReactDOM are about 67 kB. Deferred, own cost: content 46.4 kB (right after paint), settings 23.4, Quick Search 20.7, sign-in 15.0, find 14.6, chat info 13.2, mentions 6.9, auth flows 6.4, message action layers 5.6, media viewer 4.7, notifications 4.4, attachments 3.0, service worker registration 2.0.

## Before you optimize

Find the cause first. In order: is the work needed at all; is it on the wrong thread; is it repeated because of a data-flow mistake (a render budget test will show that); is it the right algorithm. Only then tune. Do not add caches or memoization on a guess.

## Bundle discipline

- A new runtime dependency needs a reason and its gzip size recorded in `decisions.md`.
- Anything not needed for first paint of the signed-in shell is loaded later: the media viewer, settings, rich block renderers, search UI, emoji data.
- The worker bundle and the SQLite WASM start downloading in parallel with the UI bundle.
