/**
 * Message content for one pane's message list, behind a dynamic import.
 *
 * The content views (media, rich blocks, forms, agent cards, attachments,
 * buttons, service rows: `web/src/features/content/`) are not needed to
 * paint the signed-in shell, so they are their own chunk
 * (`content-chunk.tsx`), preloaded right after the shell's first paint
 * (`Shell.tsx`) and loaded on first use otherwise. Until it arrives a row's
 * content slots render a placeholder that keeps the row's final size where
 * the size is known from the row alone (photos and videos, from
 * `mediaModel`'s box) and paints the blurred preview the row carries
 * (`previews`, the same object URLs the content view then uses, so nothing
 * flashes when it takes over); the rest of the content appears with the
 * chunk, and the timeline keeps the reader's place while it does. The shell
 * loads the chunk right after its first paint (a frame, then a task), not on
 * the idle lane: content that is on the device paints with its row.
 *
 * One `ChatContent` per pane (the pane outlives chat switches): the content
 * environment (`createContentEnv`) is created once when the chunk is there,
 * so its identity is stable, and its handlers act on whichever chat the pane
 * shows when they fire. Framework-free.
 *
 * - **Media**: the session's real media layer (`createCoreMediaSources`,
 *   from the chunk, one per session: `mediaSources`) instead of the CDN
 *   stand-in, and a visibility controller per pane on the timeline's scroll
 *   container (`scroller`), so held media subscribes when it first shows and
 *   media near the viewport is hinted to the core.
 * - **Handlers and names** (`content-handlers.ts`, in the chunk): bot
 *   buttons to the session's `invokeAction`, forms to the chat model's
 *   `submitForm`, photos and videos to the media viewer, links, replies,
 *   compose. The options below are what they act through.
 */

import type { FormSubmissionValue, MessageRowId, rowKey } from "@inline/core-protocol"
import type { ChatID, UserID } from "@inline/ids"
import { effect, signal, untracked, type Dispose, type ReadSignal, type StoreClient } from "@inline/reactive"
import type { ToastTone } from "@inline/ui"
import type { Destination, OpenIntent } from "@inline/view"
import type { ActionHandle } from "@inline/view/features"
import type { ContentEnv, MediaSources, OpenMediaInput } from "../content"
import { PreviewUrls } from "../content/preview-urls"
import type { ContentChunk } from "./content-chunk"
import type { DownloadTarget } from "./download"
import type { ConfirmRequest } from "./message-actions"

/** The chunk as a loadable (`AppViews.content`). */
export type ContentChunkSource = {
  readonly value: ReadSignal<ContentChunk | undefined>
}

/** A timeline's visibility hints (`MediaVisibility` fits). */
export type ContentVisibility = { attach(container: Element): Dispose; dispose(): void }

/** The session's media layer as the pane uses it (`CoreMediaSources` fits). */
export type PaneMediaSources = MediaSources & { createVisibility?(): ContentVisibility }

export type ContentToast = { readonly title: string; readonly description?: string; readonly tone?: ToastTone }

