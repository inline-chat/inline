/**
 * Message actions for a signed-in session: what only views can do for the
 * session's `SessionActions` (`@inline/view/features`, `session.actions`),
 * and the row actions the message lists show.
 *
 * - `attach()` connects the hooks (`session.attachActions`): reply and edit
 *   go to the composer of the pane showing the message's chat (each chat
 *   composer registers itself), copy text and copy link go to the clipboard,
 *   Add Reaction… opens the reaction picker, refusals and uncertain outcomes
 *   become toasts in the tone the model gives them (`uncertain` is a warning
 *   that says "Not confirmed yet", `offline` says so; never "failed"), and a
 *   bot's answer becomes a toast.
 * - Delete asks first, on every path: the hooks include `confirmDelete`,
 *   which `SessionActions.delete` (the one function the row menu, the quick
 *   actions, the `message.delete` command (Mod+Backspace), the command bar
 *   and any later native menu all end in) calls before deleting a sent
 *   message. A message still sending is cancelled without asking (the
 *   Mac's Cancel); the session decides that, not this file.
 * - `actionsFor(rowId)`: the session's row actions (their Delete asks
 *   through the hook above).
 * - `ask(...)`: the same alert for anything else that confirms first (a bot
 *   button with a confirm step).
 * - The picker's anchor: each chat list registers its row actions
 *   (`registerPickerAnchors`); a picker opened from the menu or a command
 *   points at the row's Add Reaction button (`reactionAnchor`), and the row
 *   stays active while it is open (`setPickerAnchor`, cleared on close).
 * - The reaction picker (`picker`, a popover: the emoji feature's quick row
 *   and full picker once the emoji code is there, a few common emoji before) and
 *   the confirmation (`confirm`, an alert dialog) are rendered once by
 *   `MessageActionLayers.tsx`. Neither is on the first frame, so their code
 *   (the kit's popover and dialog, the layer views) is a chunk of its own
 *   (`src/app/layers-chunk.ts`), warmed right after the first paint. A
 *   question asked before it arrives waits for it and opens with it; a
 *   picker likewise. Nothing runs until the user answers, so a delete is
 *   never lost or done unasked; if the chunk cannot load, the question is
 *   declined with a toast.
 *
 * Framework-free; the shell creates one per session with `useModel`.
 */

import type { ActionAnswer, MessageRow, MessageRowId } from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { computed, signal, type Dispose, type ReadSignal } from "@inline/reactive"
import type { DialogController, PopoverController, Rect, ToastTone } from "@inline/ui"
import { toAppUrl, type Destination } from "@inline/view"
import type { UserID } from "@inline/ids"
import type { ActionHooks, ActionNotice, MessageTarget, SessionActions } from "@inline/view/features"
import type { MessageAction } from "../message"

/** The few reactions the picker offers until the emoji picker's code is there (first use right after load). */
export const QUICK_REACTIONS: readonly string[] = ["👍", "❤️", "😂", "😮", "😢", "🙏", "🔥", "✅"]

/** What reply and edit need from a chat's composer (`ComposerModel` fits). */
export type ActionComposer = {
  readonly composer: {
    setReply(target: { messageId: MessageID } | null): void
    startEdit(target: { messageId: MessageID }, content: { text: string; entities?: MessageRow["entities"] }): void
  }
  focus(): boolean
}

export type MessageActionsOptions = {
  readonly session: {
    readonly userId: UserID
    readonly actions: Pick<SessionActions, "actionsFor" | "target" | "toggleReaction">
    attachActions(hooks: ActionHooks): () => void
  }
  /** Write text to the clipboard. */
  readonly copyText: (text: string) => Promise<boolean> | void
  /** Show a toast. */
  readonly toast: (input: { id?: string; title: string; description?: string; tone?: ToastTone }) => void
  /** The page's origin for message links. Default the app's. */
  readonly origin?: string
  /** True while the page has a non-empty text selection (Copy Text then leaves Cmd/Ctrl+C to the browser). */
  readonly isTextSelected?: () => boolean
  /** The rectangle of a message row on screen, to anchor the picker when the menu (not a button) opened it. */
  readonly rowRect?: (rowId: MessageRowId) => Rect | null
  /**
   * The picker's and the confirmation's controllers, made on first need
   * (or when warmed): the kit's (`kitLayers` in the layers chunk) in the
   * app, stand-ins in tests without a DOM. Without it nothing opens.
   */
  readonly layers?: MessageLayersFactory
  /** The picker was asked for (the app starts loading the emoji picker then, if it has not yet). */
  readonly onOpenPicker?: () => void
}

export type MessageLayerCallbacks = { pickerClosed(): void; confirmClosed(): void; anchor(): Rect | null }

/** The two top-layer controllers message actions drive. */
export type MessageLayers = {
  readonly picker: PopoverController
  readonly confirm: DialogController
}

