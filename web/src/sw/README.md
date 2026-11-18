# Offline shell: the service worker

The app starts with no network. A service worker precaches the hashed shell of one build. A new build waits, and the app offers to reload. Code is never swapped under a running tab. No Workbox: the worker is about 5 kB and this project owns it.

## Files

| File | What it is |
| --- | --- |
| `protocol.ts` | Injected config type, cache names, page and worker messages. Has no imports. |
| `service-worker.ts` | `installServiceWorker(scope, config)`: install, activate, fetch and message handlers. |
| `sw-entry.ts` | Entry of `/sw.js`. Runs `installServiceWorker(self, __INLINE_SW_CONFIG__)`. |
| `register.ts` | Page side: `registerServiceWorker(options)`, `clearServiceWorkerCaches(caches)`, `browserEnv()`. |
| `trusted-script-url.ts` | `trustedScriptUrl(path)`: one Trusted Types policy (`inline-script-url`) that only accepts same-origin `http:`/`https:` URLs without credentials. |
| `types.ts` | The parts of the worker global and of `navigator.serviceWorker` this module uses. The app compiles against the DOM library, which has no worker types. |
| `testing/` | Fake Cache Storage, fake network, fake browser lifecycle and fake builds. Shared by the tests. |
| `../../tooling/service-worker-plugin.ts` | Vite plugin that emits `/sw.js`. |
| `../../tooling/precache-manifest.ts` | Pure function: emitted files in, precache manifest out. |
| `../../tooling/vite.labs.config.ts` | Throwaway config for the scratch build and the lab. |
| `../../lab-sw.html`, `../lab/sw/main.ts` | The lab page. |

## Build

`serviceWorkerPlugin({ buildId })` runs only in `vite build`. It runs in `generateBundle` with order `post`, so Vite's HTML and worker outputs are already in the bundle.

1. **Manifest.** It starts at `index.html` and follows references. A chunk refers to its static and dynamic imports. A text file (HTML, JS, CSS, worker bundles) refers to every emitted file whose name appears in it. This reaches:
   - the entry chunk, its CSS and lazy chunks;
   - the core worker (Vite emits it as an asset whose URL is a string in the chunk);
   - the worker's chunks and `sqlite3-*.wasm`.

   It leaves out lab pages and anything only they use. Source maps, other `.html` files, `.vite/` and `sw.js` are never included. Each entry has a revision: the first 16 hex characters of the file's SHA-256. The shell is stored under `/`, not `/index.html`, because static hosts commonly redirect `/index.html` to `/`.
2. **Worker script.** The plugin runs a second Vite build with no config file and no app plugins. It builds `sw-entry.ts` as one IIFE (a classic script: Firefox at our floor has no module service workers) and injects the manifest with `define`. The build fails if the worker bundle contains any module outside `src/sw/`.
3. **Emit.** The script is emitted unhashed as `sw.js` at the site root.

The scratch build (see "Verified") produced a manifest of `/`, `index-*.css`, `index-*.js` and `modulepreload-polyfill-*.js`. Today `index.html` does not load the core worker. Computed with `lab-core.html` as the shell, the manifest adds `core.worker-*.js`, `dist-*.js`, `sqlite3-*.wasm`, `sqlite3-worker1-*.js` and `sqlite3-opfs-async-proxy-*.js`. The last two (about 250 kB) are referenced by sqlite-wasm but unused by the SAH pool. Drop them with `exclude` once the core is confirmed never to load them.

## Lifecycle

- **Install.** Downloads the whole manifest into memory first:
  - the shell with `cache: "no-cache"`, hashed files from the HTTP cache when possible;
  - each file's revision is checked, so a stale edge or a modified file fails the install;
  - only then are the files written to `inline-sw-shell-<buildId>`: assets first, then the shell, then a completion marker.

  Any failure (download, revision, quota) deletes the cache. The worker then becomes redundant and the browser retries at the next update check. A cache without the marker is left over from an interrupted install and is rebuilt from scratch. Stored responses keep the host's headers (for example `X-Frame-Options`). Transfer headers (`content-encoding`, `content-length`, `transfer-encoding`, `set-cookie`) and the redirect flag are dropped. Install never calls `skipWaiting`.
