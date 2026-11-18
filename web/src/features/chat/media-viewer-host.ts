/**
 * Where the media viewer opens from: one per session (`ShellModel`). A
 * photo or video clicked in a message (`ContentHandlers.onOpenMedia`) loads
 * the viewer's chunk on first use (`media-viewer-chunk.ts`), builds its
 * model over the loaded window's rows, and publishes it for the shell to
 * render; closing disposes it. Framework-free.
 */

import type { MessageRow } from "@inline/core-protocol"
import { signal, type ReadSignal } from "@inline/reactive"
import type { OpenMediaInput } from "../content/env"
import type { MediaViewerModel, ViewerSources } from "./media-viewer"
import type { MediaViewerChunk } from "./media-viewer-chunk"

/** The chunk as a loadable (`AppViews.mediaViewer`). */
export type MediaViewerChunkSource = {
  readonly value: ReadSignal<MediaViewerChunk | undefined>
  load(): Promise<MediaViewerChunk | undefined>
}

export type OpenMediaRequest = {
  readonly input: OpenMediaInput
  /** The rows of the window the media was opened from, oldest first. */
  readonly rows: () => readonly MessageRow[]
  readonly sources: ViewerSources
}

/** The app's keyboard dispatcher, for a modal layer while the viewer is open (`KeyboardDispatcher` fits). */
export type ViewerKeyboard = { pushLayer(scope: string, options?: { modal?: boolean }): () => void }

export class MediaViewerHost {
  /** The open viewer, for the shell to render. */
  readonly viewer: ReadSignal<MediaViewerModel | undefined>
  readonly #chunk: MediaViewerChunkSource
  readonly #viewer = signal<MediaViewerModel | undefined>(undefined)
  readonly #keyboard: ViewerKeyboard | undefined
  #popLayer: (() => void) | undefined
  #request = 0
  #disposed = false

  constructor(chunk: MediaViewerChunkSource, keyboard?: ViewerKeyboard) {
    this.#chunk = chunk
    this.#keyboard = keyboard
    this.viewer = { get: () => this.#viewer.get(), peek: () => this.#viewer.peek() }
  }

  /** Open the viewer at this media. A later open replaces an earlier one still loading. */
  open(request: OpenMediaRequest): Promise<MediaViewerModel | undefined> {
    if (this.#disposed) return Promise.resolve(undefined)
    const id = ++this.#request
    const create = (chunk: MediaViewerChunk | undefined): MediaViewerModel | undefined => {
      if (!chunk || this.#disposed || id !== this.#request) return undefined
      const { items, index } = chunk.viewerItems(request.rows(), request.input)
      if (items.length === 0) return undefined
      this.close()
      const model: MediaViewerModel = new chunk.MediaViewerModel({
        items,
        index,
        sources: request.sources,
        onClosed: () => {
          if (this.#viewer.peek() !== model) return
          this.close()
        },
      })
      this.#viewer.set(model)
      // The app's shortcuts do not fire under the viewer (it is modal, like the kit's dialogs).
      this.#popLayer = this.#keyboard?.pushLayer("dialog", { modal: true })
      model.open()
      return model
    }
    const loaded = this.#chunk.value.peek()
    return loaded ? Promise.resolve(create(loaded)) : this.#chunk.load().then(create)
  }

  close(): void {
    this.#popLayer?.()
    this.#popLayer = undefined
    const current = this.#viewer.peek()
    if (!current) return
    this.#viewer.set(undefined)
    current.dispose()
  }

  dispose(): void {
    this.#disposed = true
    this.close()
  }
}
