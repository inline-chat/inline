/**
 * Page side of the service worker: registration, update detection, applying
 * an update, and the hooks for sign-out and the kill switch.
 *
 * Framework-free. State goes to an `UpdateFeed` from `@inline/platform`
 * (`none`, `available` while a new build downloads, `ready` when it waits or
 * another tab already switched to it), and to `subscribe` listeners for the
 * lab. Browser objects are injected through `env`, so all of it runs in Node
 * against the fakes in `testing/`.
 *
 * Update policy (README, "Updates"):
 * - A new worker waits. This tab never swaps code on its own.
 * - `applyUpdate()` (the user chose to update) tells the waiting worker to
 *   take over and reloads this tab once it controls the page.
 * - When another tab applied the update, this tab keeps running its build and
 *   reports `ready`; `apply` then just reloads. It reloads by itself only while
 *   hidden and only when `hasUnsavedWork()` says there is nothing to lose. A
 *   visible tab is never reloaded without the user.
 * - The first install takes control of the page without a reload.
 */

import type { Clock, UpdateFeed, UpdateState } from "@inline/platform"
import { CACHE_PREFIX, isWorkerMessage, type PageMessage } from "./protocol"
import { trustedScriptUrl } from "./trusted-script-url"
import type {
  ContainerLike,
  ContainerMessageEvent,
  PageCachesLike,
  RegistrationLike,
  ScriptUrl,
  ServiceWorkerLike,
} from "./types"

export type PageEventType = "focus" | "online" | "visibilitychange" | "pageshow"

/** The browser, injected. `browserEnv()` reads the globals when called. */
export interface ServiceWorkerPageEnv {
  /** `navigator.serviceWorker`, or undefined where there is none. */
  readonly container: ContainerLike | undefined
  readonly caches: PageCachesLike | undefined
  readonly secureContext: boolean
  readonly clock: Clock
  isVisible(): boolean
  reload(): void
  listen(type: PageEventType, listener: (event: { readonly persisted?: boolean }) => void): () => void
  /** Runs `fn` once the page has loaded, so registration does not compete with the first load. */
  afterLoad(fn: () => void): () => void
  /** Turns the script path into what `register` accepts under Trusted Types. */
  scriptUrl(path: string): ScriptUrl
}

export interface RegisterServiceWorkerOptions {
  /** `import.meta.env.PROD` (and not Electron). When false, an existing registration is removed. */
  readonly enabled: boolean
  /** This page's build: `__INLINE_BUILD_ID__`. Must equal the plugin's `buildId`. */
  readonly buildId: string
  readonly feed?: UpdateFeed
  /**
   * Whether reloading this tab now could lose something the user did. Asked
   * before an automatic reload; without it the tab never reloads by itself.
   */
  readonly hasUnsavedWork?: () => boolean
  /** Default `/sw.js`. */
  readonly scriptPath?: string
  /** Default `/`. */
  readonly scope?: string
  /** Periodic update check. Default 60 minutes. */
  readonly checkIntervalMs?: number
  /** Focus, visibility and online checks are skipped within this long of the last one. Default 5 minutes. */
  readonly minCheckGapMs?: number
  /** After `applyUpdate`, reload anyway if the new worker has not taken over by then. Default 10 s. */
  readonly applyTimeoutMs?: number
  readonly onError?: (error: unknown) => void
  readonly env?: ServiceWorkerPageEnv
}

export type ServiceWorkerPhase = "disabled" | "unsupported" | "registering" | "registered" | "failed"

/**
 * - `installing`: a new build is downloading (`update: available`).
 * - `waiting`: it is installed and waits for this tab or another to apply it (`ready`).
 * - `activated-elsewhere`: another tab applied it; this tab runs the old build (`ready`).
 */
export type PendingUpdate = "none" | "installing" | "waiting" | "activated-elsewhere"

export interface ServiceWorkerStatus {
  readonly phase: ServiceWorkerPhase
  readonly update: UpdateState
  readonly pending: PendingUpdate
  /** Whether a service worker controls this page. */
  readonly controlled: boolean
  readonly error?: string
}

export interface ServiceWorkerController {
  status(): ServiceWorkerStatus
  subscribe(listener: (status: ServiceWorkerStatus) => void): () => void
  /** Asks the browser to look for a new `/sw.js`. Network errors are ignored. */
  checkForUpdate(): Promise<void>
  /** The user chose to update. Does nothing unless `update` is `ready`. */
  applyUpdate(): void
  /** Sign-out: deletes every cache the service worker owns. */
  clearCaches(): Promise<void>
  /** Unregisters and deletes the caches. Open tabs keep their code until reload. */
  unregister(): Promise<void>
  dispose(): void
}

const NONE: UpdateState = { status: "none" }
const MINUTE = 60_000

/**
 * Deletes every cache the service worker owns (`inline-sw-*`), from the page,
 * whether or not a worker runs. The security guide's sign-out list includes
 * them. Nothing else in Cache Storage is touched.
 */
export const clearServiceWorkerCaches = async (caches: PageCachesLike | undefined): Promise<string[]> => {
  if (!caches) return []
  const names = (await caches.keys()).filter((name) => name.startsWith(CACHE_PREFIX))
  await Promise.all(names.map((name) => caches.delete(name)))
  return names
}