- **Activate.** Happens in three cases:
  - nothing was active (first install);
  - no window uses the old worker;
  - a page sent `inline-sw:skip-waiting` after the user chose to update.

  It prunes old caches (below), then calls `clients.claim()`, which only affects windows without a controller: the first install's page, or a hard-reloaded tab.
- **Fetch.**
  - Non-GET, cross-origin, ranged and query-string requests get no `respondWith`. That covers the API, WebSocket upgrades (which never reach a service worker anyway) and media.
  - App navigations get the precached shell, so a deep link works offline. A navigation is not answered with the shell when its last path segment contains a dot (`/lab-sw.html`, `/sw.js`, `/robots.txt`; app routes never contain one) or when it is under a `navigationDenylist` prefix (default `/__`).
  - Precached files are served cache-first.
  - Other files under `/assets/` are looked up in the caches of other builds, then fetched from the network.
  - Everything else is not touched.
  - If this build's cache is gone (cleared at sign-out), the request goes to the network and the worker refills its cache in the background. No other build's shell stands in for it, even offline: this worker cannot check those bytes.
  - **Integrity.** Script on the origin can write Cache Storage, so a cached shell or file of this build is served only when its bytes still match the manifest's revision, checked on every response (read and SHA-256: about 0.01 ms for the shell, 0.12 ms for 250 kB, 0.4 ms for the 900 kB WASM, measured in Bun on an M-series Mac; expect several times that on slow phones). On a mismatch the build's cache is deleted and rebuilt in the background and the request goes to the network. Files of other builds (old tabs' lazy chunks) are served unchecked: their revisions belong to a worker that is gone.
  - **Policy header.** The plugin reads the shell's meta content policy (`shellPolicyOf`) into `shellPolicy`; the worker appends it as a `Content-Security-Policy` header to the shell it serves, keeping any policy the host sent. Header and meta carry the identical policy, so their intersection is that policy; the header also covers anything parsed before the meta tag.
- **Worker requests.** The core's dedicated worker and its WASM are fetched through the same service worker. The window's request covers the worker script; the worker is itself a client for its own imports and the WASM.

## Version skew and cache cleanup

Every page sends `inline-sw:hello` with its build ID, after registering, on a controller change and on a back-forward cache restore. The worker records `windowId → buildId` in the `inline-sw-meta` cache. That record survives the worker being stopped and is shared by the old and the new worker. It holds no account data.

Prune runs on activate and on every hello. It deletes a build's cache only when:

- the build is not this worker's;
- the build is not newer than this worker's (a waiting or installing worker's cache is never touched);
- no living window runs that build.

If any living window has not said which build it runs, nothing is deleted that round. So an old tab keeps getting its build's lazy chunks, worker and WASM, even offline, after another tab applied an update. When the last tab of a build closes, the next hello removes that build's cache.

`buildId` must be the same value in the plugin and in `registerServiceWorker` (`__INLINE_BUILD_ID__`). Build IDs sort lexically, newest last.

## Updates (page policy)

`registerServiceWorker` reports to an `UpdateFeed` from `@inline/platform`:

| Feed state | `pending` | When |
| --- | --- | --- |
| `none` | `none` | No update, or the first install |
| `available` | `installing` | A new build is downloading |
| `ready`, with `version` when known | `waiting` | The new build is installed and waits |
| `ready`, with `version` when known | `activated-elsewhere` | Another tab already switched to the new build; this tab still runs the old one |

The version comes from the worker's `inline-sw:build` message.

- **`apply()` / `applyUpdate()`.** Runs only when the state is `ready`. It is the user's decision, so the update offer should mention unsent work if any. It posts `inline-sw:skip-waiting` to the waiting worker and reloads this tab on `controllerchange`. If the new worker has not taken over after `applyTimeoutMs` (10 s), it reloads anyway. If the worker already changed (`activated-elsewhere`), it just reloads.
- **First install.** The worker claims the page. There is no reload and no update state.
- **Another tab applied.** The tab tells the new worker its build, so its files stay, and reports `ready`.
  - A visible tab is never reloaded without the user.
  - A hidden tab reloads by itself only if `hasUnsavedWork()` returns false, either at once or later when it becomes hidden.
  - Without a `hasUnsavedWork` callback a tab never reloads by itself.
  - Durable intents and drafts survive a reload. `hasUnsavedWork` covers what does not: uploads in flight, unsaved composer state.
