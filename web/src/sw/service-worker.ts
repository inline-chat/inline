/**
 * The service worker: precaches one build's shell, serves it offline, and
 * never swaps code under a running tab.
 *
 * - install: downloads the whole manifest into memory, checks every file's
 *   revision, then writes the build's cache. A failure leaves no cache. It does
 *   not call `skipWaiting`.
 * - activate: happens when no window uses the previous worker, or when a page
 *   sends `inline-sw:skip-waiting` after the user chose to update. Prunes old
 *   caches no living window needs, then claims uncontrolled windows.
 * - fetch: precached files cache-first; app navigations get the shell; files
 *   of other builds still cached are served to the old tabs that ask for them;
 *   everything else is not touched (no `respondWith`).
 * - integrity: Cache Storage is writable by any script on the origin, so a
 *   cached copy of this build's shell or files is served only when its bytes
 *   still match the manifest's revision (checked on every response; about
 *   0.4 ms per MB). On a mismatch the cache is dropped and rebuilt and the
 *   request goes to the network. The shell is served with the build's content
 *   policy as a header too (`shellPolicy`).
 *
 * Imports nothing outside this directory: the build checks the bundle for it.
 */

import {
  CLIENT_BUILDS_PATH,
  COMPLETE_MARKER_PATH,
  CACHE_PREFIX,
  META_CACHE,
  buildIdOfCache,
  isPageMessage,
  revisionOf,
  shellCacheName,
  type PrecacheEntry,
  type ServiceWorkerConfig,
  type WorkerMessage,
} from "./protocol"
import type {
  ClientLike,
  ExtendableEventLike,
  FetchEventLike,
  MessageEventLike,
  ServiceWorkerScopeLike,
} from "./types"

export class PrecacheError extends Error {
  override readonly name = "PrecacheError"
}

export interface PruneResult {
  readonly deleted: readonly string[]
  readonly kept: readonly string[]
  /** A living window has not said which build it runs, so nothing was deleted. */
  readonly deferred: boolean
}

/** What tests and the entry point can reach; the browser only sees the listeners. */
export interface ServiceWorkerHandle {
  precache(): Promise<void>
  prune(): Promise<PruneResult>
}

/** Headers that describe the transfer, not the bytes we store. */
const TRANSFER_HEADERS = ["content-encoding", "content-length", "transfer-encoding", "set-cookie"]

const noop = (): void => undefined

const cleanHeaders = (headers: Headers): Headers => {
  const next = new Headers(headers)
  for (const name of TRANSFER_HEADERS) next.delete(name)
  return next
}

const isClient = (source: unknown): source is ClientLike =>
  typeof source === "object" &&
  source !== null &&
  typeof (source as { id?: unknown }).id === "string" &&
  typeof (source as { postMessage?: unknown }).postMessage === "function"

/** App routes never contain a dot (see `packages/view/src/workspace/url.ts`); files do. */
const looksLikeFile = (pathname: string): boolean => {
  const last = pathname.slice(pathname.lastIndexOf("/") + 1)
  return last.includes(".") && last !== "index.html"
}

