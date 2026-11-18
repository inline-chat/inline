import type { UserID } from "@inline/ids"
import type { Db } from "../../database"

/**
 * Per-account context the update layer needs beyond the store: who the
 * account is (a removal of this user is an access loss) and which chats and
 * spaces lost access since a page was fetched (the fence).
 *
 * Kept beside the `Db` rather than inside it so `Db`'s signature is stable.
 * The realtime client binds the account; tests bind it directly.
 */
type AccountContext = {
  accountUserId: () => UserID | undefined
  /** Sync bucket IDs purged for access loss, with the revision of the purge. */
  purged: Map<string, number>
  revision: number
}

const contexts = new WeakMap<Db, AccountContext>()

const context = (db: Db): AccountContext => {
  let found = contexts.get(db)
  if (!found) {
    found = { accountUserId: () => undefined, purged: new Map(), revision: 0 }
    contexts.set(db, found)
  }
  return found
}

/** Tell the update layer which user owns this store. */
export const bindAccountUser = (
  db: Db,
  accountUserId: () => UserID | null | undefined,
) => {
  context(db).accountUserId = () => accountUserId() ?? undefined
}

export const accountUserId = (db: Db): UserID | undefined =>
  context(db).accountUserId()

/**
 * Record that a bucket's chat or space was purged for access loss. A page or
 * repair for it that is still in flight must not write it back (core.md,
 * "Sync"). The mark holds until the chat or space is stored again.
 */
export const markBucketPurged = (db: Db, bucketId: string) => {
  const found = context(db)
  found.revision += 1
  found.purged.set(bucketId, found.revision)
}

export const isBucketPurged = (db: Db, bucketId: string) =>
  context(db).purged.has(bucketId)

/** The bucket's chat or space is local again: its pages may apply. */
export const clearBucketPurged = (db: Db, bucketId: string) => {
  context(db).purged.delete(bucketId)
}
