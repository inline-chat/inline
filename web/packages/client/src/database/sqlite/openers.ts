import type {
  Database,
  SAHPoolUtil,
  Sqlite3Static,
} from "@sqlite.org/sqlite-wasm"
import type { UserID } from "@inline/ids"
import { InlineSqliteUnavailableError } from "./errors"
import {
  SahPoolRegistry,
  type SahPoolLocation,
} from "./sah-pool-registry"
import {
  SQLitePersistenceStore,
  type SQLitePersistenceStoreOptions,
} from "./SQLitePersistenceStore"

export {
  InlineSqliteUnavailableError,
  isInlineSqliteStartupFallbackSafe,
  type InlineSqliteUnavailableReason,
} from "./errors"
export {
  isSahPoolBusyError,
  sahPoolNames,
  SahPoolRegistry,
  type SahPoolLocation,
} from "./sah-pool-registry"

let sqlitePromise: Promise<Sqlite3Static> | null = null

const sqlite = () => {
  if (!sqlitePromise) {
    sqlitePromise = import("@sqlite.org/sqlite-wasm").then(
      ({ default: initialize }) => initialize(),
    )
  }
  return sqlitePromise
}

const hasOpfsSyncAccessHandles = () => {
  const scope = globalThis as typeof globalThis & {
    FileSystemHandle?: unknown
    FileSystemDirectoryHandle?: unknown
    FileSystemFileHandle?: {
      prototype?: { createSyncAccessHandle?: unknown }
    }
  }
  return (
    !!scope.FileSystemHandle &&
    !!scope.FileSystemDirectoryHandle &&
    !!scope.FileSystemFileHandle &&
    typeof scope.FileSystemFileHandle.prototype
      ?.createSyncAccessHandle === "function" &&
    typeof navigator !== "undefined" &&
    typeof navigator.storage?.getDirectory === "function"
  )
}

const sqliteForWorker = async () => {
  if (typeof document !== "undefined") {
    throw new InlineSqliteUnavailableError("worker-required")
  }
  if (!hasOpfsSyncAccessHandles()) {
    throw new InlineSqliteUnavailableError("opfs-unsupported")
  }
  try {
    return await sqlite()
  } catch (cause) {
    throw new InlineSqliteUnavailableError(
      "wasm-initialization-failed",
      { cause },
    )
  }
}

/**
 * One pool per account. See `sah-pool-registry.ts` for why a failed
 * installation neither deletes the replica nor blocks the next attempt.
 */
const pools = new SahPoolRegistry<SAHPoolUtil>({
  install: async (options) => {
    const sqlite3 = await sqliteForWorker()
    return sqlite3.installOpfsSAHPoolVfs(options)
  },
})

export type OpfsSqliteLocation = {
  /** See `SahPoolLocation.namespace`. */
  namespace?: string
}

const poolLocation = (
  accountId: UserID,
  location?: OpfsSqliteLocation,
): SahPoolLocation => ({
  accountId,
  ...(location?.namespace ? { namespace: location.namespace } : {}),
})

const REPLICA_FILENAME = "/replica.sqlite3"

export const createSqliteMemoryPersistenceStore = (
  options?: SQLitePersistenceStoreOptions,
) =>
  new SQLitePersistenceStore(
    async (): Promise<Database> => {
      const sqlite3 = await sqlite()
      return new sqlite3.oo1.DB(":memory:", "c")
    },
    options,
  )

/**
 * The account's replica on OPFS. Opening throws `InlineSqliteUnavailableError`
 * with reason `opfs-busy` when another context still holds the account's
 * storage after the built-in retries; the files are left untouched and a
 * later attempt can succeed.
 */
export const createOpfsSqlitePersistenceStore = (
  accountId: UserID,
  options?: SQLitePersistenceStoreOptions,
  location?: OpfsSqliteLocation,
) =>
  new SQLitePersistenceStore(
    async () => {
      const pool = await pools.acquire(poolLocation(accountId, location))
      return new pool.OpfsSAHPoolDb(REPLICA_FILENAME)
    },
    options,
  )

/**
 * Delete one account's replica and its pool directory. Close the account's
 * store first. Other accounts are not touched.
 */
export const eraseOpfsSqliteReplica = async (
  accountId: UserID,
  location?: OpfsSqliteLocation,
): Promise<void> => {
  const target = poolLocation(accountId, location)
  const pool = await pools.acquire(target)
  try {
    await pool.wipeFiles()
    await pool.removeVfs()
  } finally {
    pools.forget(target)
  }
}
