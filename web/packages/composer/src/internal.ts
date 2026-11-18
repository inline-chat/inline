import { normalizeEntities, normalizeText, type ComposerEntity } from "./model"

/**
 * The composer's own clipboard format, and the clipboard types every part of
 * the package shares. Small and synchronous on purpose: copy must write the
 * payload inside the `copy` event, and a paste of the composer's own content
 * needs no HTML parsing (`./paste`, loaded on first use).
 *
 * Provenance. Any web page can put `INTERNAL_MIME` on the clipboard in its
 * own copy handler, with a mention whose text names one person and whose ID
 * is another's. So a payload carries an HMAC-SHA-256 of its body under a
 * secret only the app's origin can read, and a paste honors it only when
 * that tag verifies (compared in constant time). The clipboard can be read by
 * other pages, so the payload never contains the secret, only the tag; a
 * page that edits the body (a user ID, say) cannot make a matching tag. A
 * genuine payload replayed unchanged pastes exactly what the user copied.
 *
 * The secret is the app's choice (`createInternalClipboard(key)`): the web
 * app keeps one per browser in the origin's storage, so two tabs of the app
 * honor each other's copies. The package's default (`documentClipboard`) is
 * a random key per document, which honors only this document's copies.
 */

/** The composer's own clipboard format. */
export const INTERNAL_MIME = "application/x-inline-composer"

/** Returns the URL to store (possibly normalized), or `null` to drop the link. */
export type UrlPolicy = (url: string) => string | null

/** Parses HTML into an inert document, or returns `null` if it cannot. */
export type HtmlParser = (html: string) => Document | null

export type ClipboardContent = {
  /** `text/html` */
  html?: string
  /** `text/plain` */
  text?: string
  /** `INTERNAL_MIME`, written by the composer's own copy. */
  internal?: string
}

export type PastedContent = { text: string; entities: ComposerEntity[] }

/** Writes and recognizes the composer's own clipboard payloads. */
export type InternalClipboard = {
  /** The `INTERNAL_MIME` payload for this content, tagged with the key. */
  serialize(content: { text: string; entities: readonly ComposerEntity[] }): string
  /** The body (JSON `{ v: 1, text, entities }`) of a payload whose tag verifies under the key, else `null`. */
  verify(raw: string): string | null
}

/** Longest payload honored (the same bound as pasted HTML). */
export const MAX_INTERNAL_LENGTH = 512 * 1024

// ---------------------------------------------------------------------------
// SHA-256 and HMAC (FIPS 180-4, RFC 2104). Synchronous: WebCrypto's are
// asynchronous, and a copy event must set its data before it returns.

/**
 * The round constants and initial hash: the first 32 bits of the fractional
 * parts of the cube roots of the first 64 primes and the square roots of the
 * first 8 (FIPS 180-4, 4.2.2 and 5.3.3), computed rather than tabled (smaller
 * in the first-frame bundle; the test vectors check every bit).
 */
const K = new Uint32Array(64)
const H0 = new Uint32Array(8)
{
  const frac = (x: number) => ((x - Math.floor(x)) * 0x1_0000_0000) >>> 0
  for (let n = 2, found = 0; found < 64; n++) {
    let prime = true
    for (let d = 2; d * d <= n; d++) if (n % d === 0) prime = false
    if (!prime) continue
    if (found < 8) H0[found] = frac(Math.sqrt(n))
    K[found++] = frac(Math.cbrt(n))
  }
}

const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n))

