/**
 * Storage for a worker-hosted core: the account's OPFS replica, or memory
 * when the browser cannot keep one. Uses the openers in database/sqlite.
 */
import type { UserID } from "@inline/ids"
import {
  createOpfsSqlitePersistenceStore,
  createSqliteMemoryPersistenceStore,
  eraseOpfsSqliteReplica,
  isInlineSqliteStartupFallbackSafe,
  type OpfsSqliteLocation,
} from "../database/sqlite/openers"
import type { HostStorage } from "./account-core"

/**
 * Open an account's storage for `CoreHostOptions.openStorage`. Falls back to
 * memory only when the browser cannot keep a replica at all (no OPFS, not a
 * worker, permission denied). A busy or failed pool throws, so the host shows
 * a failure instead of an empty in-memory replica that hides real data.
 */
export const openOpfsHostStorage = async (
  userId: UserID,
  location?: OpfsSqliteLocation,
): Promise<HostStorage> => {
  const store = createOpfsSqlitePersistenceStore(userId, undefined, location)
  try {
    await store.open()
  } catch (error) {
    await store.close().catch(() => undefined)
    if (!isInlineSqliteStartupFallbackSafe(error)) throw error
    return {
      store: createSqliteMemoryPersistenceStore(),
      kind: "memory",
      erase: async () => undefined,
    }
  }
  return {
    store,
    kind: "persistent",
    erase: () => eraseOpfsSqliteReplica(userId, location),
  }
}

/**
 * Erase an account's OPFS replica without opening it, for
 * `CoreHostOptions.eraseStorage` (finishing an erase a killed core left).
 */
export const eraseOpfsHostStorage = (userId: UserID, location?: OpfsSqliteLocation): Promise<void> =>
  eraseOpfsSqliteReplica(userId, location)
