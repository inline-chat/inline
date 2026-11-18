/**
 * Code splitting without React `lazy`: a view chunk is loaded with a dynamic
 * import in framework-free code and published on a signal, which the gate
 * reads with `useSignal`. The sign-in screen and the signed-in shell are
 * separate chunks; the gate shows a neutral frame until the one it needs has
 * arrived (from the service worker's cache after the first visit).
 */

import { signal, type ReadSignal } from "@inline/reactive"

export type Loadable<T> = {
  /** The loaded value, or undefined until it arrives. */
  readonly value: ReadSignal<T | undefined>
  /** The last load error, cleared by a new attempt. */
  readonly error: ReadSignal<unknown>
  /** Start loading (once; again after an error). */
  load(): Promise<T | undefined>
}

export const loadable = <T>(importer: () => Promise<T>): Loadable<T> => {
  const value = signal<T | undefined>(undefined)
  const error = signal<unknown>(undefined)
  let pending: Promise<T | undefined> | undefined
  return {
    value: { get: () => value.get(), peek: () => value.peek() },
    error: { get: () => error.get(), peek: () => error.peek() },
    load() {
      if (pending) return pending
      error.set(undefined)
      pending = importer().then(
        (loaded) => {
          value.set(loaded)
          return loaded
        },
        (failure: unknown) => {
          pending = undefined
          error.set(failure ?? new Error("load failed"))
          return undefined
        },
      )
      return pending
    },
  }
}
