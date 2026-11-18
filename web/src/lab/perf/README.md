# Perf lab

`web/lab-perf.html` (source here) measures the app against the budgets in `web/docs/performance.md`. It boots the real app in demo mode (the real core against the simulated server, a seeded account) in a frame, drives scripted journeys through the app's own surfaces, measures each budget moment with the browser's performance APIs, and prints one row per budget with pass or fail. Nothing here ships: lab pages are only in the labs build.

## Run it

```sh
cd web
bunx vite build -c tooling/vite.labs.config.ts
bunx vite preview -c tooling/vite.labs.config.ts
# open http://localhost:8001/lab-perf.html?scale=medium&cpu=4
```

1. Use the labs build (a production build with the demo enabled). The dev server works but the lab marks every row as coming from a development build.
2. Set CPU throttling, the reference profile: DevTools > Performance > settings (gear) > CPU: 4x slowdown. Keep DevTools open (closing it drops the throttling) and declare it with `?cpu=4`; the page cannot detect throttling, so without the parameter the table says "CPU throttling not declared". DevTools being open costs a little; it is the documented profile.
3. Keep the window in front and the app frame on screen. A hidden or occluded window throttles animation frames; the lab measures the frame rate before each frame-dependent journey and refuses to grade those rows below 30 fps ("not measured: frames throttled").
4. Press **Run all** (or open with `&run=all`), wait a few minutes, then **Copy as Markdown** for the progress log. Close other tabs of the same demo first: the frame must be the leader tab.

Parameters: `scale=small|medium|large` (default medium; the sidebar budget is graded only at large), `seed`, `storage=opfs|memory` (passed to the demo), `cpu=N`, `run=all`.

