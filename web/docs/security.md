# Security

What the web and desktop client must hold to. Read this before adding a dependency, rendering user content, handling a link, or changing headers or the build's content policy.

The session's keys are readable by script on the app origin. So the working assumption is simple: any script that runs on the origin owns the account. Everything below follows from keeping other people's code and bytes off it.

## Origins

- The app is on `app.inline.chat`. Marketing, docs and public pages are on `inline.chat`.
- User-uploaded bytes are served from other origins, never from a product origin.
- Widgets and other user- or agent-authored HTML run only in sandboxed frames on a separate registrable domain, with no access to the app's storage or session.
- No preview deployments on product origins. Previews use a separate domain and a test API.

## Content policy

The production build ships a strict Content Security Policy with Trusted Types (`vite.config.ts`).

- No inline scripts, no `eval`, no third-party scripts. `'wasm-unsafe-eval'` is allowed for SQLite only.
- No inline `<style>` blocks or style attributes in markup. Setting a style or CSS variable on an element from code is allowed.
- No raw HTML sinks: no `innerHTML`, `outerHTML`, `insertAdjacentHTML` or `dangerouslySetInnerHTML`. Trusted Types blocks them in browsers that support it; do not rely on that, since not every browser enforces it.
- Script URLs are sinks too: `new Worker(...)` and `navigator.serviceWorker.register(...)` take a URL only through `trustedScriptUrl` (`src/sw/trusted-script-url.ts`), the one named Trusted Types policy the content policy allows. It returns same-origin `http:` and `https:` URLs without credentials only (not `blob:` or `data:`, even same-origin). There is no default policy.
- `connect-src` lists the API hosts. A new host is a reviewed change.
- Response headers add what a meta tag cannot: `frame-ancestors 'none'`, HSTS, `Referrer-Policy`, `Permissions-Policy`.
- The service worker serves a cached shell or file only when its bytes match the build's manifest revision, checked on every response; anything else (a response planted in Cache Storage by script) is dropped, the cache is rebuilt and the network answers. It adds the shell's meta policy as a `Content-Security-Policy` header too, beside any the host sends. Files of older builds, kept for old tabs, cannot be checked by the new worker and are served as cached.

Do not weaken the policy to make something work. Find another way or raise it.

## Rendering user content

- Message text is rendered from structured entities into DOM nodes, never from HTML strings.
- One link-scheme allowlist lives in `chat-ui` and every link passes through it. Unknown schemes render as text.
- External links open with `rel="noopener noreferrer"`. In Electron they go to the system browser, never to an app window.
- Media from users is displayed with `<img>`, `<video>` and `<audio>` from the media origin. SVG from users is never inlined.
- File names, titles and other user strings are text nodes. File names lose bidirectional embedding, override and isolate controls (U+202A to U+202E, U+2066 to U+2069) and control characters before they are shown or used as a download name (`displayFileName`, `downloadFileName`), and are drawn in their own direction-isolated element (`dir="auto"`).
- Bot buttons show what the bot did not write: a confirm dialog names the link's host (or mail address, or number), and a copy button's toast shows the start of the copied text (`buttonDisclosure`).
- Pasted content in the composer's own clipboard format is honored only when this document wrote it; a page can set that format too. Text hidden only by styling is pasted as visible plain text.

## Dependencies

- Runtime dependencies stay few and are pinned to exact versions. Today that means the view framework, StyleX, the signals library, SQLite WASM, msgpack, the protobuf runtime and `@noble` crypto.
- Adding a runtime dependency needs a recorded reason, its size, and a look at its own dependencies. Prefer writing 100 lines over importing a package for them.
- No dependency that loads code or assets from a third-party host at runtime.
- Build-time dependencies are less sensitive but still pinned by the lockfile; CI installs with a frozen lockfile.

## Session and storage

- The session record is kept by the `auth` package and shared across tabs.
- Sign-out and server-side revocation erase, in this order:
  - In the core (worker): it refuses new intents (`signingOut`), writes an erase marker (`accounts/<accountKey>/erase-pending` in OPFS), hands `LOG_OUT` to the socket without waiting (sign-out only), closes the replica, erases the media files and the replica with its search index, removes the marker, and only then reports `phase: "signedOut"` with `erased: "complete"` or `"failed"` (the marker then stays).
  - In each tab: `AccountSession.end` releases the views at once and keeps the core connection open until that report, at most 10 s (`SIGN_OUT_WAIT_MS`), recording the outcome. The link, once a sign-out passed through it, waits up to 30 s (`SIGN_OUT_SHUTDOWN_TIMEOUT_MS`) for the core to shut down before terminating the worker, instead of the usual 3 s.
  - In the page, from the app's erase hook: the workspace, the boot snapshot, the quick search usage and the service worker caches.
- What an interrupted erase leaves (tab closed, worker killed, erase failed) is removed later: the account's next start finishes a marked erase before opening anything, and the boot sweep (`src/core/account-storage-sweep.ts`) runs on the idle lane at every start and removes the SQLite pool of this server's namespace and the media root (`accounts/u<id>/`) of every account no session in this browser owns. It skips an account whose link leader lock is held (a core may have it open), reads the owners again under that lock, removes nothing while the auth store cannot say who is signed in, and writes the erase marker first and removes it last, so an interrupted sweep is finished by the next one. Media without a pool in this namespace and without a marker is left alone (it may be another server's or the demo's). The boot snapshot (checked against the auth store at every start) and the service worker caches (no account data) need no sweep.
- Nothing secret goes into a URL, a log line or the diagnostics export. The export is redacted by construction: it includes IDs, counters and states, never message text or keys.
- Storage is per account. One account's context never opens another account's files.

## Desktop

Electron adds its own rules; see `desktop.md`. In short: sandboxed renderers with context isolation, no Node integration, a narrow preload, the app served from a custom scheme under the same content policy, and no remote code.

## When something needs sign-off

Changes to the content policy, a new origin or host, anything that renders HTML from outside the bundle, and anything that changes how session keys are stored need sign-off before they land.
