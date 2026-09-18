import { createCipheriv, createDecipheriv, createHmac, hkdfSync, randomBytes } from "node:crypto"

// A separate marker distinguishes new storage from legacy text/binary values.
// Existing data is read compatibly; malformed marked values never fall back to plaintext.
export const CONTENT_PREFIX = "inline-content:v1:"
const MAGIC = Buffer.from(CONTENT_PREFIX)
const MARKER = "inline-content:"
const MAX_CONTENT_BYTES = 1024 * 1024

export class ContentEncryptionError extends Error {
  constructor() { super("Content encryption failed"); this.name = "ContentEncryptionError" }
}

export const contentEncryptionWritesEnabled = (): boolean => {
  const mode = process.env["CONTENT_ENCRYPTION_WRITES"] ?? "false"
  if (mode !== "true" && mode !== "false") throw new ContentEncryptionError()
  return mode === "true"
}

function rootKey(): Buffer {
  const hex = process.env["ENCRYPTION_KEY"]
  if (!hex || !/^[a-fA-F0-9]{64}$/.test(hex)) throw new ContentEncryptionError()
  return Buffer.from(hex, "hex")
}

function key(purpose: string): Buffer {
  const root = rootKey()
  try { return Buffer.from(hkdfSync("sha256", root, new Uint8Array(), `inline/content/v1/${purpose}`, 32)) }
  finally { root.fill(0) }
}

export function sealContent(value: Uint8Array, purpose: string): Buffer {
  const secret = key(`encrypt/${purpose}`)
  try {
    if (value.byteLength > MAX_CONTENT_BYTES) throw new ContentEncryptionError()
    const nonce = randomBytes(12)
    const cipher = createCipheriv("aes-256-gcm", secret, nonce)
    cipher.setAAD(Buffer.from(`${CONTENT_PREFIX}${purpose}`))
    return Buffer.concat([MAGIC, nonce, cipher.update(value), cipher.final(), cipher.getAuthTag()])
  } catch { throw new ContentEncryptionError() }
  finally { secret.fill(0) }
}

export const isSealedContent = (value: Uint8Array): boolean =>
  value.byteLength >= MAGIC.length && Buffer.from(value).subarray(0, MAGIC.length).equals(MAGIC)

export function openContent(value: Uint8Array, purpose: string): Buffer {
  if (!isSealedContent(value)) {
    if (Buffer.from(value).subarray(0, MARKER.length).toString() === MARKER) throw new ContentEncryptionError()
    return Buffer.from(value)
  }
  const secret = key(`encrypt/${purpose}`)
  try {
    const bytes = Buffer.from(value)
    if (bytes.length < MAGIC.length + 28 || bytes.length > MAX_CONTENT_BYTES + MAGIC.length + 28) {
      throw new ContentEncryptionError()
    }
    const decipher = createDecipheriv("aes-256-gcm", secret, bytes.subarray(MAGIC.length, MAGIC.length + 12))
    decipher.setAAD(Buffer.from(`${CONTENT_PREFIX}${purpose}`))
    decipher.setAuthTag(bytes.subarray(bytes.length - 16))
    return Buffer.concat([decipher.update(bytes.subarray(MAGIC.length + 12, bytes.length - 16)), decipher.final()])
  } catch { throw new ContentEncryptionError() }
  finally { secret.fill(0) }
}

export function sealContentText(value: string, purpose: string): string {
  return CONTENT_PREFIX + sealContent(Buffer.from(value, "utf8"), purpose).subarray(MAGIC.length).toString("base64")
}

export function openContentText(value: string, purpose: string): string {
  if (!value.startsWith(CONTENT_PREFIX)) {
    if (value.startsWith(MARKER)) throw new ContentEncryptionError()
    return value
  }
  const encoded = value.slice(CONTENT_PREFIX.length)
  // Reject oversized envelopes before allocating their decoded bytes.
  if (encoded.length > Math.ceil((MAX_CONTENT_BYTES + 28) / 3) * 4) throw new ContentEncryptionError()
  const bytes = Buffer.from(encoded, "base64")
  if (bytes.toString("base64") !== encoded) throw new ContentEncryptionError()
  return openContent(Buffer.concat([MAGIC, bytes]), purpose).toString("utf8")
}

/** Stable lookup keys must not rotate independently of a coordinated index migration. */
export function contentLookup(purpose: string, scope: readonly (string | number)[], value: string): Buffer {
  const secret = key(`lookup/${purpose}`)
  try { return createHmac("sha256", secret).update(JSON.stringify([scope, value])).digest() }
  finally { secret.fill(0) }
}

/** Validate flags even while writes are disabled; fail before serving with a bad key. */
export function assertContentEncryptionConfigured(): void {
  contentEncryptionWritesEnabled()
  rootKey().fill(0)
}
