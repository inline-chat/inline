/**
 * The browser's key for the composer's clipboard payloads, so a message copied
 * with mentions in one tab of the app pastes with its mentions in another
 * (`@inline/composer` `createInternalClipboard`, `packages/composer/README.md`
 * "Paste").
 *
 * - One random 32-byte key per browser profile, in the app origin's
 *   `localStorage` (`CLIPBOARD_KEY_STORAGE`), which only this origin can read.
 *   Another origin's page cannot read it, so it cannot tag a forged payload;
 *   the payload carries only the tag (HMAC-SHA-256), never the key.
 * - Read on every copy and paste (one `localStorage` read), so two tabs that
 *   both made a key at their first copy converge on the one stored last.
 * - Without storage (blocked, private mode that throws), a key per document:
 *   rich paste then works inside the tab only, as before.
 * - Not account data: it authenticates clipboard payloads and nothing else,
 *   and a script on the origin can read it, but such a script owns the
 *   session anyway (`docs/security.md`). Sign-out need not remove it.
 */

import { createInternalClipboard, randomClipboardKey, type InternalClipboard } from "@inline/composer"

export const CLIPBOARD_KEY_STORAGE = "inline.composer.clipboardKey"

export type KeyStorage = { getItem(key: string): string | null; setItem(key: string, value: string): void }

const toHex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

const fromHex = (value: string | null): Uint8Array | null => {
  if (value === null || !/^[0-9a-f]{64}$/.test(value)) return null
  const out = new Uint8Array(32)
  for (let i = 0; i < 32; i++) out[i] = Number.parseInt(value.slice(i * 2, i * 2 + 2), 16)
  return out
}

/** The key, made and stored on first use; `storage` is read lazily (default `localStorage`). */
export const browserClipboardKey = (storage: () => KeyStorage | null = defaultStorage): (() => Uint8Array) => {
  let fallback: Uint8Array | null = null
  return () => {
    try {
      const store = storage()
      if (store) {
        const stored = fromHex(store.getItem(CLIPBOARD_KEY_STORAGE))
        if (stored) return stored
        const key = randomClipboardKey()
        store.setItem(CLIPBOARD_KEY_STORAGE, toHex(key))
        return key
      }
    } catch {
      // Storage refused: fall through to the document's key.
    }
    fallback ??= randomClipboardKey()
    return fallback
  }
}

const defaultStorage = (): KeyStorage | null => (globalThis as { localStorage?: KeyStorage }).localStorage ?? null

/** Payloads tagged with a key from `storage` (tests, labs). */
export const createAppClipboard = (storage?: () => KeyStorage | null): InternalClipboard =>
  createInternalClipboard(browserClipboardKey(storage))

/** The app's clipboard: the composer model's default. */
export const appClipboard: InternalClipboard = createAppClipboard()
