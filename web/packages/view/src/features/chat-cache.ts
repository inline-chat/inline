/**
 * Keeps a few recent chats resident so switching back paints in the next
 * frame (timeline-and-composer.md, "Window"). A chat shown in any pane, or
 * leased by a view, is never released and does not count against the
 * capacity; of the others, the most recent `capacity` stay. A released model
 * stays alive while a send in flight holds it.
 */

import type { WindowAnchor } from "@inline/core-protocol"
import type { ChatID } from "@inline/ids"
import { signal, type ReadSignal } from "@inline/reactive"
import type { ChatModel } from "./chat-model"

/** Start: the Mac app keeps a handful of chat view models; five covers quick switching. */
export const defaultResidentChats = 5

export type ChatLease = {
  readonly model: ChatModel
  /** Stop using the model. The cache decides whether it stays resident. */
  release(): void
}

export type ChatCacheOptions = {
  /** Creates a model for a chat; the cache retains it once. */
  readonly create: (chatId: ChatID, anchor: WindowAnchor | undefined) => ChatModel
  /** Chats shown in a pane now. Read on every eviction pass. */
  readonly pinned: () => ReadonlySet<ChatID>
  readonly capacity?: number
}

type Entry = { model: ChatModel; release: () => void; leases: number }

export class ChatCache {
  readonly capacity: number
  readonly #options: ChatCacheOptions
  /** Least recently used first. */
  readonly #entries = new Map<ChatID, Entry>()
  readonly #resident = signal<readonly ChatID[]>([])
  #disposed = false

  /** Resident chats, most recent last. */
  readonly resident: ReadSignal<readonly ChatID[]>

  constructor(options: ChatCacheOptions) {
    this.#options = options
    this.capacity = Math.max(1, options.capacity ?? defaultResidentChats)
    this.resident = { get: () => this.#resident.get(), peek: () => this.#resident.peek() }
  }

  /**
   * The model of a chat, created on first use and reused while resident.
   * Opening a resident chat at a message moves its window there.
   */
  open(chatId: ChatID, anchor?: WindowAnchor): ChatLease {
    if (this.#disposed) throw new Error("ChatCache is disposed")
    let entry = this.#entries.get(chatId)
    if (entry) {
      this.#entries.delete(chatId)
      if (anchor && typeof anchor === "object") entry.model.ensureAround(anchor.around)
    } else {
      const model = this.#options.create(chatId, anchor)
      entry = { model, release: model.retain(), leases: 0 }
    }
    this.#entries.set(chatId, entry)
    entry.leases += 1
    const held = entry
    const leaseRelease = held.model.retain()
    let released = false
    this.#publish()
    this.evict()
    return {
      model: held.model,
      release: () => {
        if (released) return
        released = true
        held.leases -= 1
        leaseRelease()
        this.evict()
      },
    }
  }

  /** The resident model of a chat, without touching its recency. */
  peek(chatId: ChatID): ChatModel | undefined {
    return this.#entries.get(chatId)?.model
  }

  /**
   * Keep the `capacity` most recently used chats besides those on screen or
   * leased, and release the rest. Runs after every open and release; the
   * owner also calls it when the panes change.
   */
  evict(): void {
    if (this.#disposed) return
    const pinned = this.#options.pinned()
    const candidates: ChatID[] = []
    for (const [chatId, entry] of this.#entries) {
      if (!pinned.has(chatId) && entry.leases === 0) candidates.push(chatId)
    }
    const excess = candidates.length - this.capacity
    if (excess <= 0) return
    for (const chatId of candidates.slice(0, excess)) {
      const entry = this.#entries.get(chatId)
      this.#entries.delete(chatId)
      // The model disposes itself once a send in flight releases it too.
      entry?.release()
    }
    this.#publish()
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    for (const entry of this.#entries.values()) {
      entry.release()
      // Leases still held by views end here too: the account is closing.
      entry.model.dispose()
    }
    this.#entries.clear()
    this.#publish()
  }

  #publish() {
    this.#resident.set([...this.#entries.keys()])
  }
}
