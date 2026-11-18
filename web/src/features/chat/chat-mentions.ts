/**
 * `@` mentions for one open chat's composer (`web/src/features/mentions/README.md`).
 * Framework-free; the static side of `mention-models.ts`.
 *
 * - `suggest` is the composer model's `suggest` option. The participants
 *   model and the suggestions are their own chunk (`mentions-chunk.ts`),
 *   loaded on the first `@`: until it arrives the list is empty; when it
 *   arrives the signal it publishes changes and the composer's list (a
 *   computed over `suggest`) fills in by itself. Other triggers (`:`, `/`)
 *   get nothing here.
 * - `afterSend(entities)` runs the rule-14 decision once a message with
 *   mentions is accepted (`mention-models.ts`): `autoAdd` posts
 *   `addChatParticipants` at once and says so with Undo; `prompt` asks in
 *   the confirmation alert and adds on confirm; refusals and uncertain
 *   outcomes are toasts in the session's words.
 * - `dispose()` releases the suggestions and the participants model.
 */

import type { Entity, RowKey } from "@inline/core-protocol"
import type { Trigger } from "@inline/composer"
import type { ChatID, UserID } from "@inline/ids"
import { signal, type ReadSignal, type StoreClient } from "@inline/reactive"
import type { ComposerSuggestion } from "../composer/autocomplete"
import type { ActionHandle } from "@inline/view/features"
import type { MentionAddDecision } from "../mentions/add-policy"
import type { ConfirmRequest } from "./message-actions"
import type { ChatMentionModels } from "./mention-models"
import type { MentionsChunk } from "./mentions-chunk"

/** The chunk as a loadable (`AppViews.mentions`). */
export type MentionsChunkSource = {
  readonly value: ReadSignal<MentionsChunk | undefined>
  load(): Promise<MentionsChunk | undefined>
}

/** What the suggestions read from the chat (`ChatModel` fits). */
export type MentionsChat = {
  readonly rowKeys: ReadSignal<readonly RowKey[]>
  row(key: RowKey): ReadSignal<{ readonly fromId: UserID } | undefined>
  readonly window: ReadSignal<{ readonly hasOlder: boolean }>
}

export type ChatMentionsOptions = {
  readonly chatId: ChatID
  readonly viewerId: UserID
  readonly client: StoreClient
  readonly chat: MentionsChat
  readonly chunk: MentionsChunkSource
  /** Show a notice (a toast), with an optional action (Undo). */
  readonly notify: (input: MentionNotice) => void
  /** Display names for the notices. */
  readonly nameOf?: (userId: UserID) => string | undefined
  /**
   * Rule 14's add: post `addChatParticipants { chatId, userIds }` (the
   * session's intent, with its final outcome). Without it, both decisions
   * only say who is outside the thread (an older core, a test).
   */
  readonly addParticipants?: (userIds: readonly UserID[]) => ActionHandle
  /** Undo of an auto-add: `removeChatParticipant { chatId, userId }`, one per person. */
  readonly removeParticipant?: (userId: UserID) => ActionHandle
  /** Ask first (the shell's confirmation alert, `MessageActions.ask`): the `prompt` decision. Without it, `prompt` only says so. */
  readonly ask?: (request: ConfirmRequest) => void
  /** Told of every decision that is not `none` (tests, diagnostics). */
  readonly onAddDecision?: (decision: Exclude<MentionAddDecision, { kind: "none" }>) => void
}

/** A notice from the mention models: a toast's fields. */
export type MentionNotice = {
  readonly title: string
  readonly description?: string
  readonly tone?: "neutral" | "success" | "warning" | "error"
  readonly action?: { readonly label: string; readonly onAction: () => void }
}

const none: readonly ComposerSuggestion[] = Object.freeze([])

export class ChatMentions {
  readonly chatId: ChatID
  /** The participants model and suggestions, once the chunk is there and a mention was asked for. */
  readonly loaded: ReadSignal<ChatMentionModels | undefined>
  readonly #options: ChatMentionsOptions
  readonly #loaded = signal<ChatMentionModels | undefined>(undefined)
  #loading: Promise<ChatMentionModels | undefined> | undefined
  #disposed = false

  constructor(options: ChatMentionsOptions) {
    this.#options = options
    this.chatId = options.chatId
    this.loaded = { get: () => this.#loaded.get(), peek: () => this.#loaded.peek() }
  }

  /** The composer's `suggest`. Called inside a computed: it reads signals and never writes one. */
  readonly suggest = (trigger: Trigger): readonly ComposerSuggestion[] => {
    if (trigger.kind !== "mention") return none
    const loaded = this.#loaded.get()
    if (loaded) return loaded.suggestions.suggest(trigger)
    // Loading writes signals; start it after the computed that asked.
    queueMicrotask(() => void this.load())
    return none
  }

  /** Load the chunk and create the models (once). */
  load(): Promise<ChatMentionModels | undefined> {
    const current = this.#loaded.peek()
    if (current || this.#disposed) return Promise.resolve(current)
    this.#loading ??= this.#options.chunk.load().then((chunk) => {
      this.#loading = undefined
      if (!chunk || this.#disposed) return undefined
      const models = this.#loaded.peek() ?? chunk.createChatMentionModels(this.#options)
      this.#loaded.set(models)
      return models
    })
    return this.#loading
  }

  /** A message was accepted with these entities: the rule-14 check. Resolves with the decision, for tests. */
  async afterSend(entities: readonly Entity[] | undefined): Promise<MentionAddDecision> {
    if (!entities?.some((entity) => entity.type === "mention")) return { kind: "none" }
    const loaded = await this.load()
    return loaded && !this.#disposed ? loaded.afterSend(entities) : { kind: "none" }
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    const loaded = this.#loaded.peek()
    this.#loaded.set(undefined)
    loaded?.dispose()
  }
}
