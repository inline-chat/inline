import { useCallback, useSyncExternalStore } from "react"
import { DbObjectKind, DbQueryPlanType, type Db, type DbModels } from "@inline/client/core"

// These are in-memory committed projections. Persistent reads belong to controllers.
export function useRows<K extends DbObjectKind>(db: Db, kind: K): DbModels[K][] {
  const subscribe = useCallback(
    (listener: () => void) =>
      db.subscribeToResidentChanges((batch) => {
        if (batch.changes.some((change) => change.kind === kind)) listener()
      }),
    [db, kind]
  )
  const getSnapshot = useCallback(
    () => db.queryCached(`web:${kind}`, DbQueryPlanType.Objects, kind, () => true) as DbModels[K][],
    [db, kind]
  )
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot)
}

export { nameForUser } from "./conversation/projection"

export function safeMediaUrl(value?: string): string | undefined {
  if (!value) return
  try {
    const url = new URL(value)
    if (
      url.protocol === "https:" ||
      (url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname))
    )
      return url.href
  } catch {
    /* malformed remote value */
  }
}
