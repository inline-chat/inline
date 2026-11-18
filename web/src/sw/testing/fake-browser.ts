/**
 * A browser's service worker machinery, small enough to read: one
 * registration, its installing, waiting and active workers, windows with
 * controllers, fetch routing, messages both ways, and the lifecycle rules the
 * real worker depends on:
 *
 * - An installed worker waits while any window is controlled by the active
 *   one, unless it called `skipWaiting`.
 * - Activation moves every window the old worker controlled to the new one
 *   and fires `controllerchange` there.
 * - A failed install leaves the worker redundant and the registration as it was.
 * - A new script is installed only when its bytes differ (here: its config).
 *
 * Each worker runs the real `installServiceWorker` against a scope built from
 * the shared fake Cache Storage and network. Pages run the real
 * `registerServiceWorker` through `FakeWindow.env()`.
 */

import type { Clock } from "@inline/platform"
import type { ServiceWorkerPageEnv, PageEventType } from "../register"
import type { ServiceWorkerConfig } from "../protocol"
import { installServiceWorker, type ServiceWorkerHandle } from "../service-worker"
import type {
  ClientLike,
  ContainerLike,
  ContainerMessageEvent,
  ExtendableEventLike,
  FetchEventLike,
  MessageEventLike,
  RegistrationLike,
  ScriptUrl,
  ServiceWorkerLike,
  ServiceWorkerScopeLike,
  WorkerState,
} from "../types"
import { FakeCacheStorage } from "./fake-cache-storage"
import { FakeNetwork, TEST_ORIGIN } from "./fake-network"

type Listener = (event: never) => void

const displayUrl = (href: string): string => {
  const url = new URL(href)
  return url.origin === TEST_ORIGIN ? `${url.pathname}${url.search}` : href
}

export class FakeWorker {
  state: WorkerState = "parsed"
  skipWaitingCalled = false
  readonly listeners = new Map<string, Listener[]>()
  readonly handle: ServiceWorkerHandle
  readonly stateListeners = new Set<() => void>()

  constructor(
    readonly id: number,
    readonly config: ServiceWorkerConfig,
    scope: ServiceWorkerScopeLike,
  ) {
    this.handle = installServiceWorker(scope, config)
  }

  get buildId(): string {
    return this.config.buildId
  }

  setState(state: WorkerState): void {
    this.state = state
    for (const listener of Array.from(this.stateListeners)) listener()
  }
}

class Registration {
  installing: FakeWorker | null = null
  waiting: FakeWorker | null = null
  active: FakeWorker | null = null
  unregistered = false
  readonly updateFoundListeners = new Set<() => void>()
}

export interface OpenWindowOptions {
  readonly visible?: boolean
}

export class FakeBrowser {
  readonly network = new FakeNetwork()
  readonly caches = new FakeCacheStorage()
  readonly windows: FakeWindow[] = []
  /** Workers ever created, in order. */
  readonly workers: FakeWorker[] = []
  registration: Registration | null = null
  /**
   * For each request that reached a worker: `worker GET /x` when it answered
   * with `respondWith`, `network GET /x` when it left the request alone.
   */
  readonly handled: string[] = []
  /** When true, messages from pages to workers are lost (to test timeouts). */
  dropPageMessages = false
  private script: ServiceWorkerConfig | null = null
  private nextWindowId = 1
  private readonly inFlight = new Set<Promise<unknown>>()

  // -------------------------------------------------------------------------
  // Test controls

  /** What `/sw.js` serves from now on. */
  deployScript(config: ServiceWorkerConfig): void {
    this.script = config
  }

  /** Opens a tab at `path`: the navigation goes through the active worker if there is one. */
  async openWindow(path = "/", options: OpenWindowOptions = {}): Promise<FakeWindow> {
    const registration = this.liveRegistration()
    const controller = registration?.active ?? null
    const window = new FakeWindow(this, `w${this.nextWindowId++}`, new URL(path, TEST_ORIGIN).href, controller)
    window.visible = options.visible ?? true
    window.document = await window.navigate(path)
    this.windows.push(window)
    return window
  }

  /** Closes the tab. A waiting worker may activate. */
  async closeWindow(window: FakeWindow): Promise<void> {
    window.closed = true
    this.windows.splice(this.windows.indexOf(window), 1)
    await this.track(this.tryActivate())
    await this.settle()
  }

