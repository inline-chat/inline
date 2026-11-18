/**
 * The worker carrier: the core protocol across a port.
 *
 * `serveCore` runs next to the core (in the dedicated worker). `connectCarrier`
 * runs in the UI context that started the worker and opens one `CoreEndpoint`
 * per UI context over the same port. Messages are the protocol's own plain
 * data in a small envelope; delivery order is the port's order.
 */

import type { Command, CoreEndpoint, CoreMessage, CoreMessageListener } from "@inline/core-protocol"
import { Log } from "@inline/log"
import { type CoreContexts, isCoreContexts, multiplexEndpoint } from "./multiplex"
import type { PortLike, PortMessageEvent } from "./platform"

const WIRE = 1

type ToCore =
  | { lk: typeof WIRE; t: "open"; ctx: string }
  | { lk: typeof WIRE; t: "cmd"; ctx: string; command: Command }
  | { lk: typeof WIRE; t: "close"; ctx: string }
  | { lk: typeof WIRE; t: "shutdown" }

type FromCore =
  | { lk: typeof WIRE; t: "msg"; ctx: string; message: CoreMessage }
  | { lk: typeof WIRE; t: "down" }
  | { lk: typeof WIRE; t: "failed"; reason: string }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

const isToCore = (value: unknown): value is ToCore => {
  if (!isRecord(value) || value.lk !== WIRE) return false
  switch (value.t) {
    case "open":
    case "close":
      return typeof value.ctx === "string"
    case "cmd":
      return typeof value.ctx === "string" && isRecord(value.command) && typeof value.command.kind === "string"
    case "shutdown":
      return true
    default:
      return false
  }
}

const isFromCore = (value: unknown): value is FromCore => {
  if (!isRecord(value) || value.lk !== WIRE) return false
  switch (value.t) {
    case "msg":
      return typeof value.ctx === "string" && isRecord(value.message) && typeof value.message.kind === "string"
    case "down":
      return true
    case "failed":
      return typeof value.reason === "string"
    default:
      return false
  }
}

/** What the UI side holds for a running core, wherever it runs. */
export interface CoreHandle {
  /** One UI context's endpoint on this core. */
  open(contextId: string): CoreEndpoint
  /** Called once if the core dies on its own (worker error, start failure). */
  onExit(listener: (reason: string) => void): () => void
  /** Closes every context and the core; resolves once the core reports it is down. */
  shutdown(): Promise<void>
  /** Stops the core now, without waiting for it. */
  terminate(): void
}

/** Starts the core for this account. In the browser it creates the dedicated worker. */
export type StartCore = () => CoreHandle

/** A core factory: one endpoint the multiplexer shares, or a host that opens contexts itself. */
export type CreateCore = () => CoreEndpoint | CoreContexts

const toContexts = (created: CoreEndpoint | CoreContexts, log: Log): CoreContexts =>
  isCoreContexts(created) ? created : multiplexEndpoint(created, { log })

// ---------------------------------------------------------------------------
// Core side

export type ServeCoreOptions = {
  log?: Log
}

export type ServedCore = {
  /** Stops serving and closes the core. */
  close(): Promise<void>
}

/**
 * Serves a core on a port: in a dedicated worker, `serveCore(self, createCore)`.
 * The core is created at once. A `shutdown` from the UI closes every context
 * and the core, answers `down`, and closes the port (which ends the worker).
 */
export const serveCore = (port: PortLike, createCore: CreateCore, options: ServeCoreOptions = {}): ServedCore => {
  const log = (options.log ?? new Log("Link")).withScope("Serve")
  const endpoints = new Map<string, { endpoint: CoreEndpoint; unsubscribe: () => void }>()
  let contexts: CoreContexts | undefined
  let stopped = false

  const send = (message: FromCore) => {
    try {
      port.postMessage(message)
    } catch (error) {
      log.error("post failed", { error })
    }
  }

  try {
    contexts = toContexts(createCore(), log)
  } catch (error) {
    log.error("core failed to start", { error })
    send({ lk: WIRE, t: "failed", reason: error instanceof Error ? error.message : "core failed to start" })
  }

  const closeContext = (ctx: string) => {
    const entry = endpoints.get(ctx)
    if (!entry) return
    endpoints.delete(ctx)
    entry.unsubscribe()
    void Promise.resolve(entry.endpoint.close()).catch((error: unknown) => log.warn("context close failed", { error }))
  }

  const stop = async () => {
    if (stopped) return
    stopped = true
    port.removeEventListener("message", onMessage)
    for (const ctx of Array.from(endpoints.keys())) closeContext(ctx)
    try {
      await contexts?.close()
    } catch (error) {
      log.error("core close failed", { error })
    }
  }

  const onMessage = (event: PortMessageEvent) => {
    const data = event.data
    if (!isToCore(data)) {
      log.warn("dropped malformed message")
      return
    }
    if (stopped) return
    switch (data.t) {
      case "open": {
        if (!contexts) return
        closeContext(data.ctx)
        const endpoint = contexts.open(data.ctx)
        const ctx = data.ctx
        const unsubscribe = endpoint.subscribe((message) => send({ lk: WIRE, t: "msg", ctx, message }))
        endpoints.set(ctx, { endpoint, unsubscribe })
        return
      }
      case "cmd": {
        const entry = endpoints.get(data.ctx)
        if (!entry) {
          log.warn("command for an unknown context")
          return
        }
        entry.endpoint.post(data.command)
        return
      }
      case "close":
        closeContext(data.ctx)
        return
      case "shutdown":
        void stop().then(() => {
          send({ lk: WIRE, t: "down" })
          port.close?.()
        })
        return
    }
  }

  port.addEventListener("message", onMessage)
  port.start?.()

  return { close: stop }
}