export type ChatContentOptions = {
  readonly chunk: ContentChunkSource
  /** The session's rows, for names (`store.peekRow`). */
  readonly peekRow: (key: ReturnType<typeof rowKey>) => unknown
  readonly userId: UserID
  /** The chat the pane shows now (handlers act on it). */
  readonly currentChatId: () => ChatID | undefined
  readonly open: (destination: Destination, intent?: OpenIntent) => void
  /** Whether reply threads open beside the chat (`preferences.replyThreadsInSidePane`). */
  readonly threadsInSidePane: () => boolean
  readonly parseAppLink: (href: string) => Destination | undefined
  readonly openExternal: (url: string) => void
  readonly copyText: (text: string) => void
  /** Put text in the pane's composer without sending (prompt suggestions, compose buttons). */
  readonly compose?: (text: string) => void
  /** The session's media layer, made from the chunk once per session. Default: the CDN stand-in. */
  readonly mediaSources?: (chunk: ContentChunk) => PaneMediaSources
  /** A bot button's callback (`session.actions.invokeAction` for the row). */
  readonly invokeAction?: (rowId: MessageRowId, actionId: string) => ActionHandle | undefined
  /** A form's submit (`ChatModel.submitForm` for the row). */
  readonly submitForm?: (rowId: MessageRowId, formId: string, values: readonly FormSubmissionValue[]) => ActionHandle | undefined
  /** Ask first (the shell's confirmation alert). Without it, a button with a confirm step runs at once. */
  readonly confirm?: (request: ConfirmRequest) => void
  /** Show a toast. */
  readonly toast?: (toast: ContentToast) => void
  /** Open the media viewer at this media, over the media layer the content uses. */
  readonly openMedia?: (input: OpenMediaInput, sources: MediaSources) => void
  /**
   * A document's Download: the row's file from the core (`client`, the row's
   * message by `target`), saved under `downloadFileName(...)` by `save`
   * (default: an `<a download>` over an object URL). The work is in the
   * content chunk (`content-handlers.ts`, `download.ts`).
   */
  readonly files?: {
    readonly client: Pick<StoreClient, "subscribe">
    readonly target: (rowId: MessageRowId) => DownloadTarget | undefined
    readonly save?: (blob: Blob, name: string) => void
  }
}

export class ChatContent {
  /** The chunk, once loaded. */
  readonly chunk: ReadSignal<ContentChunk | undefined>
  /** The list's content environment, once the chunk is there. Stable from then on. */
  readonly env: ReadSignal<ContentEnv | undefined>
  /** The rows' blurred previews as object URLs: the placeholders use them before the chunk, the content view after. */
  readonly previews: PreviewUrls
  readonly #options: ChatContentOptions
  readonly #env = signal<ContentEnv | undefined>(undefined)
  #sources: PaneMediaSources | undefined
  #visibility: ContentVisibility | undefined
  #scroller: Element | undefined
  #detachVisibility: Dispose | undefined
  readonly #stop: Dispose
  #disposed = false

  constructor(options: ChatContentOptions) {
    this.#options = options
    this.chunk = options.chunk.value
    this.previews = new PreviewUrls()
    this.env = { get: () => this.#env.get(), peek: () => this.#env.peek() }
    this.#stop = effect(() => {
      const chunk = options.chunk.value.get()
      if (chunk) untracked(() => this.#create(chunk))
    })
  }

  /**
   * Part for the timeline's scroll container (the element whose viewport
   * decides what is visible): the media layer's visibility hints for this
   * pane attach to it once the chunk is there.
   */
  readonly scroller = (element: Element): Dispose => {
    this.#scroller = element
    this.#attachVisibility()
    return () => {
      if (this.#scroller !== element) return
      this.#scroller = undefined
      this.#detachVisibility?.()
      this.#detachVisibility = undefined
    }
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stop()
    this.#detachVisibility?.()
    this.#visibility?.dispose()
    this.previews.dispose()
    this.#env.set(undefined)
  }

  #create(chunk: ContentChunk): void {
    if (this.#disposed || this.#env.peek()) return
    const sources = this.#options.mediaSources?.(chunk)
    this.#sources = sources
    // The handlers and names are part of the chunk (`content-handlers.ts`): nothing calls them before it is here.
    this.#env.set(
      chunk.createContentEnv({
        handlers: chunk.contentHandlers(this.#options, () => this.#env.peek()?.sources ?? this.#sources),
        names: chunk.contentNames(this.#options.peekRow),
        me: this.#options.userId,
        previews: this.previews,
        ...(sources ? { sources } : {}),
      }),
    )
    this.#visibility = sources?.createVisibility?.()
    this.#attachVisibility()
  }

  #attachVisibility(): void {
    const visibility = this.#visibility
    const scroller = this.#scroller
    if (!visibility || !scroller) return
    this.#detachVisibility?.()
    this.#detachVisibility = visibility.attach(scroller)
  }
}
