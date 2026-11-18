# Browser and performance tests: plan

Status: **planned, not built.** The Node levels exist (`web/packages/client/src/testing/`, see its README). This file is the plan for the browser levels of `docs/testing.md`: what to build, where it goes, how it runs locally and in CI, and the pitfalls already paid for. The next agent should be able to follow it step by step.

## What each level is for

| Level | Tool | Runs against | Answers |
| --- | --- | --- | --- |
| Components | Vitest browser mode, Chromium (Playwright provider) | UI primitives rendered alone | Focus, keyboard, ARIA, layering, `dir="auto"` |
| End to end | Playwright: Chromium, WebKit, Firefox | Production build + local API server + seeded Postgres | Sign-in, send, reload, offline, two tabs, upgrade with an old tab open |
| Performance | Playwright, Chromium only, 4x CPU throttling | Production build + seeded account (large) | The budgets in `docs/performance.md`, from the app's `performance.measure` marks |
| Visual | Playwright screenshots | UI lab pages (`lab-ui.html`) | Light/dark, left-to-right/right-to-left |

Everything that can be shown in Node stays in Node. A browser test exists only for what needs a real engine: focus, layout, storage, workers, timing.

## Dependencies to add (needs the coordinator: shared `package.json`, `bun.lock`, `docs/decisions.md`)

- `@playwright/test`, pinned to the version `landing/` uses (1.63.0 today) so CI and laptops share one browser download. Upgrade both together.
- `@vitest/browser` and `@vitest/browser-playwright` at the installed Vitest's exact version (browser mode is stable since Vitest 4).
- Dev-only; record each in `docs/decisions.md` with the reason. No runtime dependency.

## File layout

```
web/
  vitest.browser.config.ts        # component tests: browser mode, provider playwright, chromium, headless
  tests/
    README.md                     # this plan, then the how-to once built
    playwright.config.ts          # projects below; reporter list + html; trace retain-on-failure
    global-setup.ts               # build check, start API server, migrate + seed, write auth storage state
    fixtures/
      api-server.ts               # start/stop the Bun API server on a free port (see "Local server")
      seed.ts                     # seeded account into Postgres via the server's test utilities
      app-server.ts               # `vite preview` of `dist/`, never `vite dev`
      persistent-profile.ts       # launchPersistentContext in a temp dir, for every storage test
      two-tabs.ts                 # two pages on one profile; leader detection; handoff waits
      marks.ts                    # read and clear performance.measure entries by stable name
      cpu.ts                      # CDP Emulation.setCPUThrottlingRate(4) per page
    e2e/
      sign-in.spec.ts             # sign in with a seeded test account; first frame from local data on reload
      send.spec.ts                # send, reload mid-send, the message exists once
      offline.spec.ts             # context.setOffline: queue, reconnect, deliver once, no failed state
      reload.spec.ts              # warm start shows sidebar and last chat with no spinner
      two-tabs.spec.ts            # leader handoff under a send, no duplicate, no lost intent
      upgrade.spec.ts             # an old tab open while a new build loads: old tab shows "updated", never writes
    perf/
      budgets.ts                  # the numbers from docs/performance.md, one place
      warm-start.perf.ts          # boot snapshot -> first paint; core live and interactive
      chat-switch.perf.ts         # in-memory and SQLite-only chats, input -> paint
      send.perf.ts                # keypress -> row painted
      timeline.perf.ts            # scroll and paging: frames over 32 ms, anchor drift
    lab/
      visual.spec.ts              # UI lab screenshots, light/dark, LTR/RTL
```

Component tests live next to their components in `web/packages/ui` and `web/packages/view` as `*.browser.test.tsx`, picked up only by `vitest.browser.config.ts`.

## Playwright projects

| Project | Browser | Test match | Notes |
| --- | --- | --- | --- |
| `e2e-chromium` | Desktop Chrome | `e2e/**` | Primary engine |
| `e2e-webkit` | Desktop Safari (Playwright WebKit) | `e2e/**` | Not Safari. Storage specs use the persistent profile fixture |
| `e2e-firefox` | Desktop Firefox | `e2e/**` | Most likely to differ on Trusted Types and editing |
| `perf-chromium` | Desktop Chrome | `perf/**` | `workers: 1`, CPU throttling 4x, trace on every run, kept on failure |
| `visual-chromium` | Desktop Chrome | `lab/**` | Screenshot comparisons |

Common `use`: `trace: "retain-on-failure"`, `screenshot: "only-on-failure"`, `serviceWorkers: "block"` until a test needs them, `baseURL` from the app server fixture. `retries: 0`: a flaky gate is worse than none; fix or quarantine with a reason.

## Local server and seeded data, without Docker

The API is the real server (`server/src/index.ts`) started by a fixture, as `server/src/__tests__/e2e/bridgeV2.e2e.test.ts` does in-process (`app.listen({ port: 0, hostname: "127.0.0.1" })`).

