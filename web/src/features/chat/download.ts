/**
 * Saving a message's file (a document row's Download button): the bytes come
 * from the core's media layer (`media` query, priority `opened`: the user
 * asked, so no auto-download limit), and the browser saves them from an
 * object URL under a name made safe by `downloadFileName` (bidirectional
 * controls and path separators removed). The file never comes from a URL a
 * page could choose, and the name is never the server's string unchecked.
 *
 * Framework-free; the DOM part (`saveBlob`) takes the document.
 */

import type { MediaContent, MediaResource, MessageRowId } from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { effect, type Dispose, type StoreClient } from "@inline/reactive"
import { downloadFileName } from "../content/file-name"

export type DownloadTarget = { readonly chatId: ChatID; readonly messageId: MessageID }

/** Why a download did not happen. */
export class DownloadFailed extends Error {
  constructor(readonly reason: "failed" | "aborted") {
    super(`Download ${reason}`)
    this.name = "DownloadFailed"
  }
}

/**
 * The message's file as a `Blob`, once the core has it. Subscribes to the
 * file with priority `opened` and resolves on `ready`, rejects on `failed`
 * or an abort; unsubscribes either way.
 */
export const messageFileBlob = (client: Pick<StoreClient, "subscribe">, target: DownloadTarget, signal?: AbortSignal): Promise<Blob> =>
  new Promise<Blob>((resolve, reject) => {
    if (signal?.aborted) {
      reject(new DownloadFailed("aborted"))
      return
    }
    const handle = client.subscribe({
      kind: "media",
      media: { kind: "message", chatId: target.chatId, messageId: target.messageId },
      priority: "opened",
    })
    let done = false
    let stop: Dispose | undefined
    const finish = () => {
      done = true
      signal?.removeEventListener("abort", onAbort)
      // Released outside the effect's own run.
      queueMicrotask(() => {
        stop?.()
        handle.unsubscribe()
      })
    }
    const onAbort = () => {
      if (done) return
      finish()
      reject(new DownloadFailed("aborted"))
    }
    signal?.addEventListener("abort", onAbort, { once: true })
    stop = effect(() => {
      const value = handle.resource.get() as MediaResource | undefined
      if (done || value?.kind !== "media") return
      if (value.state === "ready" && value.blob) {
        finish()
        resolve(value.blob)
      } else if (value.state === "failed") {
        finish()
        reject(new DownloadFailed("failed"))
      }
    })
  })

/** How long an object URL handed to the browser's download stays valid. */
export const DOWNLOAD_URL_LIFETIME_MS = 60_000

/**
 * Hand a blob to the browser's download under `name` (already made safe by
 * `downloadFileName`). An anchor with `download`, never navigation.
 */
export const saveBlob = (
  doc: Document,
  blob: Blob,
  name: string,
  urls: Pick<typeof URL, "createObjectURL" | "revokeObjectURL"> = URL,
  later: (fn: () => void, ms: number) => void = (fn, ms) => void setTimeout(fn, ms),
): void => {
  const url = urls.createObjectURL(blob)
  const anchor = doc.createElement("a")
  anchor.href = url
  anchor.download = name
  anchor.rel = "noopener"
  anchor.click()
  later(() => urls.revokeObjectURL(url), DOWNLOAD_URL_LIFETIME_MS)
}

/** Said when a file could not be saved. */
export const downloadFailedText = { title: "Couldn't download the file", description: "Check your connection and try again." } as const

export type MessageFileDownload = {
  readonly client: Pick<StoreClient, "subscribe">
  /** The message a row shows; undefined for a row still sending (no server ID: nothing to fetch). */
  readonly target: (rowId: MessageRowId) => DownloadTarget | undefined
  /** Hand the file to the browser. Default `saveBlob` on this page's document. */
  readonly save?: (blob: Blob, name: string) => void
  /** Say that it failed. */
  readonly toast?: (input: { readonly title: string; readonly description?: string; readonly tone?: "error" }) => void
}

/**
 * A row's Download (a document in the message list, a file in chat info's
 * Files tab): the file from the core, saved under `downloadFileName` of the
 * sender's name (never the raw string). Resolves with the name it saved
 * under, or undefined (nothing to fetch, or a failure, which is said).
 */
export const downloadMessageFile = async (options: MessageFileDownload, rowId: MessageRowId, media: MediaContent): Promise<string | undefined> => {
  const target = options.target(rowId)
  if (!target) return undefined
  const name = downloadFileName(media.kind === "document" ? media.document.fileName : "")
  try {
    const blob = await messageFileBlob(options.client, target)
    if (options.save) options.save(blob, name)
    else saveBlob(document, blob, name)
    return name
  } catch {
    options.toast?.({ ...downloadFailedText, tone: "error" })
    return undefined
  }
}