  /** A reload: the tab closes and a new client loads the same URL. */
  async reload(window: FakeWindow): Promise<FakeWindow> {
    const path = new URL(window.url).pathname
    await this.closeWindow(window)
    return this.openWindow(path, { visible: window.visible })
  }

  /** Waits until every pending event, message and background task is done. */
  async settle(): Promise<void> {
    for (let round = 0; round < 100; round++) {
      await new Promise<void>((resolve) => setImmediate(resolve))
      if (this.inFlight.size === 0) return
      await Promise.allSettled(Array.from(this.inFlight))
    }
    throw new Error("FakeBrowser did not settle")
  }

  track<T>(promise: Promise<T>): Promise<T> {
    const settled = promise.then(
      () => undefined,
      () => undefined,
    )
    this.inFlight.add(settled)
    void settled.then(() => this.inFlight.delete(settled))
    return promise
  }

  // -------------------------------------------------------------------------
  // Registration and lifecycle

  liveRegistration(): Registration | null {
    return this.registration && !this.registration.unregistered ? this.registration : null
  }

  async register(): Promise<Registration> {
    let registration = this.liveRegistration()
    if (!registration) {
      registration = new Registration()
      this.registration = registration
    }
    await this.softUpdate()
    return registration
  }

  /** Fetches `/sw.js`; installs it when it differs from the newest worker. */
  async softUpdate(): Promise<void> {
    const registration = this.liveRegistration()
    if (!registration) return
    const result = await this.network.fetch(`${TEST_ORIGIN}/sw.js`).catch(() => null)
    if (!result || !this.script) throw new TypeError("Failed to update the service worker")
    const newest = registration.installing ?? registration.waiting ?? registration.active
    if (newest && JSON.stringify(newest.config) === JSON.stringify(this.script)) return
    await this.install(registration, this.script)
  }

  private createWorker(config: ServiceWorkerConfig, registration: Registration): FakeWorker {
    let worker: FakeWorker | null = null
    const self = (): FakeWorker => {
      if (!worker) throw new Error("worker not constructed")
      return worker
    }
    const listeners = new Map<string, Listener[]>()
    const scope: ServiceWorkerScopeLike = {
      location: { origin: TEST_ORIGIN },
      caches: this.caches,
      clients: {
        matchAll: async (options) => {
          const type = options?.type ?? "window"
          if (type !== "window" && type !== "all") return []
          return this.windows
            .filter((window) => options?.includeUncontrolled === true || window.controller === self())
            .map((window) => window.clientFor(self()))
        },
        claim: async () => {
          for (const window of this.windows) {
            if (window.controller === self()) continue
            window.controller = self()
            window.fireControllerChange()
          }
        },
      },
      registration: {
        unregister: async () => {
          registration.unregistered = true
          return true
        },
      },
      crypto: globalThis.crypto,
      skipWaiting: async () => {
        self().skipWaitingCalled = true
        void this.track(this.tryActivate())
      },
      fetch: (request, init) => this.network.fetch(request, init),
      addEventListener: (type: string, listener: Listener) => {
        listeners.set(type, [...(listeners.get(type) ?? []), listener])
      },
    }
    worker = new FakeWorker(this.workers.length + 1, config, scope)
    for (const [type, list] of listeners) worker.listeners.set(type, list)
    this.workers.push(worker)
    return worker
  }

  private async install(registration: Registration, config: ServiceWorkerConfig): Promise<void> {
    const worker = this.createWorker(config, registration)
    if (registration.installing) registration.installing.setState("redundant")
    registration.installing = worker
    worker.setState("installing")
    for (const listener of Array.from(registration.updateFoundListeners)) listener()
    const ok = await this.dispatch(worker, "install", {})
    if (registration.installing !== worker) return
    registration.installing = null
    if (!ok) {
      worker.setState("redundant")
      return
    }
    if (registration.waiting) registration.waiting.setState("redundant")
    registration.waiting = worker
    worker.setState("installed")
    await this.tryActivate()
  }

