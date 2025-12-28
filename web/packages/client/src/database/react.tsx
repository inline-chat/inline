import { useCallback, useMemo, useSyncExternalStore } from "react"
import { db } from "./index"
import { DbModels, DbObjectKind } from "./models"
import { DbObjectRef, DbQueryPlanType } from "./types"

const defaultPredicate = () => true

/** Get a stable ref for a given kind and id. Returns undefined if id is undefined. */
export function useObjectRef<K extends DbObjectKind>(kind: K, id: number | undefined): DbObjectRef<K> | undefined {
  return useMemo(() => (id !== undefined ? db.ref(kind, id) : undefined), [kind, id])
}

/** Subscribe to a single object by ref. Returns the object or undefined if not found. */
export function useObject<K extends DbObjectKind, O extends DbModels[K]>(
  ref: DbObjectRef<K> | undefined,
): O | undefined {
  const subscribe = useCallback(
    (onStoreChange: () => void) => {
      if (!ref) return () => {}
      const { unsubscribe } = db.subscribeToObject(ref, onStoreChange)
      return unsubscribe
    },
    [ref],
  )

  const getSnapshot = useCallback(() => {
    if (!ref) return undefined
    return db.get<K, O>(ref)
  }, [ref])

  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot)
}

/** Subscribe to a query that returns objects. */
export function useQueryObjects<K extends DbObjectKind, O extends DbModels[K]>(
  kind: K,
  predicate: (object: O) => boolean = defaultPredicate,
): O[] {
  const key = useMemo(() => `query:${kind}:objects:${predicate.toString()}`, [kind, predicate])

  const subscribe = useCallback(
    (onStoreChange: () => void) => {
      const { unsubscribe } = db.subscribeToQuery(key, DbQueryPlanType.Objects, kind, predicate, onStoreChange)
      return unsubscribe
    },
    [key, kind, predicate],
  )

  const getSnapshot = useCallback(() => {
    return db.queryCached<K, O, DbQueryPlanType.Objects>(key, DbQueryPlanType.Objects, kind, predicate)
  }, [key, kind, predicate])

  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot)
}

/** Subscribe to a query that returns refs. */
export function useQueryRefs<K extends DbObjectKind, O extends DbModels[K]>(
  kind: K,
  predicate: (object: O) => boolean = defaultPredicate,
): DbObjectRef<K>[] {
  const key = useMemo(() => `query:${kind}:refs:${predicate.toString()}`, [kind, predicate])

  const subscribe = useCallback(
    (onStoreChange: () => void) => {
      const { unsubscribe } = db.subscribeToQuery(key, DbQueryPlanType.Refs, kind, predicate, onStoreChange)
      return unsubscribe
    },
    [key, kind, predicate],
  )

  const getSnapshot = useCallback(() => {
    return db.queryCached<K, O, DbQueryPlanType.Refs>(key, DbQueryPlanType.Refs, kind, predicate)
  }, [key, kind, predicate])

  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot)
}
