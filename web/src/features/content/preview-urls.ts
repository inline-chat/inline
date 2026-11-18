/**
 * Object URLs for the blurred previews rows carry (`strippedJpeg` output).
 * The preview is painted as an element's background from the first frame;
 * the URL is created when the first element attaches and revoked after the
 * last one lets go. Never a `data:` string in markup, never inline `<style>`:
 * the background is set through the CSSOM, which the content policy allows.
 *
 * Keyed by the bytes' identity. `strippedJpeg` returns the same output for the
 * same input, and the content memo keeps model identity across row copies
 * (`reuseTree`), so one preview has one URL however many rows show it.
 */

export type ObjectUrlApi = {
  create(bytes: Uint8Array): string
  revoke(url: string): void
}

export const browserObjectUrls: ObjectUrlApi = {
  create: (bytes) => URL.createObjectURL(new Blob([bytes as Uint8Array<ArrayBuffer>], { type: "image/jpeg" })),
  revoke: (url) => URL.revokeObjectURL(url),
}

/** The element side of a preview: something with a style declaration. */
export type PreviewTarget = { readonly style: Pick<CSSStyleDeclaration, "setProperty" | "removeProperty"> }

export type PreviewPart = { attach(element: PreviewTarget): () => void }

export type PreviewUrlsOptions = {
  readonly api?: ObjectUrlApi
  /**
   * When to check a released URL again before revoking it. A detach followed
   * by an attach in the same task (a remount, StrictMode) keeps the URL.
   * Default `queueMicrotask`.
   */
  readonly defer?: (fn: () => void) => void
}

type Entry = { url: string; count: number }

const noopPart: PreviewPart = { attach: () => () => {} }

export class PreviewUrls {
  readonly #api: ObjectUrlApi
  readonly #defer: (fn: () => void) => void
  readonly #entries = new Map<Uint8Array, Entry>()
  readonly #parts = new WeakMap<Uint8Array, PreviewPart>()
  #disposed = false

  constructor(options: PreviewUrlsOptions = {}) {
    this.#api = options.api ?? browserObjectUrls
    // Not the bare function: called as a method it would run with this object as `this`, which browsers reject.
    this.#defer = options.defer ?? ((fn) => queueMicrotask(fn))
  }

  /** The URL for these bytes, counted until `release`. */
  acquire(bytes: Uint8Array): string {
    let entry = this.#entries.get(bytes)
    if (!entry) {
      entry = { url: this.#api.create(bytes), count: 0 }
      this.#entries.set(bytes, entry)
    }
    entry.count += 1
    return entry.url
  }

  release(bytes: Uint8Array): void {
    const entry = this.#entries.get(bytes)
    if (!entry || entry.count === 0) return
    entry.count -= 1
    if (entry.count > 0) return
    this.#defer(() => {
      if (entry.count > 0 || this.#entries.get(bytes) !== entry) return
      this.#entries.delete(bytes)
      this.#api.revoke(entry.url)
    })
  }

  /**
   * A part that paints the preview as the element's background while
   * attached. Cached per bytes, so a view can ask for it on every render.
   */
  part(bytes: Uint8Array | undefined): PreviewPart {
    if (!bytes) return noopPart
    let part = this.#parts.get(bytes)
    if (!part) {
      part = {
        attach: (element) => {
          if (this.#disposed) return () => {}
          const url = this.acquire(bytes)
          element.style.setProperty("background-image", `url("${url}")`)
          return () => {
            element.style.removeProperty("background-image")
            this.release(bytes)
          }
        },
      }
      this.#parts.set(bytes, part)
    }
    return part
  }

  /** URLs alive now. */
  get size(): number {
    return this.#entries.size
  }

  /** Revoke everything (sign-out, closing the app's media layer). */
  dispose(): void {
    this.#disposed = true
    for (const entry of this.#entries.values()) this.#api.revoke(entry.url)
    this.#entries.clear()
  }
}