  async tryActivate(): Promise<void> {
    const registration = this.registration
    const waiting = registration?.waiting
    if (!registration || !waiting) return
    const active = registration.active
    if (active?.state === "activating") return
    const inUse = active !== null && this.windows.some((window) => window.controller === active)
    if (inUse && !waiting.skipWaitingCalled) return
    registration.waiting = null
    registration.active = waiting
    if (active) active.setState("redundant")
    waiting.setState("activating")
    for (const window of this.windows) {
      if (active !== null && window.controller === active) {
        window.controller = waiting
        window.fireControllerChange()
      }
    }
    await this.dispatch(waiting, "activate", {})
    waiting.setState("activated")
  }

  /** Dispatches an extendable event and waits for its `waitUntil` promises. */
  async dispatch(worker: FakeWorker, type: string, fields: object): Promise<boolean> {
    const promises: Promise<unknown>[] = []
    const event = {
      ...fields,
      waitUntil: (promise: Promise<unknown>) => {
        promises.push(promise)
        void this.track(promise)
      },
    }
    for (const listener of worker.listeners.get(type) ?? []) (listener as (event: ExtendableEventLike) => void)(event)
    let ok = true
    for (let index = 0; index < promises.length; index++) {
      try {
        await promises[index]
      } catch {
        ok = false
      }
    }
    return ok
  }

  /** A request from `window` (or a new navigation when `window` is the one loading). */
  async fetchVia(controller: FakeWorker | null, url: string, init: RequestInit & { navigate?: boolean } = {}): Promise<Response> {
    const { navigate, ...requestInit } = init
    const request = new Request(new URL(url, TEST_ORIGIN), requestInit)
    if (navigate) Object.defineProperty(request, "mode", { value: "navigate" })
    if (!controller || controller.state === "redundant") return this.network.fetch(request)
    let response: Promise<Response> | null = null
    const event: FetchEventLike = {
      request,
      respondWith: (value) => {
        if (response) throw new Error("respondWith called twice")
        response = Promise.resolve(value)
      },
      waitUntil: (promise) => void this.track(promise),
    }
    for (const listener of controller.listeners.get("fetch") ?? []) (listener as (event: FetchEventLike) => void)(event)
    const answered = response as Promise<Response> | null
    this.handled.push(`${answered ? "worker" : "network"} ${request.method} ${displayUrl(request.url)}`)
    return answered ?? this.network.fetch(request)
  }

  postToWorker(worker: FakeWorker, data: unknown, source: ClientLike): void {
    if (this.dropPageMessages || worker.state === "redundant") return
    const fields: Omit<MessageEventLike, "waitUntil"> = { data, source }
    void this.track(this.dispatch(worker, "message", fields))
  }
}

export class FakeWindow {
  visible = true
  closed = false
  document = ""
  /** Times the page asked to reload. */
  reloadRequests = 0
  /** Script URLs passed to `register`. */
  readonly registeredScripts: ScriptUrl[] = []
  private readonly pageListeners = new Map<PageEventType, Set<(event: { readonly persisted?: boolean }) => void>>()
  private readonly controllerChangeListeners = new Set<() => void>()
  private readonly messageListeners = new Set<(event: ContainerMessageEvent) => void>()
  private readonly views = new Map<FakeWorker, ServiceWorkerLike>()
  private readonly clients = new Map<FakeWorker, ClientLike>()

  constructor(
    readonly browser: FakeBrowser,
    readonly id: string,
    readonly url: string,
    public controller: FakeWorker | null,
  ) {}

  /** Loads a document the way a navigation does. */
  async navigate(path: string): Promise<string> {
    const response = await this.browser.fetchVia(this.controller, path, { navigate: true })
    return response.ok ? response.text() : `HTTP ${response.status}`
  }

  /** A subresource request from this page. */
  fetch(url: string, init: RequestInit = {}): Promise<Response> {
    return this.browser.fetchVia(this.controller, url, init)
  }

  /** Fetches and returns the body, or throws on a network error. */
  async text(url: string): Promise<string> {
    const response = await this.fetch(url)
    return response.ok ? response.text() : `HTTP ${response.status}`
  }

  emit(type: PageEventType, event: { readonly persisted?: boolean } = {}): void {
    for (const listener of Array.from(this.pageListeners.get(type) ?? [])) listener(event)
  }

