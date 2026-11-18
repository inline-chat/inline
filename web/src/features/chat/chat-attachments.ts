/**
 * Attachments for the chat panes of a session (`web/src/features/media/README.md`,
 * "What the chat pane does", and `composer/README.md`, "Attachments"),
 * with the model loaded on the first file. Framework-free.
 *
 * - `SessionAttachments` (one per session) loads `attachments-chunk.ts` when
 *   the first file arrives and then holds the session's `AttachmentDrafts`
 *   (attachments per chat, which outlive a composer). Optimistic rows go to
 *   the end of the chat's window in the same frame when the window is at
 *   the latest message (`placeRows`, from the chat models the panes
 *   register). `dispose()` on sign-out.
 * - `LazyAttachments` (one per composer) is the chat's `ComposerAttachments`
 *   before and after the chunk: empty until a file arrives, then the
 *   drafts' object for the chat. It is what `ComposerView` gets, so the
 *   Attach button is there in the first frame and nothing moves when the
 *   model arrives.
 * - `attachmentOptions(lazy, options)` is `withAttachments` for a lazy model:
 *   paste and drop add files, Send is enabled with attachments and no text,
 *   attachments go as `sendMedia`, and the attachment reasons have words.
 */

import type { MessageRow } from "@inline/core-protocol"
import type { ChatID, UserID } from "@inline/ids"
import { computed, effect, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import type { AttachmentDrafts, AttachmentsClient, ComposerAttachments, PendingAttachment, UploadActivity } from "../composer/attachments"
import type { ComposerModelOptions } from "../composer/model"
import { DropTarget } from "../composer/drop-target"
import { sendErrorText } from "../composer/text"
import type { AttachmentsChunk } from "./attachments-chunk"

/** The chunk as a loadable (`AppViews.attachments`). */
export type AttachmentsChunkSource = {
  readonly value: ReadSignal<AttachmentsChunk | undefined>
  load(): Promise<AttachmentsChunk | undefined>
}

/** A chat's window, for placing optimistic rows (`ChatModel` fits). */
export type AttachmentWindow = {
  readonly windowSub: number
  readonly window: ReadSignal<{ readonly atLatest: boolean }>
}

export type SessionAttachmentsOptions = {
  readonly chunk: AttachmentsChunkSource
  readonly client: AttachmentsClient
  readonly userId: UserID
  /**
   * The strip's view (`attachmentStripChunk.load` in the app, the chunk
   * table's `attachmentStrip`): started with the model on the first file, so
   * the two load side by side rather than one after the other.
   */
  readonly loadStripView?: () => unknown
}

export class SessionAttachments {
  readonly drafts: ReadSignal<AttachmentDrafts | undefined>
  readonly #options: SessionAttachmentsOptions
  readonly #drafts = signal<AttachmentDrafts | undefined>(undefined)
  readonly #windows = new Map<ChatID, AttachmentWindow[]>()
  #loading: Promise<AttachmentDrafts | undefined> | undefined
  #disposed = false

  constructor(options: SessionAttachmentsOptions) {
    this.#options = options
    this.drafts = { get: () => this.#drafts.get(), peek: () => this.#drafts.peek() }
  }

  /** Load the model and create the session's drafts (once), and the strip's view beside it. */
  load(): Promise<AttachmentDrafts | undefined> {
    const current = this.#drafts.peek()
    if (current || this.#disposed) return Promise.resolve(current)
    if (!this.#loading) this.#options.loadStripView?.()
    this.#loading ??= this.#options.chunk.load().then((chunk) => {
      this.#loading = undefined
      if (!chunk || this.#disposed) return undefined
      const drafts =
        this.#drafts.peek() ??
        chunk.createAttachmentDrafts({
          client: this.#options.client,
          userId: this.#options.userId,
          placeRows: (row) => this.#place(row),
        })
      this.#drafts.set(drafts)
      return drafts
    })
    return this.#loading
  }

  /** Words for an attachment reason, once the model is there (it is whenever one can occur). */
  errorText(reason: string): string | null {
    return this.#options.chunk.value.peek()?.attachmentSendErrorText(reason) ?? null
  }

  /** The chat's attachments for one composer. */
  forChat(chatId: ChatID): LazyAttachments {
    return new LazyAttachments(chatId, this)
  }

  /**
   * Report a chat's uploads through its compose reporter ("sending photo")
   * with the composer's `followUploadActivity`, from when the model's chunk
   * is there (nothing uploads before). Returns the dispose, which ends a
   * running activity.
   */
  followUploads(activity: ReadSignal<UploadActivity | null>, reporter: { beginActivity(kind: UploadActivity): () => void }): Dispose {
    let stop: Dispose | undefined
    const watch = effect(() => {
      const chunk = this.#options.chunk.value.get()
      if (!chunk || stop) return
      untracked(() => {
        stop = chunk.followUploadActivity(activity, reporter)
      })
    })
    return () => {
      watch()
      stop?.()
      stop = undefined
    }
  }

  /** A pane shows this chat's window: optimistic media rows join its end. */
  registerWindow(chatId: ChatID, window: AttachmentWindow): Dispose {
    const list = this.#windows.get(chatId) ?? []
    list.push(window)
    this.#windows.set(chatId, list)
    return () => {
      const current = this.#windows.get(chatId)
      const index = current?.indexOf(window) ?? -1
      if (index >= 0) current?.splice(index, 1)
      if (current?.length === 0) this.#windows.delete(chatId)
    }
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#drafts.peek()?.dispose()
    this.#drafts.set(undefined)
    this.#windows.clear()
  }

  #place(row: MessageRow): { row: MessageRow; appendTo?: readonly number[] } {
    const window = this.#windows.get(row.chatId)?.at(-1)
    return window && window.window.peek().atLatest ? { row, appendTo: [window.windowSub] } : { row }
  }
}

const noItems: readonly PendingAttachment[] = Object.freeze([])

export class LazyAttachments implements ComposerAttachments {
  readonly chatId: ChatID
  readonly items: ReadSignal<readonly PendingAttachment[]>
  readonly hasAttachments: ReadSignal<boolean>
  readonly notice: ReadSignal<string | null>
  /** The strongest upload of a sent attachment still running (`followUploadActivity` reports it), or null. */
  readonly activity: ReadSignal<UploadActivity | null>
  /** The drafts' object for this chat, once the model is there and this chat has used it. */
  readonly inner: ReadSignal<ComposerAttachments | undefined>
  readonly #session: SessionAttachments
  readonly #inner = signal<ComposerAttachments | undefined>(undefined)

  constructor(chatId: ChatID, session: SessionAttachments) {
    this.chatId = chatId
    this.#session = session
    this.inner = { get: () => this.#inner.get(), peek: () => this.#inner.peek() }
    // Attachments added earlier in this chat (another composer, before a switch) come back.
    const drafts = session.drafts.peek()
    if (drafts) this.#inner.set(drafts.forChat(chatId))
    this.items = computed(() => this.#inner.get()?.items.get() ?? noItems)
    this.hasAttachments = computed(() => this.#inner.get()?.hasAttachments.get() ?? false)
    this.notice = computed(() => this.#inner.get()?.notice.get() ?? null)
    this.activity = computed(() => this.#inner.get()?.activity?.get() ?? null)
  }

  add(files: readonly Blob[]): void {
    if (files.length === 0) return
    const inner = this.#inner.peek()
    if (inner) {
      inner.add(files)
      return
    }
    void this.#session.load().then((drafts) => {
      if (!drafts) return
      const attachments = this.#inner.peek() ?? drafts.forChat(this.chatId)
      this.#inner.set(attachments)
      attachments.add(files)
    })
  }

  remove(id: Parameters<ComposerAttachments["remove"]>[0]): void {
    this.#inner.peek()?.remove(id)
  }

  retry(id: Parameters<ComposerAttachments["retry"]>[0]): void {
    this.#inner.peek()?.retry(id)
  }

  dismissNotice(): void {
    this.#inner.peek()?.dismissNotice()
  }

  send(request: Parameters<ComposerAttachments["send"]>[0]): ReturnType<ComposerAttachments["send"]> {
    const inner = this.#inner.peek()
    if (inner) return inner.send(request)
    return Promise.resolve({ status: "rejected", reason: "invalid" })
  }

  wrapSend(textSend: Parameters<ComposerAttachments["wrapSend"]>[0]): ReturnType<ComposerAttachments["wrapSend"]> {
    let wrapped: { inner: ComposerAttachments; send: ReturnType<ComposerAttachments["wrapSend"]> } | undefined
    return (request) => {
      const inner = this.#inner.peek()
      if (!inner) return Promise.resolve(textSend(request))
      if (wrapped?.inner !== inner) wrapped = { inner, send: inner.wrapSend(textSend) }
      return wrapped.send(request)
    }
  }

  /** Nothing to release here: the session's drafts own the chat's attachments. */
  dispose(): void {}

  discardAll(): void {
    this.#inner.peek()?.discardAll()
  }
}

/** `withAttachments` over a lazy model: what the composer model needs for files. */
export const attachmentOptions = (
  attachments: LazyAttachments,
  session: SessionAttachments,
  options: ComposerModelOptions,
): ComposerModelOptions => {
  const describe = options.errorText ?? sendErrorText
  return {
    ...options,
    send: attachments.wrapSend(options.send),
    onFiles: (files) => {
      attachments.add(files)
      options.onFiles?.(files)
    },
    hasAttachments: attachments.hasAttachments,
    errorText: (reason) => session.errorText(reason) ?? describe(reason),
  }
}

/**
 * Files dragged over a chat pane go to the chat's attachments, also while a
 * message is being edited: as on the Mac (`GlassComposeAppKit.handleFileDrop`
 * checks only `canMutateDraft`), the file joins the strip, Save sends only
 * the edit, and the file goes with the next message. Without attachments the
 * pane takes no files.
 */
export const chatDropTarget = (attachments: Pick<ComposerAttachments, "add"> | undefined): DropTarget =>
  new DropTarget({
    onFiles: (files) => attachments?.add(files),
    enabled: () => attachments !== undefined,
  })
