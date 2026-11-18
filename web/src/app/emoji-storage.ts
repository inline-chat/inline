/**
 * Where an account's emoji usage (recents, reaction picks, skin tone) lives:
 * `localStorage` under `inline:emoji:<userId>:` before the Mac's key
 * (`USAGE_KEYS` in the emoji feature). Small and separate from
 * `emoji-session.ts` so the boot path's erase hook can use it without the
 * session class.
 */

import type { UserID } from "@inline/ids"
import type { StorageLike } from "@inline/view"
import type { KeyValueStore } from "../features/emoji"

/** Where an account's emoji usage lives: `inline:emoji:<userId>:` before the Mac's key. */
export const emojiStoragePrefix = (userId: UserID): string => `inline:emoji:${userId}:`

/** The account's emoji usage in `localStorage`-like storage, guarded (private windows and quota read as empty, drop writes). */
export const accountEmojiStore = (storage: StorageLike | undefined, userId: UserID): KeyValueStore => {
  const prefix = emojiStoragePrefix(userId)
  return {
    get: (key) => {
      try {
        return storage?.getItem(prefix + key) ?? null
      } catch {
        return null
      }
    },
    set: (key, value) => {
      try {
        storage?.setItem(prefix + key, value)
      } catch {
        // Quota or storage disabled: usage is not kept.
      }
    },
    remove: (key) => {
      try {
        storage?.removeItem(prefix + key)
      } catch {
        // Nothing was kept.
      }
    },
  }
}

/** Remove everything kept under the account's emoji prefix (sign-out). */
export const eraseAccountEmoji = (storage: Pick<Storage, "length" | "key" | "removeItem"> | undefined, userId: UserID): void => {
  if (!storage) return
  const prefix = emojiStoragePrefix(userId)
  try {
    const keys: string[] = []
    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i)
      if (key?.startsWith(prefix)) keys.push(key)
    }
    for (const key of keys) storage.removeItem(key)
  } catch {
    // Storage unavailable: nothing was kept.
  }
}