- **Checks.** The browser checks for an update when the worker registers. After that, every `checkIntervalMs` (60 min) on the injected clock, and on focus, online and visible, at most once per `minCheckGapMs` (5 min). Registration uses `updateViaCache: "none"`. Failed checks (offline) are ignored.
- **Production only.** Registration runs only when `enabled` is true and the page is a secure context, and only after the `load` event. With `enabled: false`, any existing `/sw.js` registration on the origin is unregistered and its caches are deleted. This matters because `vite preview` and `vite dev` share port 8001.

This lines up with the version-skew rule in `docs/architecture.md`: the newest build leads, and older tabs show "Inline was updated" and reload. The service worker is one source of that signal; link's build comparison is the other. Both end in a reload.

## Sign-out

The security guide's sign-out list includes the service worker caches. Call `clearServiceWorkerCaches(globalThis.caches)`, or `controller.clearCaches()`, from the `eraseAccountData` hook of `@inline/auth` `signOut`. It deletes every `inline-sw-*` cache from the page, whether or not a worker runs, and touches no other cache. The shell holds no account data, so the worker refills it on the next online navigation.

## Kill switch

There are two layers. Use both in the same deploy.

1. **Worker.** Build with `serviceWorkerPlugin({ buildId, killSwitch: true })`. The deployed `/sw.js` installs without waiting and takes over. It deletes every `inline-sw-*` cache, unregisters, and has no fetch listener. The windows it still controls go to the network as if there were no worker, and keep running their code until they reload. A tab stuck on a broken cached shell is rescued by this layer, because the browser checks `/sw.js` on navigation.
2. **App.** In the same deploy, set `registerServiceWorker({ enabled: false, ... })`. Pages that load the new code unregister and clear caches themselves, and stop registering. Without this layer every page load re-registers the kill worker, which is harmless but wasteful.

To recover, deploy normally again.

## Content policy

`vite.config.ts` lists the policy name (decided 17 November 2026, `docs/decisions.md`):

```ts
"trusted-types inline-script-url",
```

`require-trusted-types-for 'script'` makes `navigator.serviceWorker.register`, `new Worker` and `new SharedWorker` Trusted Types sinks. In a browser that enforces Trusted Types (Chromium today, and every engine as it ships them) a plain string throws. `trustedScriptUrl()` creates one named policy (once per document) whose only rule is "an `http:` or `https:` URL of the page's origin, without credentials, made absolute" (a same-origin `blob:` URL is refused: its bytes are whatever a script put there). `script-src 'self'` and `worker-src 'self'` already allow nothing else, so the policy adds no reach. It does not add a `default` policy and does not touch the HTML or script sinks. Until the directive lists the name, `createPolicy` throws, the code falls back to the string, and an enforcing browser refuses the registration. The controller then reports `phase: "failed"`, and the app keeps working without offline support.

The core's worker in `src/core/connect.ts` hits the same sink today: `new Worker(new URL(...))` with a string will throw under the current policy in Chromium. Suggested fix, which keeps Vite's worker bundling:

```ts
import coreWorkerUrl from "./core.worker.ts?worker&url"
import { trustedScriptUrl } from "~/sw/trusted-script-url"
new Worker(trustedScriptUrl(coreWorkerUrl) as string, { type: "module" })
```

`?worker&url` is not verified here; check the emitted name in a build. Wrapping `new URL(...)` in a call stops Vite from recognizing the worker pattern.

## Wiring (coordinator)

`web/vite.config.ts`:

```ts
import { serviceWorkerPlugin } from "./tooling/service-worker-plugin"
// in contentSecurityPolicy:
"trusted-types inline-script-url",
// in plugins, after documentPolicy():
serviceWorkerPlugin({ buildId, killSwitch: process.env.INLINE_SW_KILL === "1" }),
```