export const registerServiceWorker = (options: RegisterServiceWorkerOptions): ServiceWorkerController => {
  const env = options.env ?? browserEnv()
  const scriptPath = options.scriptPath ?? "/sw.js"
  const scope = options.scope ?? "/"
  const checkIntervalMs = options.checkIntervalMs ?? 60 * MINUTE
  const minCheckGapMs = options.minCheckGapMs ?? 5 * MINUTE
  const applyTimeoutMs = options.applyTimeoutMs ?? 10_000
  const hasUnsavedWork = options.hasUnsavedWork ?? (() => true)
  const container = env.container

  const listeners = new Set<(status: ServiceWorkerStatus) => void>()
  const disposers: Array<() => void> = []
  let status: ServiceWorkerStatus = { phase: "registering", update: NONE, pending: "none", controlled: false }
  let disposed = false

  const set = (patch: Partial<ServiceWorkerStatus>): void => {
    status = { ...status, ...patch }
    options.feed?.report(status.update)
    for (const listener of Array.from(listeners)) listener(status)
  }

  const fail = (error: unknown): void => {
    options.onError?.(error)
    set({ phase: "failed", error: error instanceof Error ? error.message : String(error) })
  }

  const matchesScript = (worker: ServiceWorkerLike | null): boolean => {
    if (!worker) return false
    try {
      return new URL(worker.scriptURL).pathname === scriptPath
    } catch {
      return false
    }
  }

  const removeExisting = async (): Promise<void> => {
    if (!container) return
    const registrations = await container.getRegistrations()
    for (const registration of registrations) {
      if ([registration.active, registration.waiting, registration.installing].some(matchesScript)) {
        await registration.unregister()
      }
    }
    await clearServiceWorkerCaches(env.caches)
  }

  const controller: ServiceWorkerController = {
    status: () => status,
    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    checkForUpdate: async () => undefined,
    applyUpdate: () => undefined,
    clearCaches: async () => {
      await clearServiceWorkerCaches(env.caches)
    },
    unregister: async () => {
      await removeExisting()
    },
    dispose() {
      disposed = true
      for (const dispose of disposers.splice(0)) dispose()
      listeners.clear()
    },
  }

  if (!options.enabled) {
    set({ phase: "disabled" })
    // A worker left from a production build on this origin (`vite preview`
    // shares the dev port) or an app-side kill switch: remove it.
    if (container && env.secureContext) disposers.push(env.afterLoad(() => void removeExisting().catch(fail)))
    return controller
  }
  if (!container || !env.secureContext) {
    set({ phase: "unsupported" })
    return controller
  }

  let registration: RegistrationLike | null = null
  let hadController = container.controller !== null
  let pending: PendingUpdate = "none"
  let pendingVersion: string | undefined
  let applying = false
  let lastCheck = Number.NEGATIVE_INFINITY
  let checkTimer: unknown = null
  let applyTimer: unknown = null
  const tracked = new Set<ServiceWorkerLike>()

  const send = (worker: ServiceWorkerLike | null | undefined, message: PageMessage): void => {
    try {
      worker?.postMessage(message)
    } catch (error) {
      options.onError?.(error)
    }
  }

  const updateState = (): UpdateState => {
    const version = pendingVersion === undefined ? {} : { version: pendingVersion }
    switch (pending) {
      case "none":
        return NONE
      case "installing":
        return { status: "available", ...version }
      case "waiting":
      case "activated-elsewhere":
        return { status: "ready", ...version }
    }
  }

  const publish = (): void => set({ pending, update: updateState(), controlled: container.controller !== null })

  /** Recomputes the pending update from the registration. */
  const refresh = (): void => {
    if (!registration || pending === "activated-elsewhere") {
      publish()
      return
    }
    // Before any worker controlled this page there is nothing to update from:
    // the first install is not an update.
    if (hadController && registration.waiting) {
      if (pending !== "waiting" && pendingVersion === undefined) {
        send(registration.waiting, { type: "inline-sw:which-build" })
      }
      pending = "waiting"
    } else if (hadController && registration.installing) {
      pending = "installing"
    } else {
      // Also the moment between the waiting worker activating and the
      // controller change; the version is kept for that.
      pending = "none"
    }
    publish()
  }

  const track = (worker: ServiceWorkerLike | null): void => {
    if (!worker || tracked.has(worker)) return
    tracked.add(worker)
    const onState = (): void => {
      if (worker.state === "redundant" || worker.state === "activated") {
        worker.removeEventListener("statechange", onState)
        tracked.delete(worker)
      }
      refresh()
    }
    worker.addEventListener("statechange", onState)
    disposers.push(() => worker.removeEventListener("statechange", onState))
  }

  /** Tells the worker that serves this page which build it runs, so its files stay cached. */
  const hello = (): void => {
    send(container.controller ?? registration?.active, { type: "inline-sw:hello", buildId: options.buildId })
  }

  const reloadIfHiddenAndIdle = (): void => {
    if (pending !== "activated-elsewhere" || env.isVisible()) return
    if (hasUnsavedWork()) return
    env.reload()
  }

  const schedule = (): void => {
    if (checkTimer !== null) env.clock.clearTimeout(checkTimer)
    checkTimer = env.clock.setTimeout(() => {
      checkTimer = null
      void controller.checkForUpdate()
    }, checkIntervalMs)
  }

  controller.checkForUpdate = async () => {
    if (!registration || disposed) return
    lastCheck = env.clock.now()
    schedule()
    try {
      await registration.update()
    } catch {
      // Offline, or the script failed to download: try again later.
    }
  }

  const checkIfDue = (): void => {
    if (env.clock.now() - lastCheck >= minCheckGapMs) void controller.checkForUpdate()
  }

  controller.applyUpdate = () => {
    if (status.update.status !== "ready" || applying) return
    const waiting = registration?.waiting
    if (pending === "activated-elsewhere" || !waiting) {
      env.reload()
      return
    }
    applying = true
    send(waiting, { type: "inline-sw:skip-waiting" })
    applyTimer = env.clock.setTimeout(() => env.reload(), applyTimeoutMs)
  }

  const onControllerChange = (): void => {
    if (!hadController) {
      // The first install claimed this page. Same build, nothing to reload.
      hadController = true
      hello()
      refresh()
      return
    }
    if (applying) {
      if (applyTimer !== null) env.clock.clearTimeout(applyTimer)
      env.reload()
      return
    }
    // Another tab applied the update, or a kill switch took over. This tab
    // keeps its build; the new worker learns which one, so its files stay.
    pending = "activated-elsewhere"
    hello()
    if (pendingVersion === undefined) send(container.controller, { type: "inline-sw:which-build" })
    publish()
    reloadIfHiddenAndIdle()
  }

  const onMessage = (event: ContainerMessageEvent): void => {
    if (!isWorkerMessage(event.data) || event.data.buildId === options.buildId) return
    pendingVersion = event.data.buildId
    if (pending !== "none") publish()
  }

  const onUpdateFound = (): void => {
    pendingVersion = undefined
    track(registration?.installing ?? null)
    refresh()
  }

  const start = async (): Promise<void> => {
    try {
      registration = await container.register(env.scriptUrl(scriptPath), { scope, updateViaCache: "none" })
    } catch (error) {
      fail(error)
      return
    }
    if (disposed) return
    const current = registration
    current.addEventListener("updatefound", onUpdateFound)
    disposers.push(() => current.removeEventListener("updatefound", onUpdateFound))
    track(current.installing)
    track(current.waiting)
    set({ phase: "registered" })
    refresh()
    hello()
    // Registering already looked for a new script.
    lastCheck = env.clock.now()
    schedule()
  }

  options.feed?.setApplyHandler(() => controller.applyUpdate())
  container.addEventListener("controllerchange", onControllerChange)
  container.addEventListener("message", onMessage)
  disposers.push(
    () => container.removeEventListener("controllerchange", onControllerChange),
    () => container.removeEventListener("message", onMessage),
    () => options.feed?.setApplyHandler(null),
    () => {
      if (checkTimer !== null) env.clock.clearTimeout(checkTimer)
      if (applyTimer !== null) env.clock.clearTimeout(applyTimer)
    },
    env.listen("focus", checkIfDue),
    env.listen("online", checkIfDue),
    env.listen("visibilitychange", () => {
      if (env.isVisible()) checkIfDue()
      else reloadIfHiddenAndIdle()
    }),
    env.listen("pageshow", (event) => {
      // Back from the back-forward cache: the worker may have changed meanwhile.
      if (!event.persisted) return
      hello()
      checkIfDue()
    }),
    env.afterLoad(() => void start()),
  )
  set({ controlled: container.controller !== null })
  return controller
}

