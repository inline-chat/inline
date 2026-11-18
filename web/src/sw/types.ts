/**
 * The parts of the service worker global and of the page's
 * `navigator.serviceWorker` this module uses. The web app compiles against the
 * DOM library, which has no service worker global, and the tests run the same
 * code against fakes; both go through these shapes.
 */

// ---------------------------------------------------------------------------
// Worker side

export interface CacheLike {
  match(request: Request | string): Promise<Response | undefined>
  put(request: Request | string, response: Response): Promise<void>
  keys(): Promise<readonly Request[]>
}

export interface CacheStorageLike {
  /** With `cacheName`, looks in that cache only and never creates it. */
  match(request: Request | string, options?: { readonly cacheName?: string }): Promise<Response | undefined>
  open(name: string): Promise<CacheLike>
  has(name: string): Promise<boolean>
  delete(name: string): Promise<boolean>
  keys(): Promise<readonly string[]>
}

export interface ClientLike {
  readonly id: string
  readonly type: string
  readonly url: string
  postMessage(message: unknown): void
}

export interface ClientsLike {
  matchAll(options?: {
    readonly type?: "window" | "worker" | "sharedworker" | "all"
    readonly includeUncontrolled?: boolean
  }): Promise<readonly ClientLike[]>
  claim(): Promise<void>
}

export interface ExtendableEventLike {
  waitUntil(promise: Promise<unknown>): void
}

export interface FetchEventLike extends ExtendableEventLike {
  readonly request: Request
  respondWith(response: Response | Promise<Response>): void
}

export interface MessageEventLike extends ExtendableEventLike {
  readonly data: unknown
  /** The window or worker that sent it; `null` for a message from a worker. */
  readonly source: ClientLike | object | null
}

export interface ServiceWorkerScopeLike {
  readonly location: { readonly origin: string }
  readonly caches: CacheStorageLike
  readonly clients: ClientsLike
  readonly registration: { unregister(): Promise<boolean> }
  readonly crypto: { readonly subtle: { digest(algorithm: "SHA-256", data: ArrayBuffer): Promise<ArrayBuffer> } }
  skipWaiting(): Promise<void>
  fetch(request: Request | string, init?: RequestInit): Promise<Response>
  addEventListener(type: "install" | "activate", listener: (event: ExtendableEventLike) => void): void
  addEventListener(type: "fetch", listener: (event: FetchEventLike) => void): void
  addEventListener(type: "message", listener: (event: MessageEventLike) => void): void
}

// ---------------------------------------------------------------------------
// Page side

export type WorkerState = "parsed" | "installing" | "installed" | "activating" | "activated" | "redundant"

export interface ServiceWorkerLike {
  readonly scriptURL: string
  readonly state: WorkerState
  postMessage(message: unknown): void
  addEventListener(type: "statechange", listener: () => void): void
  removeEventListener(type: "statechange", listener: () => void): void
}

export interface RegistrationLike {
  readonly scope: string
  readonly installing: ServiceWorkerLike | null
  readonly waiting: ServiceWorkerLike | null
  readonly active: ServiceWorkerLike | null
  update(): Promise<unknown>
  unregister(): Promise<boolean>
  addEventListener(type: "updatefound", listener: () => void): void
  removeEventListener(type: "updatefound", listener: () => void): void
}

/** A Trusted Types `TrustedScriptURL`, or a plain string where Trusted Types do not exist. */
export type ScriptUrl = string | { toString(): string }

export interface ContainerMessageEvent {
  readonly data: unknown
  readonly source: unknown
}

export interface ContainerLike {
  readonly controller: ServiceWorkerLike | null
  register(
    scriptUrl: ScriptUrl,
    options: { readonly scope: string; readonly updateViaCache: "none" },
  ): Promise<RegistrationLike>
  getRegistrations(): Promise<readonly RegistrationLike[]>
  addEventListener(type: "controllerchange", listener: () => void): void
  addEventListener(type: "message", listener: (event: ContainerMessageEvent) => void): void
  removeEventListener(type: "controllerchange", listener: () => void): void
  removeEventListener(type: "message", listener: (event: ContainerMessageEvent) => void): void
}

export interface PageCachesLike {
  keys(): Promise<readonly string[]>
  delete(name: string): Promise<boolean>
}
