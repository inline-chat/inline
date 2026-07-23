import {
  assertInlineLegacyFallbackAllowed,
  createIndexedDbPersistenceStore,
  importIndexedDbReplicaIntoSqlite,
  InlineReplicaImportError,
  InlineStartupPersistenceStore,
} from "@inline/client/core"
import {
  createOpfsSqlitePersistenceStore,
  isInlineSqliteStartupFallbackSafe,
  SQLitePersistenceStore,
} from "@inline/client/sqlite"
import type { InlinePersistenceSelection } from "./createInlinePersistenceStore"

/**
 * SQLite/OPFS promotion candidate. This module is intentionally outside the
 * production account-core graph until the Alpha storage gate selects it.
 */
export const createInlineWorkerPersistenceStore = ({
  accountId,
}: InlinePersistenceSelection) =>
  new InlineStartupPersistenceStore({
    primary: () => createOpfsSqlitePersistenceStore(accountId),
    preparePrimary: async (primary) => {
      if (!(primary instanceof SQLitePersistenceStore)) {
        throw new InlineReplicaImportError(
          "Inline SQLite import target has the wrong adapter type",
        )
      }
      const source = createIndexedDbPersistenceStore(
        `user-${accountId}`,
      )
      if (!source) {
        throw new InlineReplicaImportError(
          "Inline legacy IndexedDB source is unavailable",
        )
      }
      await importIndexedDbReplicaIntoSqlite({
        source,
        target: primary,
      })
    },
    fallback: () =>
      createIndexedDbPersistenceStore(`user-${accountId}`),
    prepareFallback: assertInlineLegacyFallbackAllowed,
    canFallback: isInlineSqliteStartupFallbackSafe,
  })