export type MessageLayersFactory = (callbacks: MessageLayerCallbacks) => MessageLayers | Promise<MessageLayers>

/** Said when the layers' code could not load (offline on a first visit). */
export const layersUnavailableText = {
  title: "Couldn't open that",
  description: "Check your connection and try again.",
} as const

/**
 * A chat list's row actions, for the reaction picker's anchor
 * (`MessageActionsController` fits): while the picker is open for a row
 * that row stays active, so its capsule (the picker's anchor) stays on
 * screen; a picker opened from the menu or a command points at the row's
 * Add Reaction button, else its bubble.
 */
export type PickerAnchors = {
  setPickerAnchor(rowId: MessageRowId | null, rect?: Rect): void
  reactionAnchor(rowId: MessageRowId): Rect | null
}

/** A delete waiting for the user's answer. */
export type PendingDelete = { readonly target: MessageTarget; readonly run: () => void }

/** Something waiting for the user's answer in the confirmation alert. */
export type ConfirmRequest = {
  readonly title: string
  readonly description?: string
  /**
   * A line under the description in the app's own words: what a bot button
   * really does ("Opens example.com"), which the bot's title and text may
   * not say (`buttonDisclosure`).
   */
  readonly detail?: string
  readonly confirmLabel: string
  /** Draw the confirm button as destructive. */
  readonly destructive?: boolean
  readonly run: () => void
  /** Called when the user declines (Cancel, Escape). */
  readonly cancel?: () => void
  /** Set for a message delete. */
  readonly target?: MessageTarget
}

export const deleteConfirmText = {
  title: "Delete message?",
  description: "It will be deleted for everyone in this chat. This can't be undone.",
  confirmLabel: "Delete",
} as const

export class MessageActions {
  /** The picker and the confirmation, once made (`loadLayers`). The shell renders them from then on. */
  readonly layers: ReadSignal<MessageLayers | undefined>
  /** The message the picker reacts to, while it is open (or waiting for its layer). */
  readonly pickerTarget: ReadSignal<MessageTarget | undefined>
  /** What the alert asks, while it is open (or waiting for its layer). */
  readonly pendingConfirm: ReadSignal<ConfirmRequest | undefined>
  /** The delete the alert asks about, if it is one. */
  readonly pendingDelete: ReadSignal<PendingDelete | undefined>

  readonly #options: MessageActionsOptions
  readonly #composers = new Map<ChatID, ActionComposer[]>()
  readonly #anchors = new Map<ChatID, PickerAnchors[]>()
  /** The list holding the open picker's anchor. */
  #anchored: PickerAnchors | undefined
  readonly #pickerTarget = signal<MessageTarget | undefined>(undefined)
  readonly #pending = signal<ConfirmRequest | undefined>(undefined)
  readonly #layers = signal<MessageLayers | undefined>(undefined)
  #layersLoad: Promise<MessageLayers | undefined> | undefined
  #pickerAnchor: Rect | null = null
  #detach: Dispose | undefined
  #disposed = false

