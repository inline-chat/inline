/**
 * Reading, writing and erasing the boot snapshot in `localStorage`. Every
 * call is synchronous and none throws: storage that is missing, full or
 * blocked behaves like an empty one.
 */

import { BOOT_SNAPSHOT_KEY, parseBootSnapshot, type BootSnapshot, type SnapshotProblem } from "./format"

/** The part of `Storage` used (`localStorage` fits). */
export type SnapshotStorage = {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
}

export type BootSnapshotRead =
  | { readonly kind: "none" }
  | { readonly kind: "snapshot"; readonly snapshot: BootSnapshot; readonly chars: number; readonly ms: number }
  /** There was one and it was removed. */
  | { readonly kind: "discarded"; readonly reason: SnapshotProblem | "signedOut" }

export type ReadOptions = {
  readonly buildId: string
  /**
   * A synchronous sign of a sign-out that has not finished (the auth
   * persistence's logout tombstone). When true the snapshot is erased unread.
   */
  readonly signedOut?: () => boolean
  /** Milliseconds, for the cost of the read. */
  readonly now?: () => number
}

/** Remove the snapshot. Idempotent; the account's erase hook calls it on every sign-out. */
export const eraseBootSnapshot = (storage: SnapshotStorage | undefined): void => {
  try {
    storage?.removeItem(BOOT_SNAPSHOT_KEY)
  } catch {
    // Unavailable storage holds nothing to erase.
  }
}

/**
 * Read the snapshot for this build at start, synchronously. A snapshot that
 * cannot be used is removed, so it is never read twice.
 */
export const readBootSnapshot = (storage: SnapshotStorage | undefined, options: ReadOptions): BootSnapshotRead => {
  const now = options.now ?? (() => 0)
  const started = now()
  let text: string | null
  try {
    text = storage?.getItem(BOOT_SNAPSHOT_KEY) ?? null
  } catch {
    return { kind: "none" }
  }
  if (text === null) return { kind: "none" }
  let signedOut = false
  try {
    signedOut = options.signedOut?.() === true
  } catch {
    signedOut = false
  }
  if (signedOut) {
    eraseBootSnapshot(storage)
    return { kind: "discarded", reason: "signedOut" }
  }
  const parsed = parseBootSnapshot(text, options.buildId)
  if ("problem" in parsed) {
    eraseBootSnapshot(storage)
    return { kind: "discarded", reason: parsed.problem }
  }
  return { kind: "snapshot", snapshot: parsed.snapshot, chars: text.length, ms: now() - started }
}

/** Store serialized snapshot text. False when storage refused it (full, blocked); nothing stale is left then. */
export const writeBootSnapshot = (storage: SnapshotStorage | undefined, text: string): boolean => {
  if (!storage) return false
  try {
    storage.setItem(BOOT_SNAPSHOT_KEY, text)
    return true
  } catch {
    eraseBootSnapshot(storage)
    return false
  }
}
