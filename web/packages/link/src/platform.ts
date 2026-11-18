/**
 * The platform pieces link needs, behind small interfaces so every behavior
 * can run in Node against in-memory fakes (`@inline/link/testing`).
 *
 * The browser adapters at the bottom touch globals only when called.
 */

// ---------------------------------------------------------------------------
// Ports and channels

export type PortMessageEvent = { readonly data: unknown }
export type PortMessageListener = (event: PortMessageEvent) => void

/**
 * The minimal shape of anything that carries structured-cloneable messages in
 * order: a `Worker`, a `MessagePort`, a worker's global scope, a
 * `BroadcastChannel`, an Electron port, or a test fake.
 */
export interface PortLike {
  postMessage(message: unknown): void
  addEventListener(type: "message", listener: PortMessageListener): void
  removeEventListener(type: "message", listener: PortMessageListener): void
  /** `MessagePort` needs it when listening through `addEventListener`. */
  start?(): void
  close?(): void
}

/** A broadcast channel: every other open channel with the same name receives each message. */
export interface ChannelLike extends PortLike {
  close(): void
}

export type ChannelFactory = (name: string) => ChannelLike

// ---------------------------------------------------------------------------
// Locks

export interface HeldLock {
  release(): void
}

/**
 * Exclusive named locks, granted in request order, released when the holder
 * releases them or when its context dies. In the browser: Web Locks.
 */
export interface LockManagerLike {
  /**
   * Waits for the lock. Rejects if `signal` aborts before the grant. A grant
   * that races an abort still resolves; the caller releases it.
   */
  acquire(name: string, signal?: AbortSignal): Promise<HeldLock>
  /** The lock if it is free now (no holder, no queue), otherwise `null`. */
  tryAcquire(name: string): Promise<HeldLock | null>
}

// ---------------------------------------------------------------------------
// Clock

export type TimerHandle = unknown

export interface Clock {
  now(): number
  setTimeout(callback: () => void, ms: number): TimerHandle
  clearTimeout(handle: TimerHandle): void
}

// ---------------------------------------------------------------------------
// Page lifecycle

/**
 * `freeze`: the context is about to stop running (page frozen, or put in the
 * back-forward cache). `resume`: it runs again.
 */
export type LifecycleEvent = "freeze" | "resume"

export interface LifecycleSource {
  subscribe(listener: (event: LifecycleEvent) => void): () => void
}

// ---------------------------------------------------------------------------
// Browser adapters

type WebLockManager = {
  request(
    name: string,
    options: { signal?: AbortSignal; ifAvailable?: boolean },
    callback: (lock: unknown) => Promise<void> | void,
  ): Promise<unknown>
}

const webLocks = (): WebLockManager => {
  const locks = (globalThis.navigator as { locks?: WebLockManager } | undefined)?.locks
  if (!locks) throw new Error("Web Locks are not available in this context")
  return locks
}

/** `navigator.locks` behind `LockManagerLike`. Works in windows and workers. */
export const browserLocks = (): LockManagerLike => {
  const locks = webLocks()
  return {
    acquire: (name, signal) =>
      new Promise<HeldLock>((resolve, reject) => {
        locks
          .request(name, signal ? { signal } : {}, () =>
            new Promise<void>((release) => {
              resolve({ release: () => release() })
            }),
          )
          .catch(reject)
      }),
    tryAcquire: (name) =>
      new Promise<HeldLock | null>((resolve, reject) => {
        locks
          .request(name, { ifAvailable: true }, (lock) => {
            if (lock == null) {
              resolve(null)
              return
            }
            return new Promise<void>((release) => {
              resolve({ release: () => release() })
            })
          })
          .catch(reject)
      }),
  }
}

export const browserChannels = (): ChannelFactory => (name) => new BroadcastChannel(name)

export const systemClock = (): Clock => ({
  now: () => Date.now(),
  setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
  clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
})

/**
 * Page lifecycle for a window: `freeze`/`resume` from the Page Lifecycle API,
 * and `pagehide`/`pageshow` with `persisted` for the back-forward cache.
 * Returns a source that never fires outside a window.
 */
export const browserLifecycle = (): LifecycleSource => ({
  subscribe(listener) {
    const doc = (globalThis as { document?: EventTarget }).document
    const win = (globalThis as { window?: EventTarget }).window
    if (!doc || !win) return () => {}
    const onFreeze = () => listener("freeze")
    const onResume = () => listener("resume")
    const onPageHide = (event: Event) => {
      if ((event as { persisted?: boolean }).persisted) listener("freeze")
    }
    const onPageShow = (event: Event) => {
      if ((event as { persisted?: boolean }).persisted) listener("resume")
    }
    doc.addEventListener("freeze", onFreeze)
    doc.addEventListener("resume", onResume)
    win.addEventListener("pagehide", onPageHide)
    win.addEventListener("pageshow", onPageShow)
    return () => {
      doc.removeEventListener("freeze", onFreeze)
      doc.removeEventListener("resume", onResume)
      win.removeEventListener("pagehide", onPageHide)
      win.removeEventListener("pageshow", onPageShow)
    }
  },
})
