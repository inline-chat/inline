/**
 * The composer's emoji button for one chat (`features/emoji/README.md`, "The
 * composer"): the full picker in a popover above the button; a choice is
 * inserted at the caret and the editor gets focus back.
 *
 * The button is on the first frame at its final size (the pane draws a
 * stand-in with the same name and box until the pickers' code and the emoji
 * services are there, so nothing in the input row moves). Pressing the
 * stand-in starts loading and opens the picker once it exists; the picker
 * then shows its placeholder until the table arrives. Framework-free; the
 * pane makes one per composer and disposes it with the chat.
 */

import { effect, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import type { EmojiChunk, EmojiServices } from "../emoji"
import type { ComposerEmojiPicker } from "../emoji/composer-picker"

/** What the slot needs of the session's emoji (`SessionEmoji` fits). */
export type ComposerEmojiSource = {
  readonly services: ReadSignal<EmojiServices | undefined>
  readonly pickers: ReadSignal<EmojiChunk | undefined>
  use(): Promise<unknown>
}

export type ComposerEmojiSlotOptions = {
  readonly emoji: ComposerEmojiSource
  /** Put the emoji at the caret and focus the editor. */
  readonly insert: (emoji: string) => void
  /** The next frame, for the picker waiting on its button's layout. Default the picker's own. */
  readonly frame?: (callback: () => void) => void
}

export class ComposerEmojiSlot {
  /** The picker's controller, once the pickers' code and the services are there. */
  readonly picker: ReadSignal<ComposerEmojiPicker | undefined>
  /** The pickers' chunk, for its button view. */
  readonly chunk: ReadSignal<EmojiChunk | undefined>
  readonly #picker = signal<ComposerEmojiPicker | undefined>(undefined)
  readonly #stop: Dispose
  #openWhenReady = false
  #disposed = false

  constructor(readonly options: ComposerEmojiSlotOptions) {
    this.picker = this.#picker
    this.chunk = options.emoji.pickers
    this.#stop = effect(() => {
      const chunk = options.emoji.pickers.get()
      const services = options.emoji.services.get()
      if (!chunk || !services) return
      untracked(() => {
        if (this.#picker.peek() || this.#disposed) return
        const picker = new chunk.ComposerEmojiPicker({
          services,
          onInsert: (value) => options.insert(value),
          ...(options.frame ? { frame: options.frame } : {}),
        })
        this.#picker.set(picker)
        if (this.#openWhenReady) {
          this.#openWhenReady = false
          picker.open()
        }
      })
    })
  }

  /** The stand-in was pressed before the picker existed: load, and open it when it does. */
  request(): void {
    if (this.#disposed) return
    const picker = this.#picker.peek()
    if (picker) {
      picker.open()
      return
    }
    this.#openWhenReady = true
    void this.options.emoji.use().catch(() => {
      this.#openWhenReady = false
    })
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stop()
    this.#picker.peek()?.dispose()
    this.#picker.set(undefined)
  }
}
