/**
 * Where appearance settings live. Synchronous on purpose: the controller reads
 * once at construction (before the first render) and writes in the same task
 * as the change. Local storage now; the core can sync the settings object
 * later through another implementation of the same interface.
 */

export interface AppearanceStorage {
  read(key: string): string | null
  write(key: string, value: string): void
}

/** Settings, device-wide: appearance is chosen before an account is known. */
export const APPEARANCE_STORAGE_KEY = "inline.appearance"

/**
 * What the pre-paint boot script (`boot.js`) reads: the appearance and the
 * theme's opaque window color per variant. Written by the controller on
 * every apply, so it never needs the theme table itself.
 */
export const APPEARANCE_BOOT_KEY = "inline.appearance.boot"

export const BOOT_RECORD_VERSION = 1

export type BootRecord = {
  readonly v: typeof BOOT_RECORD_VERSION
  /** The appearance choice: "system", "light" or "dark". */
  readonly a: "system" | "light" | "dark"
  /** Window color in light, `#rrggbb`. */
  readonly l: string
  /** Window color in dark, `#rrggbb`. */
  readonly d: string
}

type WebStorageLike = { getItem(key: string): string | null; setItem(key: string, value: string): void }

/**
 * `localStorage`, or nothing when it is unavailable (blocked, private mode,
 * quota). Reads and writes never throw; a failed write keeps the setting for
 * this session only.
 */
export function localAppearanceStorage(storage?: WebStorageLike | null): AppearanceStorage {
  const resolve = (): WebStorageLike | null => {
    if (storage !== undefined) return storage
    try {
      return (globalThis as { localStorage?: WebStorageLike }).localStorage ?? null
    } catch {
      return null
    }
  }
  return {
    read(key) {
      try {
        return resolve()?.getItem(key) ?? null
      } catch {
        return null
      }
    },
    write(key, value) {
      try {
        resolve()?.setItem(key, value)
      } catch {
        // Quota or a blocked store: the setting lives for this session only.
      }
    },
  }
}

/** In-memory storage for tests and previews. */
export function memoryAppearanceStorage(initial: Record<string, string> = {}): AppearanceStorage & {
  readonly entries: Map<string, string>
} {
  const entries = new Map(Object.entries(initial))
  return {
    entries,
    read: (key) => entries.get(key) ?? null,
    write: (key, value) => {
      entries.set(key, value)
    },
  }
}