export const sha256 = (data: Uint8Array): Uint8Array => {
  const bitLength = data.length * 8
  const padded = new Uint8Array(Math.ceil((data.length + 9) / 64) * 64)
  padded.set(data)
  padded[data.length] = 0x80
  const view = new DataView(padded.buffer)
  view.setUint32(padded.length - 8, Math.floor(bitLength / 0x1_0000_0000))
  view.setUint32(padded.length - 4, bitLength >>> 0)
  const h = H0.slice()
  const w = new Uint32Array(64)
  for (let block = 0; block < padded.length; block += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(block + i * 4)
    for (let i = 16; i < 64; i++) {
      const a = w[i - 15]!
      const b = w[i - 2]!
      const s0 = rotr(a, 7) ^ rotr(a, 18) ^ (a >>> 3)
      const s1 = rotr(b, 17) ^ rotr(b, 19) ^ (b >>> 10)
      w[i] = (w[i - 16]! + s0 + w[i - 7]! + s1) >>> 0
    }
    let [a, b, c, d, e, f, g, hh] = [h[0]!, h[1]!, h[2]!, h[3]!, h[4]!, h[5]!, h[6]!, h[7]!]
    for (let i = 0; i < 64; i++) {
      const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i]! + w[i]!) >>> 0
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0
      hh = g
      g = f
      f = e
      e = (d + t1) >>> 0
      d = c
      c = b
      b = a
      a = (t1 + t2) >>> 0
    }
    h[0] = (h[0]! + a) >>> 0
    h[1] = (h[1]! + b) >>> 0
    h[2] = (h[2]! + c) >>> 0
    h[3] = (h[3]! + d) >>> 0
    h[4] = (h[4]! + e) >>> 0
    h[5] = (h[5]! + f) >>> 0
    h[6] = (h[6]! + g) >>> 0
    h[7] = (h[7]! + hh) >>> 0
  }
  const out = new Uint8Array(32)
  const outView = new DataView(out.buffer)
  for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i]!)
  return out
}

export const hmacSha256 = (key: Uint8Array, message: Uint8Array): Uint8Array => {
  const block = new Uint8Array(64)
  block.set(key.length > 64 ? sha256(key) : key)
  const inner = new Uint8Array(64 + message.length)
  const outer = new Uint8Array(64 + 32)
  for (let i = 0; i < 64; i++) {
    inner[i] = block[i]! ^ 0x36
    outer[i] = block[i]! ^ 0x5c
  }
  inner.set(message, 64)
  outer.set(sha256(inner), 64)
  return sha256(outer)
}

const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

/** Equal strings, in time that depends only on their lengths. */
export const constantTimeEqual = (a: string, b: string): boolean => {
  let diff = a.length ^ b.length
  const n = Math.max(a.length, b.length)
  for (let i = 0; i < n; i++) diff |= (a.charCodeAt(i) | 0) ^ (b.charCodeAt(i) | 0)
  return diff === 0
}

const encoder = new TextEncoder()

/** A fresh random key (32 bytes). */
export const randomClipboardKey = (): Uint8Array => {
  const key = new Uint8Array(32)
  globalThis.crypto.getRandomValues(key)
  return key
}

/**
 * Payloads tagged with `key()`. The key is read on every call, so a key
 * another tab stored after this one started is used from then on.
 */
export const createInternalClipboard = (key: () => Uint8Array): InternalClipboard => ({
  serialize: (content) => {
    const body = JSON.stringify({ v: 1, text: content.text, entities: content.entities })
    return JSON.stringify({ v: 2, body, mac: hex(hmacSha256(key(), encoder.encode(body))) })
  },
  verify: (raw) => {
    if (raw.length > MAX_INTERNAL_LENGTH) return null
    let data: unknown
    try {
      data = JSON.parse(raw)
    } catch {
      return null
    }
    if (typeof data !== "object" || data === null) return null
    const { v, body, mac } = data as Record<string, unknown>
    if (v !== 2 || typeof body !== "string" || typeof mac !== "string") return null
    const expected = hex(hmacSha256(key(), encoder.encode(body)))
    return constantTimeEqual(expected, mac) ? body : null
  },
})

let documentKey: Uint8Array | null = null

/** The default: a random key per document, so only this document's copies are honored. */
export const documentClipboard: InternalClipboard = createInternalClipboard(() => (documentKey ??= randomClipboardKey()))

/** `documentClipboard.serialize`. */
export const serializeInternal = (content: { text: string; entities: readonly ComposerEntity[] }): string =>
  documentClipboard.serialize(content)

/** Whether `raw` is a payload this document wrote (`documentClipboard`). */
export const wroteInternal = (raw: string): boolean => documentClipboard.verify(raw) !== null

