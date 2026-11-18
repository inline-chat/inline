/**
 * The boot sweep: removes account storage that no signed-in account owns.
 *
 * Sign-out erases the replica and the media in the core (invariant 10). A
 * tab closed mid-erase leaves the erase marker, and the account's next start
 * finishes it; an account that never signs in again on this browser keeps its
 * files until something removes them. So do storage cleared by hand (the auth
 * record gone, OPFS kept) and an erase that failed. This sweep is that
 * something. On each start, on the idle lane after the first paint, it looks
 * at the origin private file system and removes, per account:
 *
 * - the SQLite pool (`sahPoolNames(...).directory`) in this server's namespace;
 * - the media root `accounts/u<id>/` with its erase marker, when the account
 *   has a pool in this namespace or the marker says an erase was started.
 *   Media with neither is left alone: it may belong to another namespace (the
 *   demo's, another server's), since media roots are not namespaced.
 *
 * Rules, each a test in `account-storage-sweep.test.ts`:
 *
 * - Never an owned account. Owners are a set (multi-account is planned): every
 *   user the auth store knows, signed in or awaiting re-authentication. When
 *   the auth store cannot say (still hydrating, storage unavailable or
 *   corrupt) nothing is removed.
 * - Never under a running core. Each account is swept while holding that
 *   account's link leader lock, taken only if free; a held lock (a tab leads
 *   the account, or a stepping-down leader still waits for its worker) skips
 *   it. Holding the lock also keeps a new core for that account from starting
 *   mid-sweep. Owners are read again under the lock.
 * - Safe to interrupt. The erase marker is written first and removed last, so
 *   a sweep cut short is finished by the next sweep, or by the core itself if
 *   the account signs in first (it never opens a marked replica).
 * - Off the first-paint path. The app queues it on the warmup (idle) lane, and
 *   it yields between accounts.
 *
 * The boot snapshot (one `localStorage` key, checked against the auth store
 * at every start) and the service worker caches (no account data; cleared on
 * every sign-out) need no sweep.
 */

import type { UserID } from "@inline/ids"
import type { Log } from "@inline/log"

/** The erase marker's name (`ERASE_MARKER` in `@inline/client/host`), relative to the account's media root. */
export const ERASE_MARKER_NAME = "erase-pending"

/** The part of the origin private file system the sweep uses. Paths are segment lists from the root. */
export type SweepFileSystem = {
  /** Names of the directories directly under `path`; empty when it does not exist. */
  directories(path: readonly string[]): Promise<readonly string[]>
  /** Whether a file exists at `path`. */
  fileExists(path: readonly string[]): Promise<boolean>
  writeFile(path: readonly string[], text: string): Promise<void>
  /** Removes `path` and everything under it. No error when it does not exist. */
  remove(path: readonly string[]): Promise<void>
}

/** A held lock. */
export type SweepLock = { release(): void }

export type AccountStorageSweepOptions = {
  fs: SweepFileSystem
  /**
   * The SQLite pool directory of an account in this app's namespace
   * (`sahPoolNames({ accountId, namespace }).directory`).
   */
  poolDirectory: (userId: UserID) => string
  /** The account's media root key (`accounts/<key>/`). Default `u<id>`, the host's default. */
  mediaKey?: (userId: UserID) => string
  /**
   * Accounts signed in on this browser, read fresh on each call. Undefined
   * when that cannot be known; the sweep then stops.
   */
  owners: () => ReadonlySet<UserID> | undefined | Promise<ReadonlySet<UserID> | undefined>
  /** The account's link leader lock if it is free now, else null (`browserLocks().tryAcquire(linkNames(...).locks.leader)`). */
  tryLockAccount: (userId: UserID) => Promise<SweepLock | null>
  /** Yields between accounts (an idle slice). */
  pause?: () => Promise<void>
  /** Wall clock for the marker. */
  now?: () => number
  log?: Log
}

export type SweepSkip = { userId: UserID; reason: "owned" | "busy" | "failed" }

export type AccountStorageSweepReport = {
  /** Accounts whose storage was removed. */
  removed: UserID[]
  skipped: SweepSkip[]
  /** Set when the sweep stopped early because the owners could not be known. */
  stopped?: "ownersUnknown"
}

const ACCOUNTS = "accounts"
const USER_DIR = /^user-(\d+)$/
const MEDIA_DIR = /^u(\d+)$/

const segments = (path: string) => path.split("/").filter((segment) => segment.length > 0)