  setVisible(visible: boolean): void {
    this.visible = visible
    this.emit("visibilitychange")
  }

  /** The page side of a worker, one object per worker per window, like the browser's. */
  viewOf(worker: FakeWorker | null): ServiceWorkerLike | null {
    if (!worker) return null
    let view = this.views.get(worker)
    if (!view) {
      const listeners = new Map<() => void, () => void>()
      view = {
        scriptURL: `${TEST_ORIGIN}/sw.js`,
        get state() {
          return worker.state
        },
        postMessage: (message) => this.browser.postToWorker(worker, message, this.clientFor(worker)),
        addEventListener: (_type, listener) => {
          const wrapped = (): void => listener()
          listeners.set(listener, wrapped)
          worker.stateListeners.add(wrapped)
        },
        removeEventListener: (_type, listener) => {
          const wrapped = listeners.get(listener)
          if (wrapped) worker.stateListeners.delete(wrapped)
          listeners.delete(listener)
        },
      }
      this.views.set(worker, view)
    }
    return view
  }

  /** This window as `worker` sees it in `clients`. */
  clientFor(worker: FakeWorker): ClientLike {
    let client = this.clients.get(worker)
    if (!client) {
      client = {
        id: this.id,
        type: "window",
        url: this.url,
        postMessage: (message) => {
          const source = this.viewOf(worker)
          queueMicrotask(() => {
            if (this.closed) return
            for (const listener of Array.from(this.messageListeners)) listener({ data: message, source })
          })
        },
      }
      this.clients.set(worker, client)
    }
    return client
  }

  private self(): FakeWindow {
    return this
  }

  fireControllerChange(): void {
    for (const listener of Array.from(this.controllerChangeListeners)) listener()
  }

  private registrationView(): RegistrationLike {
    const browser = this.browser
    const view = (worker: FakeWorker | null | undefined): ServiceWorkerLike | null => this.viewOf(worker ?? null)
    const registration = browser.liveRegistration() ?? browser.registration
    return {
      scope: `${TEST_ORIGIN}/`,
      get installing() {
        return view(registration?.installing)
      },
      get waiting() {
        return view(registration?.waiting)
      },
      get active() {
        return view(registration?.active)
      },
      update: () => browser.track(browser.softUpdate()),
      unregister: async () => {
        if (registration) registration.unregistered = true
        return true
      },
      addEventListener: (_type, listener) => void registration?.updateFoundListeners.add(listener),
      removeEventListener: (_type, listener) => void registration?.updateFoundListeners.delete(listener),
    }
  }

  /** The env `registerServiceWorker` gets in this window. */
  env(clock: Clock, overrides: Partial<ServiceWorkerPageEnv> = {}): ServiceWorkerPageEnv {
    const window = this.self()
    const browser = this.browser
    const controller = (): ServiceWorkerLike | null => this.viewOf(this.controller)
    const container: ContainerLike = {
      get controller() {
        return controller()
      },
      register: async (scriptUrl) => {
        window.registeredScripts.push(scriptUrl)
        await browser.track(browser.register())
        return window.registrationView()
      },
      getRegistrations: async () => (browser.liveRegistration() ? [window.registrationView()] : []),
      addEventListener: (type: "controllerchange" | "message", listener: Listener) => {
        if (type === "controllerchange") window.controllerChangeListeners.add(listener as () => void)
        else window.messageListeners.add(listener as (event: ContainerMessageEvent) => void)
      },
      removeEventListener: (type: "controllerchange" | "message", listener: Listener) => {
        if (type === "controllerchange") window.controllerChangeListeners.delete(listener as () => void)
        else window.messageListeners.delete(listener as (event: ContainerMessageEvent) => void)
      },
    }
    return {
      container,
      caches: browser.caches,
      secureContext: true,
      clock,
      isVisible: () => window.visible,
      reload: () => {
        window.reloadRequests++
      },
      listen: (type, listener) => {
        let set = window.pageListeners.get(type)
        if (!set) {
          set = new Set()
          window.pageListeners.set(type, set)
        }
        set.add(listener)
        return () => set.delete(listener)
      },
      afterLoad: (fn) => {
        fn()
        return () => undefined
      },
      scriptUrl: (path) => path,
      ...overrides,
    }
  }
}