// ---------------------------------------------------------------------------
// UI side

export type CarrierHandle = CoreHandle & {
  /** Reports the core as dead, for adapters that see a failure the port cannot (a worker error). */
  fail(reason: string): void
}

export type ConnectCarrierOptions = {
  log?: Log
  /** Called after shutdown or terminate; a worker adapter terminates the worker here. */
  onClosed?: () => void
}

/** The UI side of `serveCore`: opens contexts on the core across a port. */
export const connectCarrier = (port: PortLike, options: ConnectCarrierOptions = {}): CarrierHandle => {
  const log = (options.log ?? new Log("Link")).withScope("Carrier")
  const contexts = new Map<string, Set<CoreMessageListener>>()
  const exitListeners = new Set<(reason: string) => void>()
  const downWaiters: (() => void)[] = []
  let state: "running" | "shuttingDown" | "closed" = "running"

  const send = (message: ToCore) => {
    if (state === "closed") return
    try {
      port.postMessage(message)
    } catch (error) {
      log.error("post failed", { error })
    }
  }

  const finish = () => {
    if (state === "closed") return
    state = "closed"
    port.removeEventListener("message", onMessage)
    contexts.clear()
    for (const resolve of downWaiters.splice(0)) resolve()
    try {
      port.close?.()
    } finally {
      options.onClosed?.()
    }
  }

  const fail = (reason: string) => {
    if (state === "closed") return
    const wasRunning = state === "running"
    finish()
    if (!wasRunning) return
    log.warn("core exited", { reason })
    for (const listener of Array.from(exitListeners)) listener(reason)
    exitListeners.clear()
  }

  const onMessage = (event: PortMessageEvent) => {
    const data = event.data
    if (!isFromCore(data)) {
      log.warn("dropped malformed message")
      return
    }
    switch (data.t) {
      case "msg": {
        const listeners = contexts.get(data.ctx)
        if (!listeners) return
        for (const listener of Array.from(listeners)) {
          try {
            listener(data.message)
          } catch (error) {
            log.error("listener threw", { error })
          }
        }
        return
      }
      case "down":
        finish()
        return
      case "failed":
        fail(data.reason)
        return
    }
  }

  port.addEventListener("message", onMessage)
  port.start?.()

  return {
    open(contextId) {
      const listeners = new Set<CoreMessageListener>()
      contexts.set(contextId, listeners)
      send({ lk: WIRE, t: "open", ctx: contextId })
      let open = true
      return {
        post(command) {
          if (!open) return
          send({ lk: WIRE, t: "cmd", ctx: contextId, command })
        },
        subscribe(listener) {
          listeners.add(listener)
          return () => {
            listeners.delete(listener)
          }
        },
        close() {
          if (!open) return
          open = false
          if (contexts.get(contextId) === listeners) contexts.delete(contextId)
          send({ lk: WIRE, t: "close", ctx: contextId })
        },
      }
    },
    onExit(listener) {
      exitListeners.add(listener)
      return () => {
        exitListeners.delete(listener)
      }
    },
    shutdown() {
      if (state === "closed") return Promise.resolve()
      const done = new Promise<void>((resolve) => downWaiters.push(resolve))
      if (state === "running") {
        state = "shuttingDown"
        send({ lk: WIRE, t: "shutdown" })
      }
      return done
    },
    terminate: finish,
    fail,
  }
}

// ---------------------------------------------------------------------------
// Adapters

/** The parts of `Worker` the adapter uses. */
export interface WorkerLike extends PortLike {
  addEventListener(type: "message", listener: (event: PortMessageEvent) => void): void
  addEventListener(type: "error", listener: (event: unknown) => void): void
  terminate(): void
}

/**
 * `StartCore` for a dedicated worker whose entry calls `serveCore(self, ...)`:
 *
 *     workerCore(() => new Worker(new URL("./core.worker.ts", import.meta.url), { type: "module" }))
 */
export const workerCore = (createWorker: () => WorkerLike, options: { log?: Log } = {}): StartCore => () => {
  const worker = createWorker()
  const port: PortLike = {
    postMessage: (message) => worker.postMessage(message),
    addEventListener: (type, listener) => worker.addEventListener(type, listener),
    removeEventListener: (type, listener) => worker.removeEventListener(type, listener),
  }
  const handle = connectCarrier(port, { ...options, onClosed: () => worker.terminate() })
  worker.addEventListener("error", () => handle.fail("worker error"))
  return handle
}

export type InProcessCore = CoreHandle & {
  /** Simulates the core dying on its own. */
  fail(reason: string): void
}

/**
 * `StartCore` for a core in this same context: tests, and hosts where the
 * core already lives in the leader (an Electron utility process, for one).
 */
export const inProcessCore = (createCore: CreateCore, options: { log?: Log } = {}): InProcessCore => {
  const log = options.log ?? new Log("Link")
  const contexts = toContexts(createCore(), log)
  const exitListeners = new Set<(reason: string) => void>()
  let state: "running" | "closed" = "running"
  let closing: Promise<void> | undefined

  const close = () => {
    if (!closing) {
      state = "closed"
      closing = Promise.resolve(contexts.close()).then(
        () => {},
        (error: unknown) => log.error("core close failed", { error }),
      )
    }
    return closing
  }

  return {
    open: (contextId) => contexts.open(contextId),
    onExit(listener) {
      exitListeners.add(listener)
      return () => {
        exitListeners.delete(listener)
      }
    },
    shutdown: close,
    terminate() {
      void close()
    },
    fail(reason) {
      if (state !== "running") return
      void close()
      for (const listener of Array.from(exitListeners)) listener(reason)
      exitListeners.clear()
    },
  }
}