// ---------------------------------------------------------------------------
// Browser globals, read when called.

export const browserEnv = (): ServiceWorkerPageEnv => {
  const nav = globalThis.navigator as (Navigator & { serviceWorker?: unknown }) | undefined
  const container = nav && "serviceWorker" in nav ? (nav.serviceWorker as unknown as ContainerLike) : undefined
  return {
    container,
    caches: (globalThis as { caches?: PageCachesLike }).caches,
    secureContext: globalThis.isSecureContext === true,
    clock: {
      now: () => Date.now(),
      setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
      clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
    },
    isVisible: () => document.visibilityState === "visible",
    reload: () => location.reload(),
    listen(type, listener) {
      const target: EventTarget = type === "visibilitychange" ? document : window
      const handler = (event: Event): void => listener({ persisted: (event as PageTransitionEvent).persisted })
      target.addEventListener(type, handler)
      return () => target.removeEventListener(type, handler)
    },
    afterLoad(fn) {
      if (document.readyState === "complete") {
        let cancelled = false
        queueMicrotask(() => {
          if (!cancelled) fn()
        })
        return () => {
          cancelled = true
        }
      }
      window.addEventListener("load", fn, { once: true })
      return () => window.removeEventListener("load", fn)
    },
    scriptUrl: (path) => trustedScriptUrl(path),
  }
}