From a script (the coordinator's browser, Playwright later):

```js
const snapshot = await __perfLabControl.runAll()            // every journey
await __perfLabControl.runAll({ journeys: ["send", "typing"], samples: { sends: 10 } })
await __perfLabControl.streaming()                          // one journey: its rows
__perfLab.rows.filter((r) => r.grade !== "pass")            // plain data, fresh on each read
__perfLab.markdown                                          // the table, ready to paste
```

`__perfLab`: `status` (`idle`, `loading`, `running`, `done`, `error`), `running`, `message`, `params`, `environment` (facts, warnings, the run line), `rows`, `counts`, `raw` (every journey's samples, per sample), `markdown`. `__perfLabControl`: one promise-returning function per journey (`warmStart`, `switchSqlite`, `switchMemory`, `send`, `typing`, `incoming`, `streaming`, `scrollPaging`, `sidebar`, `initialJs`, `leaderHandoff`, `memory`), `runAll(options)`, `environment()`, `load(scale?)`, `markdown()`, `snapshot()`. Calls run one at a time.

## How it hosts the app

A same-origin `<iframe>` pointed at `/?demo=<scale>`, observed and driven from the page (`host.ts`). The app runs exactly as shipped (its own document, boot, content policy, service worker and history binding), a journey can reload it to measure a real warm start, and the lab reads `contentWindow.__inlineApp`, `__inlineDemo`, the frame's performance timeline and its DOM. Mounting the app into the lab's own document was rejected: the app's history binding rewrites the address to `/c/<id>`, which would replace the lab's URL, and a warm start needs a fresh document.

Costs, stated in the results where they matter:

- The frame shares the lab's main thread. The lab does nothing while a journey measures and renders its table between journeys; its probes (a `requestAnimationFrame` loop, mutation observers) cost a little and are inside the numbers.
- The service worker controls both documents; a reload is served from its cache, which is what a warm start is.
- The frame is the app's window: its size is in the run line.
- The app's modules are its own instances, so the lab cannot install the render counter inside it (see "Hooks").

## Rows: method and caveat

Times are on the app frame's clock (`performance.now()` of its window). "Paint" is a frame then a task after the result is in the DOM, the app's own definition (`web/src/app/perf.ts`). "Paint frame" counts frames: 1 means the result was in the DOM before the first animation frame after the input ran, so it was painted in the next frame. Every wait has a timeout and fails naming what did not happen; a journey that throws fills its rows with `error` and the others still run.

Event Timing (`PerformanceObserver` type `event`, `interactionId`, `duration`) was the first choice for input-to-paint, but it reports trusted input only, and every input here is dispatched by script. So input time is `performance.now()` just before dispatch, and the result is found by a `MutationObserver` (a microtask after the DOM change), then a frame and a task. Real input adds the browser's own input latency on top.

Grades: `pass`/`fail` on the median (or the worst sample, for ceilings such as "no frame over 32 ms"); `inconclusive` when the method measures something adjacent (an upper bound that came out over, a scale the budget is not for, a hidden list the lab cannot explain); `not measured` without samples, without the API, or with throttled frames; `error` when the journey threw; `info` for numbers with no budget.

| Row | Input | Method | Caveat |
| --- | --- | --- | --- |
| Warm start, first paint of sidebar and last chat (150 ms) | reload | Reload the app frame on an open chat (its URL is `/c/<id>`; the demo choice is remembered for the tab), 5 times; read `inline.boot.snapshot-paint` when the app records it, else the later of `inline.boot.sidebar-rows` and `inline.boot.chat-rows`. Info rows: shell paint, sidebar rows, chat rows, snapshot paint. | Without the boot snapshot this is the paint of live data, the nearest moment. The lab's first load (seeding, service worker install) is in `raw.firstLoad`, not graded. |
| Warm start, core live (500 ms) | reload | `inline.boot.core-ready` from the same reloads. | The core's phase, not a check that input is handled. |
| Switch to a chat in memory (next frame) | synthetic | Open chat A, open B, then alternate 10 `click()`s on their sidebar rows; paint frame from a `requestAnimationFrame` loop. Fails if the list was ever hidden (`aria-busy`). Extras: click to paint, the app's own `inline.chat.switch`. | Residency is assumed (both opened in this page load); the app does not say. |
| Switch to a chat only in SQLite (100 ms) | synthetic | `click()` on 6 sidebar rows (among the first 25) not opened in this page load, reloading when none are left; click to paint. | That the rows are in SQLite is assumed (recent chats the core repaired). A list hidden while loading makes the row inconclusive: not local, or not painted from local; the lab cannot tell. |
| Send (one frame) | synthetic | Insert a unique text with `execCommand("insertText")`, dispatch an Enter `keydown` on the editor, find the row with that text; paint frame. Extras: to DOM, to paint, to the composer clearing (the durable commit). | Untrusted key events; no browser input latency. |
| Typing: no keystroke waits on store work | synthetic | 60 keystrokes 35 ms apart (`keydown`, `execCommand("insertText")`, `keyup`), then 700 ms for the debounced draft save; long tasks from `PerformanceObserver` `longtask` (budget: none). Extras: synchronous keystroke handling, keystroke to next frame, Long Animation Frames. | Store work is in the worker; waiting on it would show as a slow handler or a long task. Stalls under 50 ms show only in the extras. |
| Typing: zero timeline renders | synthetic | `MutationObserver` on the timeline root over the same window; budget 0 mutations. | A proxy: a render that commits nothing is not seen. |
| Incoming message at the bottom (one frame of the patch) | handle | `__inlineDemo.send({ kind: "deliver", chatId })` 8 times into the open chat (following latest); paint frame counted from the demo's result to the row. Graded at 2 frames. Extras: result to paint, result to DOM (negative when the row came first), command to result. | The patch is not observable: the result travels beside it (BroadcastChannel versus the core's port), so one frame of allowance is added. |
| Streaming at 20, 40, 60 updates a second (only that row; under 4 ms scripting per update) | handle | Two passes per rate. Pass 1 (3 s): `requestAnimationFrame` deltas, long tasks, Long Animation Frames (Chromium only; reported as unsupported elsewhere) with their top scripts, and every mutation under the timeline root, split into inside and outside the streaming row; any mutation outside fails the row. Pass 2 (2 s): a busy probe (a self-posting `MessageChannel` loop; gaps over 0.5 ms are other work) minus a 2 s idle baseline, per 250 ms window, divided by the row's DOM updates in that window. | Scripting per update is not observable; the probe's number includes style, layout and paint, so it is an upper bound: under 4 ms passes, over is inconclusive. The probe spins the thread, hence the separate pass. "Edits sent" comes from the demo status (approximate). |
| Scroll and history paging (no frame over 32 ms) | synthetic | In the open chat, each frame: a `wheel` event on the scroller then `scrollTop -= 80` (as the timeline lab does), until 4 pages of history arrive (new keys at the head) or the top; up to 3 chats when one runs out. Graded on the worst frame delta. | `requestAnimationFrame` deltas show main-thread frames, not compositor-only ones; the loop keeps frames coming; a 120 Hz display halves the base interval. No momentum. Anchor drift is the timeline lab's job. |
| Sidebar: scroll (no frame over 32 ms, bounded rows) | synthetic | `scrollTop += 320` per frame to the end of the list; frame deltas; fails above 50 rows in the DOM. | Inconclusive below the large scale. Same frame-delta limits. |
| Sidebar: update one chat (one row) | handle | Deliver to the open chat once (it moves to the top), then 4 deliveries; rows with mutations under the listbox within 15 frames. | Mutations stand in for renders. A reorder makes it inconclusive. |
| Leader tab handoff | none | Not measured. | Needs a second tab and closing the leader mid-send; the app README's check 12, by hand. |
| Memory: JS heap (250 MB) | passive | `performance.memory.usedJSHeapSize` of the frame after the journeys; before is in the extras. | Non-standard, Chromium only, quantized; minutes, not a working day; includes the lab's heap (same agent). |
| Memory: DOM (15,000) | passive | Elements in the app's document after every journey; the worst. | Elements; all nodes are in the extras. |
| Initial UI JavaScript (200 KB gzip) | passive | The frame's resource timing: same-origin scripts whose fetch started before `inline.boot.shell-paint`, without workers, SQLite, `connect-demo` and `dev-snapshot`; each fetched again and gzipped with `CompressionStream`. | The preview server does not compress; production may use brotli. KB is 1,000 bytes. The excluded files are listed in `raw.initialJs`. |

The run line above the table states the date, scale, build, declared throttling, frame rate, browser, device pixel ratio, the frame's size and a CPU probe (a fixed workload's time, to compare runs on one machine; about 4x under 4x throttling). Warnings say what makes the run less meaningful: a development build, undeclared throttling, a follower tab, missing APIs, more than one pane.