  constructor(options: MessageActionsOptions) {
    this.#options = options
    this.pickerTarget = { get: () => this.#pickerTarget.get(), peek: () => this.#pickerTarget.peek() }
    this.pendingConfirm = { get: () => this.#pending.get(), peek: () => this.#pending.peek() }
    const asDelete = (pending: ConfirmRequest | undefined): PendingDelete | undefined =>
      pending?.target ? { target: pending.target, run: pending.run } : undefined
    const pendingDelete = computed(() => asDelete(this.#pending.get()))
    this.pendingDelete = { get: () => pendingDelete.get(), peek: () => asDelete(this.#pending.peek()) }
    this.layers = { get: () => this.#layers.get(), peek: () => this.#layers.peek() }
  }

  /** The reaction picker, once its layer is made. */
  get picker(): PopoverController | undefined {
    return this.#layers.peek()?.picker
  }

  /** The confirmation alert, once its layer is made. */
  get confirm(): DialogController | undefined {
    return this.#layers.peek()?.confirm
  }

  /**
   * Make the picker and the confirmation (loading their code first in the
   * app). The shell calls it on the idle lane after the first paint; asking
   * or opening the picker earlier calls it too. Resolves to undefined if it
   * could not (and a later call tries again).
   */
  loadLayers(): Promise<MessageLayers | undefined> {
    const ready = this.#layers.peek()
    if (ready) return Promise.resolve(ready)
    const factory = this.#options.layers
    if (!factory || this.#disposed) return Promise.resolve(undefined)
    if (this.#layersLoad) return this.#layersLoad
    const install = (layers: MessageLayers): MessageLayers | undefined => {
      if (this.#disposed) return undefined
      this.#layers.set(layers)
      return layers
    }
    let made: MessageLayers | Promise<MessageLayers>
    try {
      made = factory(this.#layerCallbacks())
    } catch (error) {
      return Promise.reject(error instanceof Error ? error : new Error(String(error)))
    }
    if (!isPromise(made)) return Promise.resolve(install(made))
    const load = made.then(install, (error: unknown) => {
      this.#layersLoad = undefined
      throw error
    })
    this.#layersLoad = load
    return load
  }

  #layerCallbacks(): MessageLayerCallbacks {
    return {
      pickerClosed: () => {
        this.#pickerTarget.set(undefined)
        this.#releaseAnchor()
      },
      confirmClosed: () => {
        // Closed without the confirm button (Cancel, Escape, the session ending): declined.
        const pending = this.#pending.peek()
        if (!pending) return
        this.#pending.set(undefined)
        pending.cancel?.()
      },
      anchor: () => this.#pickerAnchor,
    }
  }

  /** Run `open` with the layers: now if they are made, else when they are (if `still()` then). */
  #withLayers(open: (layers: MessageLayers) => void, still: () => boolean, decline: () => void): void {
    const load = this.loadLayers()
    // Made already, or just now by a synchronous factory.
    const ready = this.#layers.peek()
    if (ready) {
      open(ready)
      return
    }
    load.then(
      (layers) => {
        if (layers && still()) open(layers)
      },
      () => {
        if (!still()) return
        decline()
        this.#options.toast({ id: "message-layers", ...layersUnavailableText, tone: "error" })
      },
    )
  }

  /** Connect the session's action hooks, the delete confirmation among them. Returns the function that disconnects them. */
  attach(): Dispose {
    this.#detach?.()
    const detach = this.#options.session.attachActions(this.hooks())
    this.#detach = detach
    return () => {
      detach()
      if (this.#detach === detach) this.#detach = undefined
    }
  }

  /** Ask in the confirmation alert; `run` on confirm, `cancel` otherwise. A new question replaces an open one (declining it). */
  ask(request: ConfirmRequest): void {
    const previous = this.#pending.peek()
    if (previous) {
      this.#pending.set(undefined)
      previous.cancel?.()
    }
    this.#pending.set(request)
    this.#withLayers(
      (layers) => layers.confirm.open(),
      () => this.#pending.peek() === request,
      () => {
        this.#pending.set(undefined)
        request.cancel?.()
      },
    )
  }

  /** The hooks `session.attachActions` takes. */
  hooks(): ActionHooks {
    const options = this.#options
    return {
      reply: (target) => this.#withComposer(target, (composer, messageId) => composer.composer.setReply({ messageId })),
      edit: (target) =>
        this.#withComposer(target, (composer, messageId) =>
          composer.composer.startEdit(
            { messageId },
            { text: target.row.text, ...(target.row.entities ? { entities: target.row.entities } : {}) },
          ),
        ),
      copyText: (text) => void options.copyText(text),
      copyLink: (destination: Destination) =>
        void options.copyText(toAppUrl(destination, options.origin ?? "https://app.inline.chat")),
      openReactionPicker: (target, anchor) => this.openPicker(target, isRect(anchor) ? anchor : undefined),
      notify: (notice: ActionNotice) =>
        options.toast({ id: `action:${notice.kind}`, title: notice.title, description: notice.text, tone: notice.tone }),
      answer: (answer: ActionAnswer) =>
        options.toast(
          answer.kind === "alert" && answer.title
            ? { title: answer.title, description: answer.text, tone: "neutral" }
            : { title: answer.text, tone: "neutral" },
        ),
      // Every delete of a sent message asks first (`SessionActions.delete` calls this; a sending one is cancelled at once).
      confirmDelete: (target, proceed) => this.ask({ ...deleteConfirmText, destructive: true, target, run: proceed }),
      ...(options.isTextSelected ? { isTextSelected: options.isTextSelected } : {}),
    }
  }

  /** A row's actions for `MessageActionsController` (Delete asks through `confirmDelete`). */
  readonly actionsFor = (rowId: MessageRowId): readonly MessageAction[] =>
    this.#options.session.actions.actionsFor(rowId) as readonly MessageAction[]

  /** The user confirmed what the alert asks. */
  confirmPending(): void {
    const pending = this.#pending.peek()
    this.#pending.set(undefined)
    this.confirm?.close("action")
    pending?.run()
  }

  /** The user declined. */
  cancelPending(): void {
    if (this.confirm?.isOpen.peek()) {
      this.confirm.close("button")
      return
    }
    // Still waiting for its layer: decline here.
    const pending = this.#pending.peek()
    this.#pending.set(undefined)
    pending?.cancel?.()
  }

  /** @deprecated `confirmPending`. */
  confirmDelete(): void {
    this.confirmPending()
  }

  /** @deprecated `cancelPending`. */
  cancelDelete(): void {
    this.cancelPending()
  }

  /**
   * Open the picker for a message: at a quick action's rectangle, else at
   * the row's Add Reaction button or bubble (the chat's list, when one shows
   * it), else at the row. The list keeps the row active while it is open.
   */
  openPicker(target: MessageTarget, anchor?: Rect): void {
    this.#options.onOpenPicker?.()
    this.#releaseAnchor()
    const anchors = this.#anchors.get(target.chatId)?.at(-1)
    const rect = anchor ?? anchors?.reactionAnchor(target.rowId) ?? this.#options.rowRect?.(target.rowId) ?? null
    this.#pickerAnchor = rect
    if (anchors) {
      anchors.setPickerAnchor(target.rowId, rect ?? undefined)
      this.#anchored = anchors
    }
    this.#pickerTarget.set(target)
    this.#withLayers(
      (layers) => layers.picker.open(),
      () => this.#pickerTarget.peek() === target,
      () => {
        this.#pickerTarget.set(undefined)
        this.#releaseAnchor()
      },
    )
  }

  /** A chat's list, while a pane shows it: where its pickers point. The newest registration wins (two panes on one chat). */
  registerPickerAnchors(chatId: ChatID, anchors: PickerAnchors): Dispose {
    const list = this.#anchors.get(chatId) ?? []
    list.push(anchors)
    this.#anchors.set(chatId, list)
    return () => {
      if (this.#anchored === anchors) this.#releaseAnchor()
      const current = this.#anchors.get(chatId)
      const index = current?.indexOf(anchors) ?? -1
      if (index >= 0) current?.splice(index, 1)
      if (current?.length === 0) this.#anchors.delete(chatId)
    }
  }

  #releaseAnchor(): void {
    const anchored = this.#anchored
    this.#anchored = undefined
    anchored?.setPickerAnchor(null)
  }

  /** A reaction was chosen in the picker. */
  choose(emoji: string): void {
    const target = this.#pickerTarget.peek()
    this.picker?.close()
    this.#pickerTarget.set(undefined)
    this.#releaseAnchor()
    if (target) this.#options.session.actions.toggleReaction(target, emoji)
  }

  /** A reaction chip on a row: add or remove the viewer's reaction. */
  toggleReaction(rowId: MessageRowId, emoji: string): void {
    const target = this.#options.session.actions.target(rowId)
    if (target) this.#options.session.actions.toggleReaction(target, emoji)
  }

  /** A chat's composer, while its pane shows it. The newest registration wins (two panes on one chat). */
  registerComposer(chatId: ChatID, composer: ActionComposer): Dispose {
    const list = this.#composers.get(chatId) ?? []
    list.push(composer)
    this.#composers.set(chatId, list)
    return () => {
      const current = this.#composers.get(chatId)
      if (!current) return
      const index = current.indexOf(composer)
      if (index >= 0) current.splice(index, 1)
      if (current.length === 0) this.#composers.delete(chatId)
    }
  }

  dispose(): void {
    this.#disposed = true
    this.#detach?.()
    this.#detach = undefined
    this.picker?.close()
    this.confirm?.close("action")
    this.#pending.set(undefined)
    this.#pickerTarget.set(undefined)
    this.#releaseAnchor()
    this.#composers.clear()
    this.#anchors.clear()
  }

  #withComposer(target: MessageTarget, act: (composer: ActionComposer, messageId: MessageID) => void): void {
    const composer = this.#composers.get(target.chatId)?.at(-1)
    if (!composer || target.messageId === undefined) return
    act(composer, target.messageId)
    composer.focus()
  }
}

const isPromise = <T>(value: T | Promise<T>): value is Promise<T> =>
  typeof (value as Promise<T> | undefined)?.then === "function"

const isRect = (value: unknown): value is Rect =>
  typeof value === "object" &&
  value !== null &&
  typeof (value as Rect).x === "number" &&
  typeof (value as Rect).y === "number" &&
  typeof (value as Rect).width === "number" &&
  typeof (value as Rect).height === "number"

/** What the emoji reaction picker needs from the message it opened for: its text (its own emoji first) and the viewer's reactions. */
export const reactionTarget = (target: MessageTarget | undefined): { messageText: string | null; mine: string[] } => ({
  messageText: target?.row.text ?? null,
  mine: target?.row.reactions?.filter((reaction) => reaction.mine).map((reaction) => reaction.emoji) ?? [],
})

/** The row element of a message, by its row ID (`data-message-row`). */
export const messageRowRect = (doc: Document, rowId: MessageRowId): Rect | null => {
  const element = doc.querySelector(`[data-message-row="${CSS.escape(rowId)}"]`)
  if (!element) return null
  const r = element.getBoundingClientRect()
  return { x: r.left, y: r.top, width: r.width, height: r.height }
}