`web/src/main.tsx`, after the platform is created (`createWebPlatform` returns `updates`):

```ts
import { registerServiceWorker } from "./sw/register"

const serviceWorker = registerServiceWorker({
  enabled: import.meta.env.PROD && platform.info.kind === "web",
  buildId: __INLINE_BUILD_ID__,
  feed: platform.updates,
  hasUnsavedWork: () => /* uploads in flight, unsaved composer state */ true,
})
// sign-out: signOut({ ..., eraseAccountData: async (userId) => { ...; await serviceWorker.clearCaches() } })
```

Electron does not use the service worker: it updates through `electron-updater`.

The build-time code lives in `web/tooling/` (not `web/build/`, which the repository's ignore rules would hide from git and lint).

## Hosting headers

| Path | Headers |
| --- | --- |
| `/sw.js` | `Cache-Control: no-cache, max-age=0` (purge at the CDN on deploy). `Content-Type: text/javascript`. `Content-Security-Policy: default-src 'none'; connect-src 'self'; require-trusted-types-for 'script'` (the worker only fetches same-origin files). No `Service-Worker-Allowed`: the worker is at the root with scope `/`. |
| `/`, `/index.html`, and every SPA fallback (any unknown path → `index.html` with 200, for first-visit deep links) | `Cache-Control: no-cache`. `frame-ancestors 'none'`, HSTS, `Referrer-Policy`, `Permissions-Policy` as `security.md` lists. The cached shell keeps these headers until the next update. The served bytes must equal the built `index.html`: no HTML rewriting, minifying, email obfuscation or script injection at the edge, or the revision check fails the install. |
| `/assets/*` | `Cache-Control: public, max-age=31536000, immutable`. `.wasm` as `Content-Type: application/wasm`. Keep previous builds' assets for at least 14 days (upload additively): old tabs that are uncontrolled or have no cache still need their chunks. Do not put a CSP header on worker scripts unless it includes `'wasm-unsafe-eval'`. |

## Tests

From `web/`: `bunx vitest run src/sw`. The app's `vitest.config.ts` includes `src/**/*.test.ts`, which covers these tests. Build-side tests live in `src/sw/precache-manifest.test.ts` because nothing collects tests under `build/`.

The fakes (`testing/`) model one registration with installing, waiting and active workers; the waiting rule; `skipWaiting`; controller hand-over with `controllerchange`; `clients.claim` and `matchAll`; messages both ways; Cache Storage with failing writes; and a network with an offline switch and per-URL failures. Each fake worker runs the real `installServiceWorker`. Each fake page runs the real `registerServiceWorker` on a manual clock.

## Verified

- 41 tests: install atomicity (download failure, revision mismatch, quota mid-write, interrupted install); waiting; apply; old-tab files offline after an update; cleanup only when safe; offline deep link; passthrough of API, cross-origin, POST, range and query requests; navigation denylist; kill switch; sign-out refill; and the page policy (hidden or visible tabs, unsaved work, periodic and focus checks, apply timeout, disabled and unsupported cases, Trusted Types URL).
- Scratch production build with `tooling/vite.labs.config.ts`. The manifest lists the shell, CSS, entry and polyfill only. Its revisions match `shasum -a 256` of the written files. `sw.js` (5.3 kB) parses as a classic script. The kill-switch variant builds.

## Must still be verified in real browsers

- Cold offline launch from a deep link (Chromium, Firefox, Safari), including the core worker and the WASM coming from the cache: dedicated workers are controlled, and `instantiateStreaming` works on a cached response.
- Update with an old tab open: apply in one tab while another, older tab lazy-loads offline; a hidden idle tab reloads; a visible tab shows the offer.
- `navigator.serviceWorker.register` under the enforcing CSP with the `inline-script-url` policy, and failure without it.
- Safari: registration, install of the roughly 900 kB WASM within storage limits, eviction behavior, and back-forward cache restores (`clients.matchAll` and bfcache pages).
- An update with a pending send does not lose it (package 2I done criterion), and a real schema upgrade.
- The lab (`lab-sw.html`) under `vite preview`. Unregister there before going back to `vite dev` on port 8001.
