/**
 * Fixtures for the flow tests: a virtual clock, a scripted fetch that
 * answers by route and records requests, and in-memory storage. Not exported
 * from the package entry.
 */

import type { FetchLike } from "./api"
import type { Clock } from "./clock"
import type { KeyValueStorage } from "./device"

export const API_BASE = "https://api.test/v1"

// ---------------------------------------------------------------------------
// Clock

type Timer = { id: number; at: number; callback: () => void }

export class VirtualClock implements Clock {
  private current: number
  private timers: Timer[] = []
  private nextId = 1

  constructor(start = 1_800_000_000_000) {
    this.current = start
  }

  now = () => this.current

  setTimeout = (callback: () => void, ms: number) => {
    const timer = { id: this.nextId++, at: this.current + Math.max(0, ms), callback }
    this.timers.push(timer)
    return timer.id
  }

  clearTimeout = (handle: unknown) => {
    this.timers = this.timers.filter((timer) => timer.id !== handle)
  }

  get pendingTimers() {
    return this.timers.length
  }

  /** Moves time forward, running due timers in order, then settles promises. */
  async advance(ms: number) {
    const target = this.current + ms
    for (;;) {
      this.timers.sort((a, b) => a.at - b.at || a.id - b.id)
      const next = this.timers[0]
      if (!next || next.at > target) break
      this.timers.shift()
      this.current = next.at
      next.callback()
      await flushMicrotasks()
    }
    this.current = target
    await flushMicrotasks()
  }
}

/** Lets already-resolved promise chains run. Not a sleep: no time passes. */
export const flushMicrotasks = async (rounds = 50) => {
  for (let index = 0; index < rounds; index += 1) await Promise.resolve()
}

// ---------------------------------------------------------------------------
// Fetch

export type Reply =
  | { status: number; body?: unknown; headers?: Record<string, string> }
  | { network: true }

export type Held = {
  readonly kind: "held"
  resolve(reply: Reply): void
  readonly promise: Promise<Reply>
}

export const hold = (): Held => {
  let resolve!: (reply: Reply) => void
  const promise = new Promise<Reply>((next) => {
    resolve = next
  })
  return { kind: "held", resolve, promise }
}

export const ok = (result?: unknown): Reply =>
  result === undefined ? { status: 200, body: { ok: true } } : { status: 200, body: { ok: true, result } }

export const apiError = (
  status: number,
  error: string,
  headers?: Record<string, string>,
): Reply => ({
  status,
  body: { ok: false, error, errorCode: status, description: "Server description text" },
  ...(headers ? { headers } : {}),
})

export const networkFailure: Reply = { network: true }

export type RecordedRequest = {
  path: string
  method: string
  headers: Record<string, string>
  body: unknown
  credentials: RequestCredentials | undefined
}

export class ScriptedFetch {
  readonly requests: RecordedRequest[] = []
  private readonly routes = new Map<string, Array<Reply | Held>>()

  constructor(private readonly base = API_BASE) {}

  on(path: string, ...replies: Array<Reply | Held>) {
    const queue = this.routes.get(path) ?? []
    queue.push(...replies)
    this.routes.set(path, queue)
    return this
  }

  to(path: string) {
    return this.requests.filter((request) => request.path === path)
  }

  /** Requests whose reply was scripted but not consumed. */
  unconsumed() {
    return [...this.routes.entries()].filter(([, queue]) => queue.length > 0).map(([path]) => path)
  }

  fetch: FetchLike = async (url, init) => {
    if (!url.startsWith(this.base)) throw new Error(`Unexpected host: ${url}`)
    const path = url.slice(this.base.length)
    const headers: Record<string, string> = {}
    for (const [key, value] of Object.entries((init.headers ?? {}) as Record<string, string>)) {
      headers[key.toLowerCase()] = value
    }
    this.requests.push({
      path,
      method: init.method ?? "GET",
      headers,
      body: typeof init.body === "string" ? JSON.parse(init.body) : init.body,
      credentials: init.credentials,
    })
    const queue = this.routes.get(path)
    const next = queue?.shift()
    if (!next) throw new Error(`No scripted reply for ${path}`)

    const reply =
      "kind" in next
        ? await new Promise<Reply>((resolve, reject) => {
            init.signal?.addEventListener("abort", () =>
              reject(new DOMException("Aborted", "AbortError")),
            )
            void next.promise.then(resolve)
          })
        : next
    if ("network" in reply) throw new TypeError("Failed to fetch")
    return new Response(reply.body === undefined ? null : JSON.stringify(reply.body), {
      status: reply.status,
      headers: { "content-type": "application/json", ...reply.headers },
    })
  }
}

// ---------------------------------------------------------------------------
// Storage

export class MemoryStorage implements KeyValueStorage {
  readonly values = new Map<string, string>()
  failing = false

  getItem(key: string) {
    if (this.failing) throw new Error("storage unavailable")
    return this.values.get(key) ?? null
  }

  setItem(key: string, value: string) {
    if (this.failing) throw new Error("storage unavailable")
    this.values.set(key, value)
  }

  removeItem(key: string) {
    if (this.failing) throw new Error("storage unavailable")
    this.values.delete(key)
  }
}

// ---------------------------------------------------------------------------
// Payloads

export const user = (overrides: Record<string, unknown> = {}) => ({
  id: 42,
  firstName: "Ada",
  lastName: null,
  username: "ada",
  email: "ada@example.com",
  phoneNumber: null,
  pendingSetup: false,
  timeZone: "Europe/Berlin",
  date: 1_700_000_000,
  ...overrides,
})

export const SECRET_TOKEN = "42:tok-SECRET-session-value"

export const loginResult = (overrides: Record<string, unknown> = {}) => ({
  userId: 42,
  token: SECRET_TOKEN,
  user: user(overrides),
})
