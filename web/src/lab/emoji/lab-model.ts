/**
 * The emoji lab's state, framework-free: real emoji services over memory
 * storage (so the lab never touches the app's usage), the three pickers
 * (reaction, composer button, an inline full picker for screenshots), the
 * composer `:` source over a plain text field, and a log of what was chosen.
 */

import { detectEmoji, type Trigger } from "@inline/composer"
import { computed, signal, type ReadSignal } from "@inline/reactive"
import type { Rect } from "@inline/ui"
import { ComposerEmojiPicker } from "../../features/emoji/composer-picker"
import { createEmojiSuggest, type EmojiSuggestion } from "../../features/emoji/composer-source"
import type { EmojiEngine } from "../../features/emoji/engine"
import { EmojiPickerController } from "../../features/emoji/picker"
import { ReactionPickerController } from "../../features/emoji/reaction-picker"
import { createEmojiServices, type EmojiServices } from "../../features/emoji/services"
import { memoryKeyValueStore, USAGE_KEYS } from "../../features/emoji/usage"

export const LAB_MESSAGE = "Shipped the new build 🚀 thanks everyone 🎉"

export class EmojiLab {
  readonly services: EmojiServices
  readonly engine: ReadSignal<EmojiEngine | undefined>
  /** The inline picker, once the data has loaded. */
  readonly inline = signal<EmojiPickerController | undefined>(undefined)
  readonly reaction: ReactionPickerController
  /** A quick row drawn inline (not in a popover), for screenshots. */
  readonly quickStatic: ReactionPickerController
  readonly composer: ComposerEmojiPicker
  /** The viewer's reactions on the lab message. */
  readonly mine = signal<ReadonlySet<string>>(new Set(["👍"]))
  readonly log = signal<readonly string[]>([])
  readonly composerText = signal("")
  readonly composerCaret = signal(0)
  readonly trigger: ReadSignal<Trigger | null>
  readonly suggestions: ReadSignal<readonly EmojiSuggestion[]>
  /** An element or point, or a lookup run when the picker opens (an element React has not rendered yet). */
  #anchor: Element | Rect | (() => Element | Rect | null) | null = null
  readonly #store = memoryKeyValueStore()

  constructor(options: { usage: "seeded" | "empty" }) {
    this.services = createEmojiServices({ store: this.#store })
    this.engine = this.services.loader.engine
    if (options.usage === "seeded") this.seed()

    this.reaction = new ReactionPickerController({
      services: this.services,
      anchor: () => (typeof this.#anchor === "function" ? this.#anchor() : this.#anchor),
      onChoose: (emoji, wasMine) => {
        const next = new Set(this.mine.peek())
        if (wasMine) next.delete(emoji)
        else next.add(emoji)
        this.mine.set(next)
        this.#log(`${wasMine ? "removed" : "reacted"} ${emoji}`)
      },
    })
    this.quickStatic = new ReactionPickerController({ services: this.services, onChoose: (emoji) => this.#log(`quick ${emoji}`) })
    this.quickStatic.prepare({ messageText: LAB_MESSAGE, mine: this.mine.peek() })

    this.composer = new ComposerEmojiPicker({
      services: this.services,
      onInsert: (emoji) => {
        const text = this.composerText.peek()
        const caret = Math.min(this.composerCaret.peek(), text.length)
        this.composerText.set(text.slice(0, caret) + emoji + text.slice(caret))
        this.composerCaret.set(caret + emoji.length)
        this.#log(`inserted ${emoji}`)
      },
    })

    const source = createEmojiSuggest({ services: this.services })
    this.trigger = computed(() => detectEmoji(this.composerText.get(), this.composerCaret.get()))
    this.suggestions = computed(() => {
      const trigger = this.trigger.get()
      return trigger ? source.suggest(trigger) : []
    })

    void this.services.warm().then((engine) => {
      this.inline.set(this.#inlinePicker(engine))
    })
  }

  #inlinePicker(engine: EmojiEngine): EmojiPickerController {
    return new EmojiPickerController({
      engine,
      usage: this.services.usage,
      support: this.services.support,
      autoFocus: false,
      idPrefix: "lab-inline",
      onChoose: (emoji) => this.#log(`picked ${emoji}`),
    })
  }

  /** Some usage so Frequently Used and the learned quick reactions show. */
  seed(): void {
    const usage = this.services.usage
    for (const emoji of ["🚀", "🚀", "🚀", "👀", "👀", "✅", "🙌", "😅", "🔥"]) usage.record(emoji)
    for (const emoji of ["🚀", "🚀", "👀"]) usage.recordReaction(emoji)
  }

  /**
   * Open the reaction picker for the lab message, anchored at an element or
   * a point, or at what a lookup finds (the picker waits for it to be laid out).
   */
  openReaction(anchor: Element | Rect | (() => Element | Rect | null) | null): void {
    this.#anchor = anchor
    this.reaction.open({ messageText: LAB_MESSAGE, mine: this.mine.peek() })
  }

  /** Start over with fresh usage (empty or seeded); the skin tone stays. */
  resetUsage(mode: "seeded" | "empty"): void {
    this.#store.data.delete(USAGE_KEYS.frecency)
    this.#store.data.delete(USAGE_KEYS.reactionCounts)
    if (mode === "seeded") this.seed()
    this.quickStatic.prepare({ messageText: LAB_MESSAGE, mine: this.mine.peek() })
    this.inline.peek()?.reset()
    this.#log(`usage reset (${mode})`)
  }

  setComposer(text: string, caret = text.length): void {
    this.composerText.set(text)
    this.composerCaret.set(Math.max(0, Math.min(caret, text.length)))
  }

  /** Accept a `:` suggestion as the composer would: replace the trigger's range with the emoji. */
  acceptSuggestion(index: number): boolean {
    const trigger = this.trigger.peek()
    const row = this.suggestions.peek()[index]
    if (!trigger || !row) return false
    const text = this.composerText.peek()
    this.setComposer(text.slice(0, trigger.range.from) + row.emoji + text.slice(trigger.range.to), trigger.range.from + row.emoji.length)
    this.services.usage.record(row.emoji)
    this.#log(`autocompleted ${row.emoji}`)
    return true
  }

  #log(line: string): void {
    this.log.set([...this.log.peek().slice(-19), line])
  }
}
