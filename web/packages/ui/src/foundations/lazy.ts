/**
 * A value loaded once on first need: a code-split chunk, usually. `value` is
 * a signal, so a view renders the loaded part the moment it arrives; `peek()`
 * lets an event handler act synchronously when it is already there. A failed
 * load is forgotten, so the next `load()` tries again.
 */

import { type ReadSignal, type Signal, signal } from "@inline/reactive"

export class Lazy<T> {
  readonly #load: () => Promise<T>
  readonly #value: Signal<T | undefined> = signal<T | undefined>(undefined)
  #pending: Promise<T> | null = null

  /** The loaded value, or undefined until it arrives. */
  readonly value: ReadSignal<T | undefined> = this.#value

  constructor(load: () => Promise<T>) {
    this.#load = load
  }

  peek(): T | undefined {
    return this.#value.peek()
  }

  /** Start loading (once) and resolve with the value. */
  load(): Promise<T> {
    const loaded = this.#value.peek()
    if (loaded !== undefined) return Promise.resolve(loaded)
    if (!this.#pending) {
      this.#pending = this.#load().then(
        (value) => {
          this.#value.set(value)
          return value
        },
        (error: unknown) => {
          this.#pending = null
          throw error
        },
      )
    }
    return this.#pending
  }
}