/** Runs one sweep. Never throws for a file system error; the account is reported `failed` and retried next start. */
export const sweepAccountStorage = async (options: AccountStorageSweepOptions): Promise<AccountStorageSweepReport> => {
  const { fs } = options
  const mediaKey = options.mediaKey ?? ((userId: UserID) => `u${userId}`)
  const report: AccountStorageSweepReport = { removed: [], skipped: [] }

  const initialOwners = await options.owners()
  if (!initialOwners) return { ...report, stopped: "ownersUnknown" }

  // The pool directories of this namespace: `<base>/user-<id>`.
  const probe = segments(options.poolDirectory("0" as UserID))
  const poolBase = probe.slice(0, -1)
  const pools = new Set<UserID>()
  for (const name of await fs.directories(poolBase).catch(() => [] as readonly string[])) {
    const match = USER_DIR.exec(name)
    // Only names this build writes: a pool directory for exactly that user ID.
    if (match?.[1] && segments(options.poolDirectory(match[1] as UserID)).at(-1) === name) pools.add(match[1] as UserID)
  }
  const media = new Set<UserID>()
  for (const name of await fs.directories([ACCOUNTS]).catch(() => [] as readonly string[])) {
    const match = MEDIA_DIR.exec(name)
    if (match?.[1] && mediaKey(match[1] as UserID) === name) media.add(match[1] as UserID)
  }

  const candidates = [...new Set([...pools, ...media])].sort()
  for (const userId of candidates) {
    if (initialOwners.has(userId)) {
      report.skipped.push({ userId, reason: "owned" })
      continue
    }
    const root = [ACCOUNTS, mediaKey(userId)]
    const marker = [...root, ERASE_MARKER_NAME]
    const hasPool = pools.has(userId)
    if (!hasPool && !(await fs.fileExists(marker).catch(() => false))) continue // not this namespace's

    if (options.pause) await options.pause()
    const lock = await options.tryLockAccount(userId).catch(() => null)
    if (!lock) {
      report.skipped.push({ userId, reason: "busy" })
      continue
    }
    try {
      const owners = await options.owners()
      if (!owners) {
        report.stopped = "ownersUnknown"
        break
      }
      if (owners.has(userId)) {
        report.skipped.push({ userId, reason: "owned" })
        continue
      }
      // Marker first, removed last: an interrupted sweep is finished later.
      await fs.writeFile(marker, JSON.stringify({ at: (options.now ?? (() => Date.now()))() }))
      if (hasPool) await fs.remove(segments(options.poolDirectory(userId)))
      await fs.remove([...root, "media"])
      for (const name of await fs.directories(root)) await fs.remove([...root, name])
      await fs.remove(marker)
      await fs.remove(root)
      report.removed.push(userId)
      options.log?.info("account storage swept", { userId, pool: hasPool })
    } catch (error) {
      // A busy access handle (a worker still closing) or a quota error: next start.
      report.skipped.push({ userId, reason: "failed" })
      options.log?.warn("account storage sweep failed", { userId, error })
    } finally {
      lock.release()
    }
  }
  return report
}

// ---------------------------------------------------------------------------
// Browser wiring

/** The owners an auth state shows; undefined while it cannot say. */
export const ownersFromAuthState = (state: {
  readonly hasHydrated: boolean
  readonly storageStatus: string
  readonly currentUserId: UserID | null
  readonly userIdHint: UserID | null
}): ReadonlySet<UserID> | undefined => {
  if (!state.hasHydrated || state.storageStatus !== "ready") return undefined
  const owners = new Set<UserID>()
  if (state.currentUserId) owners.add(state.currentUserId)
  if (state.userIdHint) owners.add(state.userIdHint)
  return owners
}

type DirectoryHandle = {
  getDirectoryHandle(name: string, options?: { create?: boolean }): Promise<DirectoryHandle>
  getFileHandle(name: string, options?: { create?: boolean }): Promise<{
    createWritable(): Promise<{ write(data: string): Promise<void>; close(): Promise<void> }>
  }>
  removeEntry(name: string, options?: { recursive?: boolean }): Promise<void>
  entries(): AsyncIterable<[string, { kind: string }]>
}

const isNotFound = (error: unknown) =>
  typeof error === "object" &&
  error !== null &&
  "name" in error &&
  ((error as { name: unknown }).name === "NotFoundError" || (error as { name: unknown }).name === "TypeMismatchError")

