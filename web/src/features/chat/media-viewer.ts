/**
 * The media viewer's model: the photos and videos of the loaded window, the
 * one shown, stepping between them, and the dialog that holds the viewer in
 * the top layer (the kit's `DialogController`: modal, Escape and a backdrop
 * press close it, focus returns where it was). Framework-free; part of the
 * viewer's chunk (`media-viewer-chunk.ts`).
 *
 * What it shows comes from the media layer: the photo at its largest stored
 * size, asked with priority `opened` (`sources.open`) and held while shown
 * (`sources.hold`), so it is not dropped for being off the timeline. No zoom
 * yet; a video plays with the browser's controls.
 */

import type { MessageRow, MessageRowId, PhotoInfo, VideoInfo } from "@inline/core-protocol"
import { computed, effect, signal, type Dispose, type ReadSignal } from "@inline/reactive"
import { DialogController } from "@inline/ui"
import type { OpenMediaInput } from "../content/env"
import type { MediaOwner, MediaSource, MediaSources } from "../content/sources"

export type ViewerItem = {
  readonly key: string
  readonly rowId: MessageRowId
  readonly kind: "photo" | "video"
  readonly photo?: PhotoInfo
  readonly video?: VideoInfo
  readonly owner?: MediaOwner
  /** The media's own size in pixels (its largest stored size for a photo). */
  readonly width: number
  readonly height: number
}

/** The media layer as the viewer uses it: `CoreMediaSources` fits; `open` and `hold` are optional. */
export type ViewerSources = MediaSources & {
  open?(source: MediaSource): void
  hold?(source: MediaSource): Dispose
}

const largest = (photo: PhotoInfo): { width: number; height: number } | undefined => {
  let best: { width: number; height: number } | undefined
  for (const size of photo.sizes) if (!best || size.width * size.height > best.width * best.height) best = size
  return best ? { width: best.width, height: best.height } : undefined
}

const ownerOf = (row: MessageRow): MediaOwner => ({
  chatId: row.chatId,
  messageId: row.messageId,
  attachmentId: row.upload?.attachmentId,
  clientKey: row.clientKey,
  state: row.state,
})

const itemOfRow = (row: MessageRow): ViewerItem | undefined => {
  const media = row.media
  if (!media || ("sticker" in media && media.sticker)) return undefined
  if (media.kind === "photo") {
    const size = largest(media.photo)
    if (!size) return undefined
    return { key: `${row.id}:photo`, rowId: row.id, kind: "photo", photo: media.photo, owner: ownerOf(row), ...size }
  }
  if (media.kind === "video") {
    const { width, height } = media.video
    return { key: `${row.id}:video`, rowId: row.id, kind: "video", video: media.video, owner: ownerOf(row), width, height }
  }
  return undefined
}

const itemOfInput = (input: OpenMediaInput): ViewerItem | undefined => {
  if (input.video) {
    const { width, height } = input.video
    return { key: `${input.rowId}:${input.key}`, rowId: input.rowId, kind: "video", video: input.video, width, height }
  }
  if (input.photo) {
    const size = largest(input.photo)
    if (!size) return undefined
    return { key: `${input.rowId}:${input.key}`, rowId: input.rowId, kind: "photo", photo: input.photo, ...size }
  }
  return undefined
}

/**
 * The photos and videos of the loaded window, oldest first, and the one the
 * user opened. Media that is not a message's own (a block image, a link
 * preview) is shown alone.
 */
export const viewerItems = (
  rows: readonly MessageRow[],
  input: OpenMediaInput,
): { readonly items: readonly ViewerItem[]; readonly index: number } => {
  const items: ViewerItem[] = []
  for (const row of rows) {
    const item = itemOfRow(row)
    if (item) items.push(item)
  }
  const ownMedia = input.kind === "photo" || input.kind === "video" || input.kind === "gif"
  const index = ownMedia ? items.findIndex((item) => item.rowId === input.rowId) : -1
  if (index >= 0) return { items, index }
  const single = itemOfInput(input)
  return { items: single ? [single] : [], index: 0 }
}

export type MediaViewerOptions = {
  readonly items: readonly ViewerItem[]
  readonly index: number
  readonly sources: ViewerSources
  /** The dialog closed (Escape, the backdrop, the close button). */
  readonly onClosed?: () => void
  /** The dialog; tests without a DOM pass a stand-in. Default the kit's. */
  readonly dialog?: (onOpenChange: (open: boolean) => void) => Pick<DialogController, "open" | "close" | "isOpen">
}

export class MediaViewerModel {
  readonly items: readonly ViewerItem[]
  readonly index: ReadSignal<number>
  readonly current: ReadSignal<ViewerItem | undefined>
  /** What the current item shows: its source in the media layer. */
  readonly source: ReadSignal<MediaSource | undefined>
  readonly canPrevious: ReadSignal<boolean>
  readonly canNext: ReadSignal<boolean>
  /** "3 of 12", or undefined for one item. */
  readonly position: ReadSignal<string | undefined>
  readonly dialog: Pick<DialogController, "open" | "close" | "isOpen"> & Partial<Pick<DialogController, "content" | "surface">>
  readonly #index: ReturnType<typeof signal<number>>
  readonly #stop: Dispose
  #disposed = false

  constructor(options: MediaViewerOptions) {
    this.items = options.items
    this.#index = signal(Math.max(0, Math.min(options.index, options.items.length - 1)))
    this.index = { get: () => this.#index.get(), peek: () => this.#index.peek() }
    const { sources } = options
    this.current = computed(() => this.items[this.#index.get()])
    this.source = computed(() => {
      const item = this.current.get()
      if (!item) return undefined
      if (item.kind === "video" && item.video) return sources.video(item.video, item.owner)
      if (item.photo) return sources.photo(item.photo, { width: item.width, height: item.height }, item.owner)
      return undefined
    })
    this.canPrevious = computed(() => this.#index.get() > 0)
    this.canNext = computed(() => this.#index.get() < this.items.length - 1)
    this.position = computed(() => (this.items.length > 1 ? `${this.#index.get() + 1} of ${this.items.length}` : undefined))
    const onOpenChange = (open: boolean) => {
      if (!open) options.onClosed?.()
    }
    this.dialog = options.dialog
      ? options.dialog(onOpenChange)
      : new DialogController({ label: "Media", closeOnBackdropPress: true, onOpenChange })
    // Hold what is shown and ask for it first; let go when it changes.
    this.#stop = effect(() => {
      const source = this.source.get()
      if (!source) return
      sources.open?.(source)
      return sources.hold?.(source)
    })
  }

  open(): void {
    if (!this.#disposed) this.dialog.open()
  }

  close(): void {
    this.dialog.close("button")
  }

  previous(): void {
    if (this.canPrevious.peek()) this.#index.set(this.#index.peek() - 1)
  }

  next(): void {
    if (this.canNext.peek()) this.#index.set(this.#index.peek() + 1)
  }

  /** Left and right step (mirrored in right to left); returns whether the key was taken. */
  key(key: string, dir: "ltr" | "rtl" = "ltr"): boolean {
    const forward = dir === "rtl" ? "ArrowLeft" : "ArrowRight"
    const back = dir === "rtl" ? "ArrowRight" : "ArrowLeft"
    if (key === forward) {
      this.next()
      return true
    }
    if (key === back) {
      this.previous()
      return true
    }
    return false
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stop()
    this.dialog.close("action")
  }
}
