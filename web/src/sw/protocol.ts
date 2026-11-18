/**
 * What the build, the service worker and the page agree on: the injected
 * configuration, cache names and the messages between page and worker.
 *
 * Imported by the worker, the page-side registration and the build plugin, so
 * it must stay free of any import (the worker bundle is checked for that).
 */

/** One file the worker precaches. */
export interface PrecacheEntry {
  /** Absolute path on the app origin, e.g. `/assets/index-BP8BdOia.js`. */
  readonly url: string
  /** First 16 hex characters of the SHA-256 of the file's bytes. Install checks it. */
  readonly revision: string
  /** Size in bytes, for the lab and the build report. */
  readonly size: number
}

/** Injected into the worker at build time as `__INLINE_SW_CONFIG__`. */
export interface ServiceWorkerConfig {
  /**
   * The app build this worker belongs to: the same value as the page's
   * `__INLINE_BUILD_ID__`. Build IDs sort lexically, newest last.
   */
  readonly buildId: string
  /**
   * The shell document, fetched at this URL and served for every app
   * navigation. `url` is the site root (`/`), not `/index.html`, because static
   * hosts commonly redirect `/index.html` to `/`.
   */
  readonly shell: PrecacheEntry
  /** Hashed JS, CSS, worker chunks and the SQLite WASM. */
  readonly assets: readonly PrecacheEntry[]
  /**
   * Requests under this path that are not in `assets` may belong to an older
   * build an old tab still runs; they are looked up in the caches of other
   * builds before going to the network. Everything under it is content-hashed.
   */
  readonly assetsPath: string
  /**
   * The content policy of the shell's meta tag, read at build time. The worker
   * adds it as a response header to the shell it serves (an identical policy
   * in a header and a meta tag enforce the same thing; the header also covers
   * what comes before the meta tag). Absent when the shell has none.
   */
  readonly shellPolicy?: string
  /** Navigations to these path prefixes are never answered with the shell. */
  readonly navigationDenylist: readonly string[]
  /**
   * Replace every installed worker with one that deletes the caches and
   * unregisters. See README, "Kill switch".
   */
  readonly killSwitch: boolean
}

/** Every cache this module owns starts with this, and nothing else does. */
export const CACHE_PREFIX = "inline-sw-"
/** One cache per build, holding exactly the build's precache manifest. */
export const SHELL_CACHE_PREFIX = `${CACHE_PREFIX}shell-`
/** Bookkeeping: which build each open window runs. No account data. */
export const META_CACHE = `${CACHE_PREFIX}meta`

export const shellCacheName = (buildId: string): string => `${SHELL_CACHE_PREFIX}${buildId}`

export const buildIdOfCache = (name: string): string | null =>
  name.startsWith(SHELL_CACHE_PREFIX) ? name.slice(SHELL_CACHE_PREFIX.length) : null

/** Synthetic keys, never requested by the app and never served. */
export const COMPLETE_MARKER_PATH = "/__inline-sw/complete"
export const CLIENT_BUILDS_PATH = "/__inline-sw/client-builds"

// ---------------------------------------------------------------------------
// Messages

/** Page to worker. */
export type PageMessage =
  /** The user chose to update: the waiting worker takes over. */
  | { readonly type: "inline-sw:skip-waiting" }
  /** This window runs `buildId`; its files must stay cached while it lives. */
  | { readonly type: "inline-sw:hello"; readonly buildId: string }
  /** Which build are you? Answered with `inline-sw:build` to the asking window. */
  | { readonly type: "inline-sw:which-build" }

/** Worker to page. */
export type WorkerMessage = { readonly type: "inline-sw:build"; readonly buildId: string }

export const isPageMessage = (data: unknown): data is PageMessage => {
  if (typeof data !== "object" || data === null) return false
  const type = (data as { type?: unknown }).type
  if (type === "inline-sw:skip-waiting" || type === "inline-sw:which-build") return true
  return type === "inline-sw:hello" && typeof (data as { buildId?: unknown }).buildId === "string"
}

export const isWorkerMessage = (data: unknown): data is WorkerMessage =>
  typeof data === "object" &&
  data !== null &&
  (data as { type?: unknown }).type === "inline-sw:build" &&
  typeof (data as { buildId?: unknown }).buildId === "string"

/** Lowercase hex of the first 8 bytes: the revision format of `PrecacheEntry`. */
export const revisionOf = (digest: ArrayBuffer): string =>
  Array.from(new Uint8Array(digest).subarray(0, 8), (byte) => byte.toString(16).padStart(2, "0")).join("")