const internalTypes: ReadonlySet<string> = new Set([
  "bold",
  "italic",
  "underline",
  "strikethrough",
  "code",
  "pre",
  "textUrl",
  "mention",
  "groupMention",
  "thread",
])
const decimalId = /^-?\d{1,20}$/
const languagePattern = /^[\w+#.-]{1,32}$/

/**
 * Validate a payload's body (JSON `{ v: 1, text, entities }`). Anything off
 * returns `null`. Validation is not provenance: `readInternal` first checks
 * the tag.
 */
export const parseInternal = (raw: string, safeUrl: UrlPolicy): PastedContent | null => {
  if (raw.length > MAX_INTERNAL_LENGTH) return null
  let data: unknown
  try {
    data = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof data !== "object" || data === null) return null
  const { v, text, entities } = data as Record<string, unknown>
  if (v !== 1 || typeof text !== "string" || !Array.isArray(entities)) return null
  const out: ComposerEntity[] = []
  for (const item of entities.slice(0, 1000)) {
    if (typeof item !== "object" || item === null) continue
    const e = item as Record<string, unknown>
    if (typeof e["type"] !== "string" || !internalTypes.has(e["type"])) continue
    if (typeof e["offset"] !== "number" || typeof e["length"] !== "number") continue
    const entity = { type: e["type"], offset: e["offset"], length: e["length"] } as ComposerEntity
    if (entity.type === "textUrl") {
      const url = typeof e["url"] === "string" ? safeUrl(e["url"]) : null
      if (!url) continue
      entity.url = url
    }
    if (entity.type === "pre" && typeof e["language"] === "string" && languagePattern.test(e["language"])) {
      entity.language = e["language"]
    }
    if (entity.type === "mention") {
      if (typeof e["userId"] !== "string" || !decimalId.test(e["userId"])) continue
      entity.userId = e["userId"] as ComposerEntity["userId"]
    }
    if (entity.type === "thread") {
      if (typeof e["chatId"] !== "string" || !decimalId.test(e["chatId"])) continue
      entity.chatId = e["chatId"] as ComposerEntity["chatId"]
    }
    if (entity.type === "groupMention") {
      if (typeof e["groupId"] !== "string" || !decimalId.test(e["groupId"])) continue
      entity.groupId = e["groupId"]
    }
    out.push(entity)
  }
  const clean = normalizeText(text, out)
  return { text: clean.text, entities: normalizeEntities(clean.text, clean.entities) }
}

/** The content of a payload whose tag verifies and whose body is valid, else `null`. */
export const readInternal = (raw: string, safeUrl: UrlPolicy, clipboard: InternalClipboard = documentClipboard): PastedContent | null => {
  const body = clipboard.verify(raw)
  return body === null ? null : parseInternal(body, safeUrl)
}

/**
 * Paste without HTML parsing, when that decides it: plain paste, the
 * composer's own verified payload, or no usable HTML. Returns `null` when the
 * HTML has to be parsed (`./paste`'s `sanitizePaste`, loaded on first use);
 * the result then equals what `sanitizePaste` returns.
 */
export const quickPaste = (
  content: ClipboardContent,
  options: { safeUrl: UrlPolicy; plain?: boolean; clipboard?: InternalClipboard; maxHtmlLength?: number },
): PastedContent | null => {
  if (!options.plain && content.internal) {
    const internal = readInternal(content.internal, options.safeUrl, options.clipboard)
    if (internal) return internal
  }
  const usableHtml = !options.plain && content.html && content.html.length <= (options.maxHtmlLength ?? MAX_INTERNAL_LENGTH)
  if (usableHtml) return null
  return plainContent(content)
}

/** The plain-text fallback `sanitizePaste` ends with. */
export const plainContent = (content: ClipboardContent): PastedContent => {
  const plain = content.text ?? ""
  if (plain === "" && content.html && !content.text) {
    // HTML only, too big or unparseable: nothing safe to insert.
    return { text: "", entities: [] }
  }
  return { text: normalizeText(plain).text, entities: [] }
}
