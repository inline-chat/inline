/**
 * Saving: the File System Access save dialog where it exists (Chromium),
 * otherwise a download link. The object URL is revoked after a delay, since
 * some browsers read it after `click()` returns.
 */

import { DESKTOP_ONLY, unavailable } from "../capability"
import type { Files, SaveOutcome } from "../platform"
import type { AnchorLike, WebEnv } from "./env"

export const DOWNLOAD_URL_LIFETIME_MS = 60_000

const isAbort = (error: unknown): boolean =>
  typeof error === "object" && error !== null && (error as { name?: unknown }).name === "AbortError"

export const createWebFiles = (env: WebEnv): Files => {
  const { window, document, clock } = env

  const download = (blob: Blob, suggestedName: string): SaveOutcome => {
    const urlApi = env.URL
    const body = document.body
    if (!urlApi || !body) return "failed"
    let url: string
    try {
      url = urlApi.createObjectURL(blob)
    } catch {
      return "failed"
    }
    try {
      const anchor = document.createElement("a") as AnchorLike
      anchor.href = url
      anchor.download = suggestedName
      anchor.rel = "noopener"
      body.appendChild(anchor)
      anchor.click()
      anchor.remove()
    } catch {
      urlApi.revokeObjectURL(url)
      return "failed"
    }
    clock.setTimeout(() => urlApi.revokeObjectURL(url), DOWNLOAD_URL_LIFETIME_MS)
    return "downloaded"
  }

  return {
    async save(blob, suggestedName) {
      const picker = window.showSaveFilePicker
      if (typeof picker !== "function") return download(blob, suggestedName)
      let handle: Awaited<ReturnType<typeof picker>>
      try {
        handle = await picker.call(window, { suggestedName })
      } catch (error) {
        if (isAbort(error)) return "cancelled"
        // No user activation, or the picker is blocked: fall back to a download.
        return download(blob, suggestedName)
      }
      try {
        const writable = await handle.createWritable()
        await writable.write(blob)
        await writable.close()
        return "saved"
      } catch {
        return "failed"
      }
    },
    reveal: unavailable(DESKTOP_ONLY),
  }
}
