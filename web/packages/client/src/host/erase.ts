/**
 * Erasing one account's data on sign-out and revocation (invariant 10), so
 * that a worker killed part way (a tab closed right after "Sign Out") never
 * leaves the replica, search index or media cache readable.
 *
 * A marker (`accounts/<accountKey>/erase-pending` in the account's byte
 * store, which lives outside the SQLite pool) is written before anything is
 * erased and removed only after everything was. Whoever opens that account's
 * storage next checks it first: `finishPendingErase` erases the replica (with
 * its search index) and the media files, then removes the marker; a replica
 * with a marker is never opened. In the browser the byte store is OPFS, so the
 * marker survives the worker.
 */
import type { UserID } from "@inline/ids"
import { MemoryByteStore, OpfsByteStore, type ByteStore } from "../media"
import type { HostStorage } from "./account-core"

export const ERASE_MARKER = "erase-pending"

/** Where an account's files and its erase marker live. */
export type AccountFiles = {
  bytes: ByteStore
  /** `accounts/<accountKey>/`. */
  root: string
}

export const defaultByteStore = (): ByteStore => {
  const storage = (globalThis as { navigator?: { storage?: { getDirectory?: unknown } } }).navigator?.storage
  return typeof storage?.getDirectory === "function" ? new OpfsByteStore() : new MemoryByteStore()
}

export const accountFiles = (bytes: ByteStore, accountKey: string): AccountFiles => ({
  bytes,
  root: `accounts/${accountKey}/`,
})

const markerPath = (files: AccountFiles) => `${files.root}${ERASE_MARKER}`

export const writeEraseMarker = (files: AccountFiles, now: number) =>
  files.bytes.write(markerPath(files), new TextEncoder().encode(JSON.stringify({ at: now })))

export const hasEraseMarker = async (files: AccountFiles) => (await files.bytes.stat(markerPath(files))) != null

export const clearEraseMarker = (files: AccountFiles) => files.bytes.remove(markerPath(files))

/** The account's media files (jobs, staged sources, cache, attachment info). */
export const eraseMediaFiles = (files: AccountFiles) => files.bytes.removePrefix(`${files.root}media/`)

export type FinishEraseOptions = {
  userId: UserID
  files: AccountFiles
  /** Erase the replica without opening it (the browser: `eraseOpfsHostStorage`). */
  eraseStorage?: (userId: UserID) => Promise<void>
  /** Otherwise: open it (unread), close it, and erase it. */
  openStorage: (userId: UserID) => HostStorage | Promise<HostStorage>
}

/**
 * Finish an erase a killed core left behind: the replica, then the media
 * files, then the marker. Returns whether there was one to finish. Throws
 * when it could not; the marker then stays for the next attempt.
 */
export const finishPendingErase = async (options: FinishEraseOptions): Promise<boolean> => {
  const { files } = options
  if (!(await hasEraseMarker(files))) return false
  if (options.eraseStorage) {
    await options.eraseStorage(options.userId)
  } else {
    const storage = await options.openStorage(options.userId)
    await storage.store.close().catch(() => undefined)
    await storage.erase()
  }
  await eraseMediaFiles(files)
  await clearEraseMarker(files)
  return true
}
