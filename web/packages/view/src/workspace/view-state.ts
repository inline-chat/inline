/**
 * Per-destination view state that survives navigation: a scroll place, a
 * draft focus, an expanded section. The bag is opaque to the workspace; each
 * feature owns the shape of its own values, which must be plain JSON data so
 * the bag can be persisted.
 *
 * Keys group destinations that share a view: a chat, a message in it and its
 * info page all use the chat's key. The store keeps the most recently used
 * entries up to a limit.
 */

import type { Destination } from "./destination"
import { destinationChatId } from "./destination"
import { destinationKey } from "./url"

export const defaultViewStateLimit = 200

/** The key a destination's view state is stored under. */
export const viewStateKey = (destination: Destination): string => {
  const chatId = destinationChatId(destination)
  if (chatId !== undefined && destination.kind !== "chatInfo") return `chat:${chatId}`
  return destinationKey(destination)
}

export class ViewStateStore {
  readonly limit: number
  // Map iteration order is insertion order; re-inserting on use makes it LRU.
  #entries = new Map<string, unknown>()

  constructor(limit: number = defaultViewStateLimit) {
    this.limit = Math.max(1, limit)
  }

  get<T = unknown>(destination: Destination): T | undefined {
    return this.getByKey(viewStateKey(destination)) as T | undefined
  }

  set(destination: Destination, value: unknown): void {
    this.setByKey(viewStateKey(destination), value)
  }

  delete(destination: Destination): void {
    this.#entries.delete(viewStateKey(destination))
  }

  getByKey(key: string): unknown {
    if (!this.#entries.has(key)) return undefined
    const value = this.#entries.get(key)
    this.#entries.delete(key)
    this.#entries.set(key, value)
    return value
  }

  setByKey(key: string, value: unknown): void {
    this.#entries.delete(key)
    if (value === undefined) return
    this.#entries.set(key, value)
    while (this.#entries.size > this.limit) {
      const oldest = this.#entries.keys().next()
      if (oldest.done) break
      this.#entries.delete(oldest.value)
    }
  }

  get size(): number {
    return this.#entries.size
  }

  /** Oldest first, for persistence. */
  entries(): readonly (readonly [string, unknown])[] {
    return [...this.#entries]
  }

  clear(): void {
    this.#entries.clear()
  }
}