Journeys leave the demo usable: the composer empty, the list back at latest, the sidebar at the top. Each run adds sent, delivered and agent messages to the demo account, which is harmless; to start over, use the demo lab's "Reset this demo".

## Hooks the app should add

Each would turn an adjacent measurement into an exact one. Until then the rows above say what they measure instead.

1. **Render counts** in the labs build: `web/src/app/dev-snapshot.ts` installs `createRenderCounter()` (`@inline/reactive/react/testing`) when the page has `?renderCounts=1` and exposes `__inlineApp.renderCounts` (`counts()` and `reset()`). Typing, streaming and the sidebar update would then count `timeline:row`, `timeline:list` and `sidebar:row` renders instead of DOM mutations.
2. **Patch applied**: a `performance.mark("inline.patch.apply", { detail: { rows } })` where the store client applies a frame-lane batch (`web/packages/reactive/src/store/client.ts`), or `__inlineApp.lastPatchAt`. Incoming and streaming would start the clock at the patch, not the demo's result.
3. **Scripting per update**: a `performance.measure("inline.patch.apply", start)` around that batch and the commit it causes, so streaming measures scripting per update instead of bounding it with the busy probe.
4. **How a chat opened**: `__inlineApp.openChat.source` (`"memory" | "sqlite" | "network"`), set by `OpenChat` (`web/src/features/chat/chat-pane-model.ts`), so the two switch rows know which path ran.
5. **Boot snapshot paint**: `inline.boot.snapshot-paint` (the boot snapshot work), which the warm-start row already reads when present.
6. **Trusted input** (later, test infrastructure): driving the same journeys through CDP `Input.dispatch*Event` would make Event Timing report them and include the browser's input latency.

## Files

| File | What |
| --- | --- |
| `main.ts` | The page: frame, controls, table, `__perfLab`, `__perfLabControl`, copy as Markdown. |
| `lab.ts` | State, the one-at-a-time queue, environment collection, `runAll`. |
| `host.ts` | `AppFrame`: loading and reloading the app, its globals, and finding its surfaces by their documented attributes. |
| `journeys.ts` | The journeys, their input, and their rows. |
| `probes.ts` | Browser probes: frame recording, observers, waiting on the DOM, after-paint, the busy probe, the CPU probe. |
| `budgets.ts` | The budget table as data, grading, rows. Pure. |
| `stats.ts` | Median, percentiles, frame and busy-probe arithmetic. Pure. |
| `environment.ts` | Parameters and the run's conditions. Pure. |
| `markdown.ts` | The Markdown table and number formatting. Pure. |
| `resources.ts` | Which scripts count as initial UI JavaScript. Pure. |
| `lab.css` | Page styles (plain CSS, like the demo lab; the page has no app components). |

Tests: `bunx vitest run src/lab/perf` from `web/` (statistics, frame and busy-probe arithmetic, grading against budgets, merging rows, parameters and environment checks, the Markdown table, the initial-script rules). The journeys and probes need a browser and are not run by any test; the coordinator runs the page.
