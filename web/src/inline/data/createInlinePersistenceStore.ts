import {
  createIndexedDbPersistenceStore,
  assertInlineLegacyFallbackAllowed,
  InlineStartupPersistenceStore,
  type InlinePersistenceStore,
} from "@inline/client/core"
import type { UserID } from "@inline/ids"

export type InlinePersistenceSelection = {
  accountId: UserID
}

/**
 * The single runtime selection boundary for Inline account persistence.
 *
 * IndexedDB remains the honest default until the worker-hosted SQLite/OPFS
 * adapter passes the remaining browser and cross-version ownership gates.
 * The authority check makes a promoted retained replica fail closed. Neither
 * Db nor the account core needs to change when this selection flips.
 */
export const createInlinePersistenceStore = ({
  accountId,
}: InlinePersistenceSelection): InlinePersistenceStore | null => {
  const indexedDb = createIndexedDbPersistenceStore(
    `user-${accountId}`,
  )
  if (!indexedDb) return null
  return new InlineStartupPersistenceStore({
    primary: () => indexedDb,
    preparePrimary: assertInlineLegacyFallbackAllowed,
    fallback: () => null,
    canFallback: () => false,
  })
}
