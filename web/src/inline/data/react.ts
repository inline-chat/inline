import {
  DbObjectKind,
  DbQueryPlanType,
  type DbObjectId,
  type DbModels,
  type DbObjectRef,
  useClientDb,
} from "@inline/client"
import { useCallback, useMemo, useSyncExternalStore } from "react"

export function useInlineObject<K extends DbObjectKind, O extends DbModels[K]>(
  kind: K,
  id: DbObjectId<K> | undefined,
): O | undefined {
  const db = useClientDb()
  const ref = useMemo(() => (id == null ? undefined : db.ref(kind, id)), [db, id, kind])

  const subscribe = useCallback(
    (listener: () => void) => {
      if (!ref) return () => undefined
      return db.subscribeToObject(ref, listener).unsubscribe
    },
    [db, ref],
  )

  const snapshot = useCallback(() => (ref ? db.get<K, O>(ref) : undefined), [db, ref])
  return useSyncExternalStore(subscribe, snapshot, snapshot)
}

export function useInlineQuery<K extends DbObjectKind, O extends DbModels[K]>(
  key: string,
  kind: K,
  predicate: (object: O) => boolean,
): O[] {
  const db = useClientDb()
  const queryKey = `${kind}:${key}`

  const subscribe = useCallback(
    (listener: () => void) =>
      db.subscribeToQuery(queryKey, DbQueryPlanType.Objects, kind, predicate, listener).unsubscribe,
    [db, kind, predicate, queryKey],
  )

  const snapshot = useCallback(
    () => db.queryCached<K, O, DbQueryPlanType.Objects>(queryKey, DbQueryPlanType.Objects, kind, predicate),
    [db, kind, predicate, queryKey],
  )

  return useSyncExternalStore(subscribe, snapshot, snapshot)
}

export function useInlineRef<K extends DbObjectKind>(
  kind: K,
  id: DbObjectId<K> | undefined,
): DbObjectRef<K> | undefined {
  const db = useClientDb()
  return useMemo(() => (id == null ? undefined : db.ref(kind, id)), [db, id, kind])
}
