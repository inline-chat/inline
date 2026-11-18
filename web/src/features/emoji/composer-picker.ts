/**
 * The composer's emoji button: a popover with the full picker. Choosing an
 * emoji closes the popover, records the use (frecency, as the Mac's
 * `EmojiPickerData.recordUse`) and hands the emoji to `onInsert`, which
 * inserts it at the caret and returns focus to the editor. Framework-free;
 * `ComposerEmojiButton.tsx` renders it.
 *
 * Focus: the kit's popover takes focus in on open (the popover itself while
 * the placeholder shows), the picker's search field takes it when it
 * attaches, and the popover returns it to the button on close. `open()`
 * from code waits for the button to be laid out, so a picker opened at
 * start-up is placed at the button.
 */

import { type Dispose, signal, type ReadSignal } from "@inline/reactive"
import { type Part, PopoverController, type Placement } from "@inline/ui"
import { type FrameScheduler, nextFrame, openWhenAnchored } from "./frame"
import { EmojiPickerController } from "./picker"
import type { EmojiServices } from "./services"

export type ComposerEmojiPickerOptions = {
  readonly services: EmojiServices
  /** Insert the chosen emoji (in the preferred tone) and focus the editor. */
  readonly onInsert: (emoji: string) => void
  /** Default "top-end": above the button, aligned to its end, as the Mac's popover over the composer. */
  readonly placement?: Placement
  readonly direction?: () => "ltr" | "rtl"
  /** The next frame (waiting for the button's layout). Default `requestAnimationFrame`. */
  readonly frame?: FrameScheduler
}

export class ComposerEmojiPicker {
  readonly popover: PopoverController
  /** The picker while the popover is open and the data has loaded. */
  readonly picker: ReadSignal<EmojiPickerController | undefined>
  readonly #picker = signal<EmojiPickerController | undefined>(undefined)
  readonly #options: ComposerEmojiPickerOptions
  #button: HTMLElement | null = null
  #cancelOpen: Dispose | null = null

  constructor(options: ComposerEmojiPickerOptions) {
    this.#options = options
    this.picker = this.#picker
    this.popover = new PopoverController({
      placement: options.placement ?? "top-end",
      offset: 8,
      role: "dialog",
      label: "Emoji",
      onOpenChange: (open) => {
        if (open) this.#opened()
      },
    })
  }

  /** The button's part (toggles the popover). */
  readonly trigger: Part = {
    attach: (element) => {
      this.#button = element
      const detach = this.popover.trigger.attach(element)
      return () => {
        detach()
        if (this.#button === element) this.#button = null
      }
    },
  }

  /** Open from code: at once when the button is laid out, else on the first frame it is. */
  open(): void {
    this.#cancelOpen?.()
    this.#cancelOpen = openWhenAnchored(
      () => this.#button,
      () => {
        this.#cancelOpen = null
        this.popover.open()
      },
      this.#options.frame ?? nextFrame,
    )
  }

  #opened(): void {
    const { loader } = this.#options.services
    const existing = this.#picker.peek()
    if (existing) {
      existing.reset()
      return
    }
    void loader.load().then(
      (engine) => {
        if (this.#picker.peek()) return
        this.#picker.set(
          new EmojiPickerController({
            engine,
            usage: this.#options.services.usage,
            support: this.#options.services.support,
            onChoose: (emoji) => this.choose(emoji),
            ...(this.#options.direction ? { direction: this.#options.direction } : {}),
          }),
        )
      },
      () => undefined,
    )
  }

  choose(emoji: string): void {
    this.#options.services.usage.record(emoji)
    this.popover.close()
    this.#options.onInsert(emoji)
  }

  dispose(): void {
    this.#cancelOpen?.()
    this.#cancelOpen = null
    this.#picker.peek()?.dispose()
    this.#picker.set(undefined)
    this.popover.dispose()
  }
}
