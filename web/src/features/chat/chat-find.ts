/**
 * Find in chat for one open chat in a pane (`web/src/features/find/README.md`,
 * "Mounting in the chat pane"). Framework-free.
 *
 * - The find model (`FindInChatModel`) and the bar are their own chunk
 *   (`find-chunk.ts`), loaded on the first Mod+F: `open()` loads it, creates
 *   the model for this chat and opens it. Until then this object answers the
 *   commands' questions (closed, nothing to step to), so Mod+F is bound from
 *   the first frame and later Mod+F, Mod+G and Mod+Shift+G act on the model.
 * - One per chat shown in a pane: the pane creates it with the chat and
 *   disposes it when the pane switches chats or closes (the Mac closes find
 *   on a switch). Disposing disposes the model, which cancels what is in
 *   flight and never restores focus.
 * - `jump` (a step, Enter, a preview chosen) puts the match's ranges on the
 *   row through `highlights` (`FindHighlights`, read by the message rows'
 *   `highlightRangesFor`) and asks the timeline to bring the message into
 *   view with a flash. Closing clears the highlight.
 * - Focus: `open()` remembers where focus was; `close()` returns it there,
 *   or to the composer when that element is gone (the Mac's rule).
 */

import { receivedMessageRowId, type MessageRow } from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { computed, signal, type Clock, type ReadSignal, type StoreClient } from "@inline/reactive"
import type { FindCommandTarget } from "../find/commands"
import type { FindInChatModel, FindJump } from "../find/find-model"
import { FindHighlights, normalizeRanges } from "../message/find"
import type { FindChunk } from "./find-chunk"

/** The chunk as a loadable (`AppViews.find`). */
export type FindChunkSource = {
  readonly value: ReadSignal<FindChunk | undefined>
  load(): Promise<FindChunk | undefined>
}

export type ChatFindOptions = {
  readonly chatId: ChatID
  readonly chunk: FindChunkSource
  readonly client: Pick<StoreClient, "subscribe">
  readonly clock: Pick<Clock, "setTimeout" | "clearTimeout">
  /** Bring a message into view and flash it (`timeline.jumpToMessage(id, { highlight: true })`). */
  readonly jumpTo: (messageId: MessageID) => void
  /** The message's row, for its text length (ranges are clipped to it). */
  readonly peekMessage: (messageId: MessageID) => MessageRow | undefined
  /** Remember focus on open; the returned function restores it on close. */
  readonly captureFocus?: () => (() => void) | undefined
}

export class ChatFind implements FindCommandTarget {
  readonly chatId: ChatID
  /** The persistent highlight of the active match, for the rows (`MessageRowContext.highlightRangesFor`). */
  readonly highlights = new FindHighlights()
  /** The find model, once the chunk is there and find was opened in this chat. */
  readonly model: ReadSignal<FindInChatModel | undefined>
  /** The chunk, for the bar. */
  readonly chunk: ReadSignal<FindChunk | undefined>
  /** The active match (message and ranges), for tests and diagnostics; cleared on close. */
  readonly active: ReadSignal<{ readonly messageId: MessageID; readonly ranges: FindJump["ranges"] } | undefined>

  readonly isOpen: ReadSignal<boolean>
  readonly fieldFocused: ReadSignal<boolean>
  readonly canGoOlder: ReadSignal<boolean>
  readonly canGoNewer: ReadSignal<boolean>

  readonly #options: ChatFindOptions
  readonly #model = signal<FindInChatModel | undefined>(undefined)
  readonly #active = signal<{ readonly messageId: MessageID; readonly ranges: FindJump["ranges"] } | undefined>(undefined)
  #pendingSeed: { seed?: string } | undefined
  #loading = false
  #disposed = false

  constructor(options: ChatFindOptions) {
    this.#options = options
    this.chatId = options.chatId
    this.model = { get: () => this.#model.get(), peek: () => this.#model.peek() }
    this.active = { get: () => this.#active.get(), peek: () => this.#active.peek() }
    this.chunk = options.chunk.value
    // Before the model exists: closed, nothing to step to (Find Next then opens, as on the Mac).
    const of = (read: (model: FindInChatModel) => ReadSignal<boolean>) =>
      computed(() => {
        const model = this.#model.get()
        return model ? read(model).get() : false
      })
    this.isOpen = of((model) => model.isOpen)
    this.fieldFocused = of((model) => model.fieldFocused)
    this.canGoOlder = of((model) => model.canGoOlder)
    this.canGoNewer = of((model) => model.canGoNewer)
  }

  /** Mod+F: open the bar (loading find on the first use), or focus its field when open. */
  open(options: { readonly seed?: string } = {}): void {
    if (this.#disposed) return
    const model = this.#model.peek()
    if (model) {
      model.open(options)
      return
    }
    this.#pendingSeed = options.seed !== undefined ? { seed: options.seed } : {}
    if (this.#loading) return
    this.#loading = true
    const loaded = this.#options.chunk.value.peek()
    if (loaded) {
      this.#create(loaded)
      return
    }
    void this.#options.chunk.load().then((chunk) => {
      if (chunk) this.#create(chunk)
      else this.#loading = false
    })
  }

  next(): void {
    this.#model.peek()?.next()
  }

  previous(): void {
    this.#model.peek()?.previous()
  }

  close(): void {
    this.#model.peek()?.close()
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    const model = this.#model.peek()
    this.#model.set(undefined)
    model?.dispose()
    this.#clear()
  }

  #create(chunk: FindChunk): void {
    this.#loading = false
    if (this.#disposed || this.#model.peek()) return
    const options = this.#options
    const model = new chunk.FindInChatModel({
      chatId: options.chatId,
      source: chunk.coreFindSource(options.client),
      server: chunk.coreServerFindSource(options.client),
      clock: options.clock,
      jump: (target) => this.#jump(target),
      ...(options.captureFocus ? { captureFocus: options.captureFocus } : {}),
      onClose: () => this.#clear(),
    })
    this.#model.set(model)
    const seed = this.#pendingSeed ?? {}
    this.#pendingSeed = undefined
    model.open(seed)
  }

  #jump(target: FindJump): void {
    if (this.#disposed || target.chatId !== this.chatId) return
    const row = this.#options.peekMessage(target.messageId)
    const ranges = normalizeRanges(target.ranges, row?.text.length ?? 0)
    this.highlights.showRow(row?.id ?? receivedMessageRowId(this.chatId, target.messageId), ranges)
    this.#active.set({ messageId: target.messageId, ranges: target.ranges })
    this.#options.jumpTo(target.messageId)
  }

  #clear(): void {
    this.highlights.clear()
    if (this.#active.peek() !== undefined) this.#active.set(undefined)
  }
}
