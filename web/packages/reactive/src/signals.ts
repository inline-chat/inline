/**
 * Signal primitives under our own names. Everything in web/ imports these,
 * never the library underneath. See web/docs/reactivity.md and the contract
 * tests in signals.contract.test.ts, which are the specification.
 *
 * The implementation wraps alien-signals 3.2.1. The wrapper adds what the
 * library does not give us: `batch`, `untracked`, custom equality on writes
 * and on computeds, effect errors that cannot break a flush, computeds that
 * keep throwing the same error until their sources change, owned scopes with
 * a return value, and a signal that knows whether anything observes it.
 */

import {
  computed as alienComputed,
  effect as alienEffect,
  effectScope as alienEffectScope,
  endBatch,
  getActiveSub,
  setActiveSub,
  signal as alienSignal,
  startBatch,
} from "alien-signals"
import type { ReactiveNode } from "alien-signals/system"

export type Dispose = () => void

export type Equals<T> = (a: T, b: T) => boolean

export interface ReadSignal<T> {
  /** Read and track: the current effect or computed re-runs when this changes. */
  get(): T
  /** Read without tracking. */
  peek(): T
}

export interface Signal<T> extends ReadSignal<T> {
  set(value: T): void
  update(fn: (current: T) => T): void
}

export type SignalOptions<T> = {
  /** Defaults to `Object.is`. A write of an equal value notifies nobody. */
  equals?: Equals<T>
}

// ---------------------------------------------------------------------------
// Errors

export type ErrorHandler = (error: unknown) => void

const defaultErrorHandler: ErrorHandler = (error) => {
  const report = (globalThis as { reportError?: (error: unknown) => void }).reportError
  if (typeof report === "function") {
    report(error)
    return
  }
  // Surface it as an uncaught error without unwinding the flush that ran it.
  queueMicrotask(() => {
    throw error
  })
}

let errorHandler: ErrorHandler = defaultErrorHandler

/**
 * Where an error thrown by an effect (or its cleanup) goes. The default
 * reports it as an uncaught error on a later turn. Returns the previous
 * handler. An effect error never propagates into the write that triggered it.
 */
export const setErrorHandler = (handler: ErrorHandler | undefined): ErrorHandler => {
  const previous = errorHandler
  errorHandler = handler ?? defaultErrorHandler
  return previous
}

const reportEffectError = (error: unknown) => {
  try {
    errorHandler(error)
  } catch {
    // A failing handler must not break the graph either.
  }
}

// ---------------------------------------------------------------------------
// Core primitives

/** Whether a tracking context (effect, computed or scope body) is active. */
export const isTracking = (): boolean => getActiveSub() !== undefined

/** Run `fn` without tracking the signals it reads. */
export const untracked = <T>(fn: () => T): T => {
  const previous = setActiveSub(undefined)
  try {
    return fn()
  } finally {
    setActiveSub(previous)
  }
}

/**
 * Group writes; observers run once, after the outermost batch ends. Reads
 * inside the batch see the writes immediately (see the sync-lane contract).
 */
export const batch = <T>(fn: () => T): T => {
  startBatch()
  try {
    return fn()
  } finally {
    endBatch()
  }
}

export const signal = <T>(initial: T, options?: SignalOptions<T>): Signal<T> => {
  const inner = alienSignal<T>(initial)
  const read = inner as () => T
  const write = inner as (value: T) => void
  const equals = options?.equals ?? Object.is
  const peek = () => untracked(read)
  const set = (value: T) => {
    if (equals(peek(), value)) return
    write(value)
  }
  return {
    get: read,
    peek,
    set,
    update: (fn) => set(fn(peek())),
  }
}

/** Holds a thrown error as a computed's value, so every read rethrows it. */
class Thrown {
  constructor(readonly error: unknown) {}
}

/**
 * A lazily evaluated, cached derivation. Must be pure. Not evaluated until
 * read. With `equals`, a recomputation that is equal to the previous value
 * keeps the previous value (and its identity) and notifies nobody.
 *
 * If `fn` throws, every read rethrows that error until a source changes.
 */
export const computed = <T>(fn: () => T, options?: SignalOptions<T>): ReadSignal<T> => {
  const equals = options?.equals
  let hasValue = false
  const inner = alienComputed<T | Thrown>((previous) => {
    let next: T | Thrown
    try {
      next = fn()
    } catch (error) {
      return new Thrown(error)
    }
    if (equals && hasValue && !(previous instanceof Thrown) && equals(previous as T, next)) {
      return previous as T
    }
    hasValue = true
    return next
  })
  const unwrap = (value: T | Thrown): T => {
    if (value instanceof Thrown) throw value.error
    return value
  }
  return {
    get: () => unwrap(inner()),
    peek: () => unwrap(untracked(inner)),
  }
}

/**
 * Run `fn` now and again whenever a signal it read changes. `fn` may return
 * a cleanup, which runs before the next run and on dispose. An error thrown
 * by `fn` or its cleanup goes to the error handler; the effect stays alive
 * with the dependencies it read before throwing.
 */
export const effect = (fn: () => void | Dispose): Dispose =>
  alienEffect(() => {
    let cleanup: void | Dispose
    try {
      cleanup = fn()
    } catch (error) {
      reportEffectError(error)
      return
    }
    if (typeof cleanup !== "function") return
    const run = cleanup
    return () => {
      try {
        run()
      } catch (error) {
        reportEffectError(error)
      }
    }
  })

/**
 * Collect the effects (and nested scopes) created inside `fn`; disposing the
 * scope disposes them. Read signals inside `fn` with `peek`; a tracked read
 * in a scope body links to the scope, not to anything that re-runs.
 */
export const scope = (fn: () => void): Dispose => alienEffectScope(fn)

/** Like `scope`, but returns what `fn` returns along with the disposer. */
export const scoped = <T>(fn: () => T): [value: T, dispose: Dispose] => {
  let value!: T
  const dispose = alienEffectScope(() => {
    value = fn()
  })
  return [value, dispose]
}

/**
 * Run `fn` when the current scope or effect is disposed (or, inside an
 * effect, before it re-runs). Outside any owner it never runs.
 */
export const onDispose = (fn: () => void): void => {
  effect(() => fn)
}

// ---------------------------------------------------------------------------
// Observed signals

export interface ObservedSignal<T> extends Signal<T> {
  /**
   * True while an effect, a watched computed or a scope is linked to this
   * signal. A computed that was evaluated but never watched also counts; it
   * stays linked until its sources change or it is watched and released.
   */
  observed(): boolean
}

/**
 * A signal that can tell whether anything observes it. The view store uses it
 * to release per-row signals nobody is watching. It costs one extra node per
 * signal, so use plain `signal` unless you need `observed()`.
 */
export const observedSignal = <T>(initial: T): ObservedSignal<T> => {
  const inner = alienSignal<T>(initial)
  const read = inner as () => T
  const write = inner as (value: T) => void
  let node: ReactiveNode | undefined
  const watched = alienComputed<T>(() => {
    // Inside a computed's getter the active subscriber is the computed itself.
    node ??= getActiveSub()
    return read()
  })
  const peek = () => untracked(read)
  const set = (value: T) => {
    if (Object.is(peek(), value)) return
    write(value)
  }
  return {
    get: watched,
    peek,
    set,
    update: (fn) => set(fn(peek())),
    observed: () => node?.subs !== undefined,
  }
}