/** `SweepFileSystem` over the origin private file system. Works on the main thread (no sync access handles). */
export const opfsSweepFileSystem = (root: () => Promise<DirectoryHandle>): SweepFileSystem => {
  const directory = async (path: readonly string[], create: boolean): Promise<DirectoryHandle | undefined> => {
    let current = await root()
    for (const segment of path) {
      try {
        current = await current.getDirectoryHandle(segment, { create })
      } catch (error) {
        if (!create && isNotFound(error)) return undefined
        throw error
      }
    }
    return current
  }
  return {
    directories: async (path) => {
      const handle = await directory(path, false)
      if (!handle) return []
      const names: string[] = []
      for await (const [name, entry] of handle.entries()) if (entry.kind === "directory") names.push(name)
      return names
    },
    fileExists: async (path) => {
      const parent = await directory(path.slice(0, -1), false)
      const name = path.at(-1)
      if (!parent || name === undefined) return false
      try {
        await parent.getFileHandle(name)
        return true
      } catch (error) {
        if (isNotFound(error)) return false
        throw error
      }
    },
    writeFile: async (path, text) => {
      const parent = await directory(path.slice(0, -1), true)
      const name = path.at(-1)
      if (!parent || name === undefined) throw new TypeError("empty path")
      const writable = await (await parent.getFileHandle(name, { create: true })).createWritable()
      await writable.write(text)
      await writable.close()
    },
    remove: async (path) => {
      const parent = await directory(path.slice(0, -1), false)
      const name = path.at(-1)
      if (!parent || name === undefined) return
      try {
        await parent.removeEntry(name, { recursive: true })
      } catch (error) {
        if (!isNotFound(error)) throw error
      }
    },
  }
}

export type BrowserSweepOptions = {
  /** The auth store: its state names the owners. */
  authStore: { getState(): Parameters<typeof ownersFromAuthState>[0] }
  log?: Log
}

/**
 * The sweep with the browser's OPFS, Web Locks and idle callbacks, for the
 * app's warmup lane. Does nothing where OPFS or Web Locks are missing.
 */
export const sweepBrowserAccountStorage = async (options: BrowserSweepOptions): Promise<AccountStorageSweepReport | undefined> => {
  const storage = (globalThis as { navigator?: { storage?: { getDirectory?: () => Promise<unknown> } } }).navigator?.storage
  const locks = (globalThis as { navigator?: { locks?: unknown } }).navigator?.locks
  if (typeof storage?.getDirectory !== "function" || !locks) return undefined
  // Narrow modules on purpose: the link's and the client's main entries would
  // bring the whole link into the boot chunk and download SQLite at idle.
  const [{ getServerUrl }, { browserLocks }, { linkNames }, { sahPoolNames }] = await Promise.all([
    import("@inline/config"),
    import("@inline/link/platform"),
    import("@inline/link/names"),
    import("@inline/client/sqlite/pool-names"),
  ])
  // The same namespace (`core.worker.ts`) and lock origin (`connect.ts`) the app uses.
  let namespace = "default"
  let origin = "default"
  try {
    const url = new URL(getServerUrl())
    namespace = url.host
    origin = url.origin
  } catch {
    // Keep the defaults, as those files do.
  }
  const lockManager = browserLocks()
  const scope = globalThis as { requestIdleCallback?: (fn: () => void) => unknown }
  const report = await sweepAccountStorage({
    fs: opfsSweepFileSystem(() => storage.getDirectory!() as Promise<DirectoryHandle>),
    poolDirectory: (userId) => sahPoolNames({ accountId: userId, namespace }).directory,
    owners: () => ownersFromAuthState(options.authStore.getState()),
    tryLockAccount: (userId) => lockManager.tryAcquire(linkNames({ origin, userId }).locks.leader),
    pause: () =>
      new Promise<void>((resolve) => {
        // Called on the global, never detached (a detached platform function throws in browsers).
        if (typeof scope.requestIdleCallback === "function") scope.requestIdleCallback(() => resolve())
        else setTimeout(() => resolve(), 0)
      }),
    ...(options.log ? { log: options.log } : {}),
  })
  if (report.removed.length > 0 || report.skipped.some((skip) => skip.reason !== "owned") || report.stopped) {
    options.log?.info("account storage sweep", {
      removed: report.removed.length,
      skipped: report.skipped.length,
      ...(report.stopped ? { stopped: report.stopped } : {}),
    })
  }
  return report
}
