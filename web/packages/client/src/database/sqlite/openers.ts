import type {
  Database,
  SAHPoolUtil,
  Sqlite3Static,
} from "@sqlite.org/sqlite-wasm"
import type { UserID } from "@inline/ids"
import {
  SQLitePersistenceStore,
  type SQLitePersistenceStoreOptions,
} from "./SQLitePersistenceStore"

let sqlitePromise: Promise<Sqlite3Static> | null = null
let sahPoolPromise: Promise<SAHPoolUtil> | null = null

const sqlite = () => {
  if (!sqlitePromise) {
    sqlitePromise = import("@sqlite.org/sqlite-wasm").then(
      ({ default: initialize }) => initialize(),
    )
  }
  return sqlitePromise
}

export type InlineSqliteUnavailableReason =
  | "worker-required"
  | "opfs-unsupported"
  | "opfs-permission-denied"
  | "wasm-initialization-failed"
  | "opfs-initialization-failed"

export class InlineSqliteUnavailableError extends Error {
  constructor(
    readonly reason: InlineSqliteUnavailableReason,
    options?: ErrorOptions,
  ) {
    super(`Inline SQLite persistence unavailable: ${reason}`, options)
    this.name = "InlineSqliteUnavailableError"
  }
}

export const isInlineSqliteStartupFallbackSafe = (
  error: unknown,
): error is InlineSqliteUnavailableError =>
  error instanceof InlineSqliteUnavailableError &&
  (error.reason === "worker-required" ||
    error.reason === "opfs-unsupported" ||
    error.reason === "opfs-permission-denied")

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

const isStoragePermissionDenied = (error: unknown) =>
  typeof DOMException !== "undefined" &&
  error instanceof DOMException &&
  (error.name === "SecurityError" ||
    error.name === "NotAllowedError")

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

const sahPool = async () => {
  if (!sahPoolPromise) {
    sahPoolPromise = sqliteForWorker().then(async (sqlite3) => {
      try {
        return await sqlite3.installOpfsSAHPoolVfs({
          name: "inline-opfs-sahpool-v1",
          directory: ".inline-sqlite-v1",
          initialCapacity: 6,
        })
      } catch (cause) {
        throw new InlineSqliteUnavailableError(
          isStoragePermissionDenied(cause)
            ? "opfs-permission-denied"
            : "opfs-initialization-failed",
          { cause },
        )
      }
    })
  }
  return sahPoolPromise
}

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

export const createOpfsSqlitePersistenceStore = (
  accountId: UserID,
  options?: SQLitePersistenceStoreOptions,
) => {
  const filename = `/user-${accountId}.sqlite3`
  return new SQLitePersistenceStore(
    async () => {
      const pool = await sahPool()
      return new pool.OpfsSAHPoolDb(filename)
    },
    options,
  )
}
