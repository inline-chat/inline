/**
 * The attachment strip's chunk (`AttachmentStripView.tsx`), loaded when the
 * first file is added (`ComposerAttachments.add` calls `load`), so a
 * composer without attachments carries none of it. `AttachmentStrip`
 * renders it from `value` once here.
 *
 * App registration (`web/src/app/view-chunks.ts`):
 * `attachmentStrip: () => import("../features/composer/AttachmentStripView")`
 * (on first use, with the attachments chunk); calling
 * `attachmentStripChunk.load()` from the same place that loads the
 * attachments model starts both at once.
 */

import { signal, type ReadSignal } from "@inline/reactive"

export type AttachmentStripChunk = typeof import("./AttachmentStripView")

const value = signal<AttachmentStripChunk | undefined>(undefined)
let loading: Promise<AttachmentStripChunk | undefined> | null = null

export const attachmentStripChunk: {
  readonly value: ReadSignal<AttachmentStripChunk | undefined>
  load(): Promise<AttachmentStripChunk | undefined>
} = {
  value,
  load: () => {
    const loaded = value.peek()
    if (loaded) return Promise.resolve(loaded)
    loading ??= import("./AttachmentStripView").then(
      (chunk) => {
        value.set(chunk)
        return chunk
      },
      () => {
        // Not loaded (offline): the next file tries again.
        loading = null
        return undefined
      },
    )
    return loading
  },
}
