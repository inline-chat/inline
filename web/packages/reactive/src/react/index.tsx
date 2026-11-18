/**
 * React bindings for @inline/reactive. This directory is the one place in
 * web/ where React effects are written. Views read signals only through
 * these hooks; see web/docs/reactivity.md ("Bindings") and web/docs/views.md.
 */

import { useCallback, useEffect, useRef, useSyncExternalStore, type RefCallback } from "react"
import { effect, scoped, type Dispose, type ReadSignal } from "../signals"

// ---------------------------------------------------------------------------
// useSignal

type Subscribe = (onChange: () => void) => () => void

const subscribers = new WeakMap<ReadSignal<unknown>, Subscribe>()

/** One stable subscribe function per signal, so React never resubscribes on re-render. */
const subscribeTo = (source: ReadSignal<unknown>): Subscribe => {
  let subscribe = subscribers.get(source)
  if (subscribe === undefined) {
    subscribe = (onChange) => {
      let first = true
      return effect(() => {
        try {
          source.get()
        } catch {
          // The error reaches the component through getSnapshot during render.
        }
        if (first) {
          first = false
          return
        }
        onChange()
      })
    }
    subscribers.set(source, subscribe)
  }
  return subscribe
}

/**
 * Read a signal and re-render when it changes. The snapshot is the signal's
 * value itself: rows and lists are immutable and keep their identity while
 * unchanged, so the snapshot is stable.
 */
export function useSignal<T>(source: ReadSignal<T>): T {
  const read = () => source.peek()
  return useSyncExternalStore(subscribeTo(source as ReadSignal<unknown>), read, read)
}

// ---------------------------------------------------------------------------
// useModel

type ModelBox<T> = {
  value: T
  deps: readonly unknown[]
  mounted: boolean
  disposed: boolean
  dispose: () => void
}

const sameDeps = (a: readonly unknown[], b: readonly unknown[]) =>
  a.length === b.length && a.every((value, index) => Object.is(value, b[index]))

const createBox = <T,>(factory: () => T, deps: readonly unknown[]): ModelBox<T> => {
  const [value, disposeScope] = scoped(factory)
  const box: ModelBox<T> = {
    value,
    deps,
    mounted: false,
    disposed: false,
    dispose: () => {
      if (box.disposed) return
      box.disposed = true
      disposeScope()
      const disposable = value as { dispose?: unknown } | null | undefined
      if (disposable && typeof disposable.dispose === "function") (disposable.dispose as () => void)()
    },
  }
  return box
}

/**
 * Create a view model or controller for the component's lifetime and dispose
 * it on unmount. Effects the factory creates are owned by the model and
 * disposed with it; a `dispose()` method on the model is called too.
 *
 * `deps` (compared with `Object.is`) recreate the model when they change; the
 * old one is disposed after the commit that replaced it.
 *
 * The model exists during the first render (first frame from local data).
 * Under StrictMode the simulated unmount and remount keep the same model:
 * disposal waits a microtask and a remount cancels it.
 */
export function useModel<T>(factory: () => T, deps: readonly unknown[] = []): T {
  const ref = useRef<ModelBox<T> | null>(null)
  let box = ref.current
  if (box === null || box.disposed || !sameDeps(box.deps, deps)) {
    box = createBox(factory, deps)
    ref.current = box
  }
  const current = box
  useEffect(() => {
    current.mounted = true
    return () => {
      current.mounted = false
      queueMicrotask(() => {
        if (!current.mounted) current.dispose()
      })
    }
  }, [current])
  return current.value
}

// ---------------------------------------------------------------------------
// useElement

/** Something that takes a DOM element and lets go of it when the cleanup runs. */
export type ElementController<E extends Element> =
  | { attach(element: E): void | Dispose }
  | ((element: E) => void | Dispose)

/**
 * A ref callback that hands the element to `controller` and runs the
 * returned cleanup when the element goes away or the controller changes.
 * Under StrictMode React attaches, detaches and attaches again on mount.
 */
export function useElement<E extends Element>(controller: ElementController<E> | null | undefined): RefCallback<E> {
  return useCallback(
    (element: E | null) => {
      if (element === null || !controller) return
      const cleanup = typeof controller === "function" ? controller(element) : controller.attach(element)
      return () => {
        if (typeof cleanup === "function") cleanup()
      }
    },
    [controller],
  )
}