export const installServiceWorker = (
  scope: ServiceWorkerScopeLike,
  config: ServiceWorkerConfig,
): ServiceWorkerHandle => {
  const origin = scope.location.origin
  const own = shellCacheName(config.buildId)
  const absolute = (path: string): string => new URL(path, origin).href
  const shellUrl = absolute(config.shell.url)
  const markerUrl = absolute(COMPLETE_MARKER_PATH)
  const recordUrl = absolute(CLIENT_BUILDS_PATH)
  const assetPaths = new Set(config.assets.map((entry) => new URL(entry.url, origin).pathname))
  /** Expected revision per absolute URL: the shell and this build's files. */
  const revisions = new Map<string, string>([
    [shellUrl, config.shell.revision],
    ...config.assets.map((entry) => [absolute(entry.url), entry.revision] as const),
  ])

  // -------------------------------------------------------------------------
  // Kill switch: take over at once, erase everything, leave.

  if (config.killSwitch) {
    scope.addEventListener("install", (event: ExtendableEventLike) => event.waitUntil(scope.skipWaiting()))
    scope.addEventListener("activate", (event: ExtendableEventLike) =>
      event.waitUntil(
        (async () => {
          await deleteOwnCaches()
          await scope.registration.unregister()
        })(),
      ),
    )
    // No fetch listener: every request of the windows it still controls goes
    // to the network as if there were no worker.
    return {
      precache: async () => undefined,
      prune: async () => ({ deleted: await deleteOwnCaches(), kept: [], deferred: false }),
    }
  }

  async function deleteOwnCaches(): Promise<string[]> {
    const names = (await scope.caches.keys()).filter((name) => name.startsWith(CACHE_PREFIX))
    await Promise.all(names.map((name) => scope.caches.delete(name)))
    return names
  }

  // -------------------------------------------------------------------------
  // Precache

  let precaching: Promise<void> | null = null

  const isComplete = async (): Promise<boolean> =>
    (await scope.caches.match(markerUrl, { cacheName: own })) !== undefined

  const download = async (entry: PrecacheEntry, fresh: boolean): Promise<Response> => {
    const response = await scope.fetch(
      new Request(absolute(entry.url), { cache: fresh ? "no-cache" : "default", credentials: "same-origin" }),
    )
    if (!response.ok) throw new PrecacheError(`${entry.url}: HTTP ${response.status}`)
    const bytes = await response.arrayBuffer()
    const revision = revisionOf(await scope.crypto.subtle.digest("SHA-256", bytes))
    if (revision !== entry.revision) {
      throw new PrecacheError(`${entry.url}: expected revision ${entry.revision}, got ${revision}`)
    }
    // A fresh response: no redirect flag (a redirected response cannot answer
    // a navigation) and no transfer headers that no longer describe the body.
    return new Response(bytes, { status: 200, statusText: "OK", headers: cleanHeaders(response.headers) })
  }

  const fillCache = async (): Promise<void> => {
    if (await isComplete()) return
    // Leftovers of an interrupted install, or a cache cleared under us.
    await scope.caches.delete(own)
    // Everything is downloaded and checked before anything is written.
    const shell = download(config.shell, true)
    const assets = Promise.all(config.assets.map((entry) => download(entry, false)))
    const [shellResponse, assetResponses] = await Promise.all([shell, assets])
    const cache = await scope.caches.open(own)
    try {
      for (const [index, entry] of config.assets.entries()) {
        const response = assetResponses[index]
        if (response) await cache.put(absolute(entry.url), response)
      }
      // The shell goes in after its files, the marker last: a cache with a
      // shell has every file the shell needs.
      await cache.put(shellUrl, shellResponse)
      await cache.put(markerUrl, new Response(config.buildId))
    } catch (error) {
      await scope.caches.delete(own).catch(() => false)
      throw error
    }
  }

  const precache = (): Promise<void> => {
    precaching ??= fillCache().finally(() => {
      precaching = null
    })
    return precaching
  }

  // -------------------------------------------------------------------------
  // Which build each window runs, kept in the meta cache so it survives the
  // worker being stopped and is shared by the old and the new worker.

  let queue: Promise<unknown> = Promise.resolve()
  const serial = <T>(task: () => Promise<T>): Promise<T> => {
    const run = queue.then(task, task)
    queue = run.catch(noop)
    return run
  }

  const readRecord = async (): Promise<Record<string, string>> => {
    const response = await scope.caches.match(recordUrl, { cacheName: META_CACHE })
    if (!response) return {}
    try {
      const data: unknown = await response.json()
      if (typeof data !== "object" || data === null) return {}
      const record: Record<string, string> = {}
      for (const [id, build] of Object.entries(data)) if (typeof build === "string") record[id] = build
      return record
    } catch {
      return {}
    }
  }

  const writeRecord = async (record: Record<string, string>): Promise<void> => {
    const cache = await scope.caches.open(META_CACHE)
    await cache.put(
      recordUrl,
      new Response(JSON.stringify(record), { headers: { "content-type": "application/json" } }),
    )
  }

  const recordWindow = (clientId: string, buildId: string): Promise<void> =>
    serial(async () => {
      const record = await readRecord()
      if (record[clientId] === buildId) return
      record[clientId] = buildId
      await writeRecord(record)
    })

  /**
   * Deletes the caches of builds no living window runs. Never deletes this
   * build's cache or a newer build's (a waiting or installing worker's), and
   * deletes nothing while a living window has not said which build it runs.
   */
  const prune = (): Promise<PruneResult> =>
    serial(async () => {
      const windows = await scope.clients.matchAll({ type: "window", includeUncontrolled: true })
      const alive = new Set(windows.map((client) => client.id))
      const recorded = await readRecord()
      const live: Record<string, string> = {}
      for (const [id, build] of Object.entries(recorded)) if (alive.has(id)) live[id] = build
      if (Object.keys(live).length !== Object.keys(recorded).length) await writeRecord(live)

      const names = (await scope.caches.keys()).filter((name) => buildIdOfCache(name) !== null)
      if (windows.some((client) => live[client.id] === undefined)) {
        return { deleted: [], kept: names, deferred: true }
      }
      const needed = new Set([config.buildId, ...Object.values(live)])
      const deleted: string[] = []
      const kept: string[] = []
      for (const name of names) {
        const build = buildIdOfCache(name) ?? ""
        if (needed.has(build) || build > config.buildId) {
          kept.push(name)
        } else {
          await scope.caches.delete(name)
          deleted.push(name)
        }
      }
      return { deleted, kept, deferred: false }
    })

  // -------------------------------------------------------------------------
  // Serving

  const matchOtherBuilds = async (url: string): Promise<Response | undefined> => {
    const names = (await scope.caches.keys())
      .filter((name) => name !== own && buildIdOfCache(name) !== null)
      .sort()
      .reverse()
    for (const name of names) {
      const hit = await scope.caches.match(url, { cacheName: name })
      if (hit) return hit
    }
    return undefined
  }

  const heal = (event: ExtendableEventLike): void => {
    event.waitUntil(precache().catch(noop))
  }

  /**
   * The cached response when its bytes match the manifest, rebuilt with the
   * extra headers; undefined when they do not (planted, or corrupted).
   */
  const verified = async (url: string, cached: Response, extraPolicy?: string): Promise<Response | undefined> => {
    const expected = revisions.get(url)
    if (expected === undefined) return undefined
    const bytes = await cached.arrayBuffer()
    if (revisionOf(await scope.crypto.subtle.digest("SHA-256", bytes)) !== expected) return undefined
    const headers = new Headers(cached.headers)
    // Appended, not set: a policy the host sent stays, and both are enforced.
    if (extraPolicy && !(headers.get("content-security-policy") ?? "").includes(extraPolicy)) {
      headers.append("content-security-policy", extraPolicy)
    }
    return new Response(bytes, { status: cached.status, statusText: cached.statusText, headers })
  }

  /** A cached file failed its check: drop this build's cache and rebuild it from the network. */
  const discard = async (event: ExtendableEventLike): Promise<void> => {
    await scope.caches.delete(own).catch(() => false)
    heal(event)
  }

  const serveShell = async (event: FetchEventLike): Promise<Response> => {
    const cached = await scope.caches.match(shellUrl, { cacheName: own })
    if (cached) {
      const checked = await verified(shellUrl, cached, config.shellPolicy)
      if (checked) return checked
      await discard(event)
    } else {
      // This build's cache is gone (cleared at sign-out) or incomplete.
      heal(event)
    }
    // No other build's shell stands in: this worker cannot check those bytes,
    // and a cache with any name can be created by script on the origin.
    return scope.fetch(event.request)
  }

  const serveAsset = async (event: FetchEventLike, url: string, ownFile: boolean): Promise<Response> => {
    const cached = await scope.caches.match(url, { cacheName: own })
    if (cached && ownFile) {
      const checked = await verified(url, cached)
      if (checked) return checked
      await discard(event)
      return scope.fetch(event.request)
    }
    if (cached) return cached
    if (ownFile) heal(event)
    // An old tab asking for its build's files after an update, or a cache
    // being refilled: another build may still hold the file.
    return (await matchOtherBuilds(url)) ?? scope.fetch(event.request)
  }

  const onFetch = (event: FetchEventLike): void => {
    const { request } = event
    if (request.method !== "GET") return
    const url = new URL(request.url)
    if (url.origin !== origin) return
    if (request.mode === "navigate") {
      if (looksLikeFile(url.pathname)) return
      if (config.navigationDenylist.some((prefix) => url.pathname.startsWith(prefix))) return
      event.respondWith(serveShell(event))
      return
    }
    if (url.search !== "" || request.headers.has("range")) return
    if (assetPaths.has(url.pathname)) {
      event.respondWith(serveAsset(event, absolute(url.pathname), true))
    } else if (url.pathname.startsWith(config.assetsPath)) {
      event.respondWith(serveAsset(event, absolute(url.pathname), false))
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle and messages

  const announce = async (): Promise<void> => {
    const message: WorkerMessage = { type: "inline-sw:build", buildId: config.buildId }
    const windows = await scope.clients.matchAll({ type: "window", includeUncontrolled: true })
    for (const client of windows) client.postMessage(message)
  }

  scope.addEventListener("install", (event: ExtendableEventLike) =>
    event.waitUntil(precache().then(() => announce())),
  )

  scope.addEventListener("activate", (event: ExtendableEventLike) =>
    event.waitUntil(
      (async () => {
        await prune().catch(noop)
        // Only windows with no controller change hands here: the first
        // install's page, a hard-reloaded tab. Controlled windows already moved
        // with the activation.
        await scope.clients.claim()
      })(),
    ),
  )

  scope.addEventListener("fetch", onFetch)

  scope.addEventListener("message", (event: MessageEventLike) => {
    const { data, source } = event
    if (!isPageMessage(data)) return
    switch (data.type) {
      case "inline-sw:skip-waiting":
        event.waitUntil(scope.skipWaiting())
        return
      case "inline-sw:hello":
        if (isClient(source)) event.waitUntil(recordWindow(source.id, data.buildId).then(prune).catch(noop))
        return
      case "inline-sw:which-build":
        if (isClient(source)) source.postMessage({ type: "inline-sw:build", buildId: config.buildId } satisfies WorkerMessage)
        return
    }
  })

  return { precache, prune }
}