1. Postgres: a local server with `CREATEDB` (on macOS `brew install postgresql@16 && brew services start postgresql@16`). Point `TEST_DATABASE_URL` at it; `server/src/__tests__/database.ts` already refuses non-local URLs and creates a throwaway database per run. CI uses the GitHub `postgres` service container the server jobs already use (a runner service, not local Docker).
2. Environment: reuse `server/scripts/test-environment.ts` (`applyTestDefaults`) for the required variables (`ENCRYPTION_KEY` and friends), and its `localOnlyFetch` so no test can reach a provider.
3. Seed: create users and sessions with `server/src/__tests__/setup.ts` `testUtils` (`createUser`, `createSessionForUser` returns a token), then chats and messages from `generateSeedAccount` (`web/packages/client/src/testing/seed-account.ts`) through the server's models, in batches. Small scale for e2e; large for performance.
4. Auth: the global setup writes the session token into Playwright `storageState` so specs start signed in; one spec covers the real sign-in flow with a seeded email code.
5. App: `bun run build` then `vite preview --port 0 --strictPort=false` serving `dist/`, with `VITE_` API and realtime URLs pointed at the fixture server. The app's CSP must allow the local origins in this mode only.

## Two-tab helper

`fixtures/two-tabs.ts`: `openTwoTabs(context)` returns `{ leader, follower }` after both reach "ready", by reading the core's leader state through a test-only hook exposed by the walking skeleton (a `data-core-role` attribute or a `window.__inlineTest` read-only probe; agree it with the core-host package). Helpers: `closeLeaderMidSend()`, `waitForHandoff(timeout = 1_000)` (the budget), `countDeliveries(text)` via the seeded server. Uses one persistent context so both tabs share OPFS.

## Performance suite

- The app marks the budget moments with `performance.mark` and `performance.measure` under stable names (for example `inline:warm-start:first-paint`, `inline:chat-switch`, `inline:send:row-painted`). The suite reads `performance.getEntriesByType("measure")`; it never times from the outside.
- Each test runs the interaction N times (default 7) after one warm-up, takes the median (and the p90 for frame gaps), and compares with `perf/budgets.ts`.
- CPU throttling 4x through CDP (`Emulation.setCPUThrottlingRate`), Chromium only.
- Tracing: `context.tracing.start({ screenshots: true, snapshots: true })` for every run, plus a Chrome performance trace (`browser.startTracing`) per measured iteration; both saved as artifacts when a budget fails, discarded on success.
- Proof the suite bites: a `perf/self-test.perf.ts` that enables a test-only slowdown flag in the build (`?slow=send`) and expects the send budget to fail and the trace to be written.
- Record the first measurement of each budget and the machine in the program's progress log, as `performance.md` asks.

## CI jobs (`.github/workflows/integrations.yml`, needs the coordinator)

| Job | When | Steps | Time target |
| --- | --- | --- | --- |
| `web` (exists) | every push | typecheck, lint, `test`, `test:packages` (includes the Node harnesses and model-based seeds), build | under 3 minutes |
| `web-components` | every push touching `web/` | `bunx playwright install --with-deps chromium`; `vitest --config vitest.browser.config.ts --run` | under 3 minutes |
| `web-e2e` | every push touching `web/` or `server/` | postgres service; install chromium, webkit, firefox; build; `playwright test --project=e2e-*`; upload `playwright-report/` and `test-results/` always | under 10 minutes |
| `web-perf` | main and nightly, not on PRs at first | postgres service; chromium; build; seed large; `playwright test --project=perf-chromium`; upload traces | under 15 minutes |
| `web-model-sync-soak` | nightly | `MODEL_SYNC_SEEDS=2000 MODEL_SYNC_STEPS=120 bunx vitest run src/testing/model-sync.test.ts` in `web/packages/client`; a failure prints its seed | under 5 minutes |

Local commands to add to `web/package.json`: `test:components`, `test:e2e`, `test:perf`, `test:visual`, each runnable headless with one command.

## Known pitfalls (from `research-2026-11-16.md` and earlier runs)

- **Never measure against the Vite dev server.** An earlier run was invalidated when dependency optimization reloaded the page mid-measurement. Performance and end-to-end runs use the production build through `vite preview`.
- **Playwright's WebKit is not Safari.** Storage, OPFS and service worker results from it are indicative only; real Safari must be checked by hand before a release claims Safari support.
- **Use a persistent profile for storage tests.** WebKit temporary profiles failed OPFS start-up; `launchPersistentContext` in a fresh temp directory worked. Firefox was never launched successfully in the earlier lab: budget time for it.
- **Background-tab timers are unreliable** for liveness; the two-tab helper waits on Web Locks state, not timers.
- **Memory.** This machine has 8 GB; earlier browser runs timed out under memory pressure. Keep suites small, one worker for performance, and check `inline/.running` before a heavy run.
- **Development builds, StrictMode and devtools distort timings.** Measure production builds only.
- **No Docker locally.** Postgres runs as a local service; CI uses runner service containers.
