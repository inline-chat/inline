/**
 * Emoji for one signed-in account (`web/src/features/emoji/README.md`): the
 * services (usage, the lazily loaded table, the drawability check), the
 * pickers' chunk, and the composer's `:` suggestions. Nothing emoji is on the
 * first frame: the light half (`emoji` in `view-chunks.ts`) and the pickers
 * (`emojiPickers`) are warmed on the idle lane after the first paint, or
 * loaded by the first use (Add Reaction, the emoji button, the first `:`);
 * the 44.5 kB table loads through the services' own `import()`, last on the
 * idle lane (`warmData`) or on first use.
 *
 * Recents and the skin tone are kept per account in `localStorage`, under
 * `inline:emoji:<userId>:<Mac key>` (the Mac's keys, `USAGE_KEYS`, after the
 * account prefix), and erased with the account on sign-out
 * (`eraseAccountEmoji`, from the app's erase hook). They name emoji used,
 * never message text.
 *
 * Framework-free; `ShellModel` makes one per session.
 */

export { accountEmojiStore, emojiStoragePrefix, eraseAccountEmoji } from "./emoji-storage"

import type { UserID } from "@inline/ids"
import { signal, type ReadSignal } from "@inline/reactive"
import type { Trigger } from "@inline/composer"
import type { StorageLike } from "@inline/view"
import { accountEmojiStore } from "./emoji-storage"
import type { ComposerSuggestion } from "../features/composer/autocomplete"
import type { EmojiChunk, EmojiServices, EmojiSuggest } from "../features/emoji"

/** The emoji modules, as `view-chunks.ts` loads them. */
export type EmojiModules = {
  readonly services: () => Promise<Pick<typeof import("../features/emoji"), "createEmojiServices" | "createEmojiSuggest">>
  readonly pickers: () => Promise<EmojiChunk>
}

const none: readonly ComposerSuggestion[] = Object.freeze([])

export type SessionEmojiOptions = {
  readonly userId: UserID
  readonly storage: StorageLike | undefined
  readonly modules: EmojiModules
  /** Run after the computed that asked (loading writes signals). Default `queueMicrotask`. */
  readonly defer?: (fn: () => void) => void
}

export class SessionEmoji {
  /** The services, once the light half has loaded. */
  readonly services: ReadSignal<EmojiServices | undefined>
  /** The pickers' chunk, once loaded. */
  readonly pickers: ReadSignal<EmojiChunk | undefined>

  readonly #options: SessionEmojiOptions
  readonly #services = signal<EmojiServices | undefined>(undefined)
  readonly #pickers = signal<EmojiChunk | undefined>(undefined)
  readonly #suggest = signal<EmojiSuggest | undefined>(undefined)
  #servicesLoad: Promise<EmojiServices | undefined> | undefined
  #pickersLoad: Promise<EmojiChunk | undefined> | undefined
  #used = false
  #disposed = false

  constructor(options: SessionEmojiOptions) {
    this.#options = options
    this.services = { get: () => this.#services.get(), peek: () => this.#services.peek() }
    this.pickers = { get: () => this.#pickers.get(), peek: () => this.#pickers.peek() }
  }

  /** Load the light half and make the services (once; again after a failure). */
  loadServices(): Promise<EmojiServices | undefined> {
    const ready = this.#services.peek()
    if (ready || this.#disposed) return Promise.resolve(ready)
    this.#servicesLoad ??= this.#options.modules.services().then(
      (module) => {
        this.#servicesLoad = undefined
        if (this.#disposed) return undefined
        const services =
          this.#services.peek() ??
          module.createEmojiServices({ store: accountEmojiStore(this.#options.storage, this.#options.userId) })
        this.#services.set(services)
        this.#suggest.set(module.createEmojiSuggest({ services }))
        return services
      },
      (error: unknown) => {
        this.#servicesLoad = undefined
        throw error
      },
    )
    return this.#servicesLoad
  }

  /** Load the pickers' chunk (once; again after a failure). */
  loadPickers(): Promise<EmojiChunk | undefined> {
    const ready = this.#pickers.peek()
    if (ready || this.#disposed) return Promise.resolve(ready)
    this.#pickersLoad ??= this.#options.modules.pickers().then(
      (chunk) => {
        this.#pickersLoad = undefined
        if (this.#disposed) return undefined
        this.#pickers.set(chunk)
        return chunk
      },
      (error: unknown) => {
        this.#pickersLoad = undefined
        throw error
      },
    )
    return this.#pickersLoad
  }

  /** The warm-up lane after the first paint: the light half and the pickers' code, never the table. */
  async warm(): Promise<void> {
    await this.loadServices()
    await this.loadPickers()
  }

  /**
   * The emoji table on the idle lane, after everything else
   * (`shell-warmup.ts`): the engine only, not the drawability scan, which
   * waits for the first real use. Resolves undefined when it cannot load.
   */
  async warmData(): Promise<unknown> {
    const services = await this.loadServices()
    if (!services || this.#disposed) return undefined
    return services.loader.load()
  }

  /**
   * The first real use (a picker opening, the first `:`): everything a
   * picker needs, then the table and the drawability scan (`services.warm()`).
   */
  async use(): Promise<EmojiServices | undefined> {
    const services = await this.loadServices()
    await this.loadPickers()
    if (services && !this.#used && !this.#disposed) {
      this.#used = true
      void services.warm().catch(() => {
        this.#used = false
      })
    }
    return services
  }

  /**
   * The composer's `:` source (`SuggestFn`): emoji rows for an `emoji`
   * trigger, nothing for others. Read inside the composer's computed: it
   * reads signals and never writes one; the first call starts the load and
   * the list fills in when the data arrives.
   */
  readonly suggest = (trigger: Trigger): readonly ComposerSuggestion[] => {
    if (trigger.kind !== "emoji") return none
    const source = this.#suggest.get()
    if (!source) {
      ;(this.#options.defer ?? queueMicrotask)(() => void this.use().catch(() => undefined))
      return none
    }
    return source.suggest(trigger) as readonly ComposerSuggestion[]
  }

  /** An emoji from the `:` list was inserted: it counts toward recents (the Mac's frecency). */
  recordAccepted(text: string): void {
    this.#suggest.peek()?.recordAccepted(text)
  }

  dispose(): void {
    this.#disposed = true
    this.#suggest.set(undefined)
  }
}

/** Both the `@` and `:` sources as one `suggest` for the composer. */
export const combinedSuggest =
  (mentions: (trigger: Trigger) => readonly ComposerSuggestion[], emoji: SessionEmoji | undefined) =>
  (trigger: Trigger): readonly ComposerSuggestion[] =>
    trigger.kind === "emoji" ? (emoji ? emoji.suggest(trigger) : none) : mentions(trigger)

