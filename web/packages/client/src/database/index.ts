import { DbModels, DbObjectKind } from "./models"
import { DbObjectRef, DbQueryPlan, DbQueryPlanType } from "./types"

export class Db {
  // node persistence layer
  // hydrate into buckets and form indexes
  // create ref types
  // create query hooks ( that give a light evaluation function for an object and we loop and fetch it )
  // ----- ^ we'll use this function to evaluate if a query needs to re-run on addition/removal of objects WOW.
  // a helper to generate refs from raw IDs
  // create object hooks to go from ref -> object
  // keep a list of subscriptions for objects (for updates) and queries (addition/removal) to trigger
  // goal: 1) to create a lightweight, object-based, simple, reactive cache layer that plays well with React  2) easily expandable/modular for later upgrades to every layer (persistence, hooks, queries, schema, etc)
  // we need stable refs.
  // TODO: Maybe we need to insert a private symbol in refs to ensure they come from us and are stable.

  collections: Partial<Record<DbObjectKind, Collection<DbObjectKind>>> = {}
  querySubscriptions = new Queries()
  objectSubscriptions = new ObjectSubscriptions()

  // Batching
  private batchDepth = 0
  private pendingRefs: Set<DbObjectRef<DbObjectKind>> = new Set()

  insert<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.collection(object.kind).insert(object)
    this.notify(this.ref(object.kind, object.id))
  }

  delete(ref: DbObjectRef<DbObjectKind>) {
    this.collection(ref.kind).delete(ref.id)
    this.notify(ref)
  }

  update<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.collection(object.kind).update(object)
    this.notify(this.ref(object.kind, object.id))
  }

  /** Batch multiple operations, deferring notifications until the batch completes. */
  batch(fn: () => void): void {
    this.batchDepth++
    try {
      fn()
    } finally {
      this.batchDepth--
      if (this.batchDepth === 0) {
        this.flushPendingNotifications()
      }
    }
  }

  private notify<K extends DbObjectKind>(ref: DbObjectRef<K>) {
    if (this.batchDepth > 0) {
      this.pendingRefs.add(ref)
    } else {
      this.triggerQueries(ref)
      this.triggerObjectSubscriptions(ref)
    }
  }

  private flushPendingNotifications() {
    if (this.pendingRefs.size === 0) return

    // Collect affected kinds for query invalidation
    let affectedKinds = new Set<DbObjectKind>()
    for (const ref of this.pendingRefs) {
      affectedKinds.add(ref.kind)
      this.triggerObjectSubscriptions(ref)
    }

    // Invalidate and notify queries once per kind
    for (const kind of affectedKinds) {
      this.querySubscriptions.markKindDirty(kind)
      let queriesForKind = this.querySubscriptions.getQueriesByKind(kind)
      for (const query of queriesForKind) {
        let callbacks = this.querySubscriptions.getCallbacksForKey(query.key)
        for (let callback of callbacks) {
          callback()
        }
      }
    }

    this.pendingRefs.clear()
  }

  get<K extends DbObjectKind, O extends DbModels[K]>(ref: DbObjectRef<K>): O | undefined {
    return this.collection(ref.kind).get(ref.id) as O | undefined
  }

  ref<K extends DbObjectKind>(kind: K, id: number): DbObjectRef<K> {
    return this.collection(kind).ref(id)
  }

  subscribeToObject<K extends DbObjectKind>(
    ref: DbObjectRef<K>,
    callback: () => void,
  ): { unsubscribe: () => void } {
    let { unsubscribe } = this.objectSubscriptions.subscribe(ref, callback)
    return { unsubscribe }
  }

  private triggerObjectSubscriptions<K extends DbObjectKind>(ref: DbObjectRef<K>) {
    let subscriptions = this.objectSubscriptions.getSubscriptionsForRef(ref)
    for (const subscription of subscriptions) {
      subscription()
    }
  }

  subscribeToQuery<K extends DbObjectKind, O extends DbModels[K]>(
    key: string,
    type: DbQueryPlanType,
    kind: K,
    predicate: (object: O) => boolean,
    callback: () => void,
  ): { unsubscribe: () => void } {
    let queryPlan: DbQueryPlan<K, O> = { key, type, kind, predicate }
    let { unsubscribe } = this.querySubscriptions.subscribe(queryPlan, callback)
    return { unsubscribe }
  }

  private triggerQueries<K extends DbObjectKind>(ref: DbObjectRef<K>) {
    // Mark all queries for this kind as dirty
    // Future: check predicates here to skip unaffected queries
    this.querySubscriptions.markKindDirty(ref.kind)

    // Notify subscribers
    let queriesForKind = this.querySubscriptions.getQueriesByKind(ref.kind)
    for (const query of queriesForKind) {
      let callbacks = this.querySubscriptions.getCallbacksForKey(query.key)
      for (let callback of callbacks) {
        callback()
      }
    }
  }

  queryCollection<K extends DbObjectKind, O extends DbModels[K], T extends DbQueryPlanType>(
    type: T,
    kind: K,
    predicate: (object: O) => boolean = () => true,
  ): T extends DbQueryPlanType.Objects ? O[] : DbObjectRef<K>[] {
    if (type === DbQueryPlanType.Objects) {
      return this.collection<K, O>(kind).getAll(predicate) as T extends DbQueryPlanType.Objects ? O[] : never
    } else {
      return this.collection<K, O>(kind).getAllRefs(predicate) as T extends DbQueryPlanType.Objects
        ? never
        : DbObjectRef<K>[]
    }
  }

  /** Cached version of queryCollection. Returns cached result if valid, otherwise computes fresh. */
  queryCached<K extends DbObjectKind, O extends DbModels[K], T extends DbQueryPlanType>(
    key: string,
    type: T,
    kind: K,
    predicate: (object: O) => boolean = () => true,
  ): T extends DbQueryPlanType.Objects ? O[] : DbObjectRef<K>[] {
    if (!this.querySubscriptions.isDirty(key)) {
      return this.querySubscriptions.getCachedResult(key)!
    }
    const result = this.queryCollection<K, O, T>(type, kind, predicate)
    this.querySubscriptions.setCachedResult(key, result)
    return result
  }

  // Private
  private collection<K extends DbObjectKind, O extends DbModels[K]>(kind: K): Collection<K, O> {
    if (!this.collections[kind]) {
      this.collections[kind] = new Collection<K, O>(kind)
    }
    return this.collections[kind] as Collection<K, O>
  }
}

class Collection<K extends DbObjectKind, O extends DbModels[K] = DbModels[K]> {
  kind: K
  ids: Set<number> = new Set()
  objectsById: Map<number, O> = new Map()
  // stable refs by ID
  refs: Map<number, DbObjectRef<K>> = new Map()

  constructor(kind: K) {
    this.kind = kind
  }

  ref(id: number): DbObjectRef<K> {
    let ref = this.refs.get(id)
    if (!ref) {
      ref = { kind: this.kind, id } as DbObjectRef<K>
      this.refs.set(id, ref)
    }
    return ref
  }

  insert(object: O) {
    this.ids.add(object.id)
    // Insert is a replace if the object already exists.
    this.objectsById.set(object.id, object)
  }

  delete(id: number) {
    this.ids.delete(id)
    this.objectsById.delete(id)
  }

  update(object: O) {
    const existing = this.objectsById.get(object.id)
    if (!existing) {
      this.insert(object)
      return
    }

    const merged = { ...existing }
    for (const [key, value] of Object.entries(object) as [keyof O, O[keyof O]][]) {
      if (value !== undefined) {
        merged[key] = value
      }
    }

    this.objectsById.set(object.id, merged)
  }

  get(id: number): O | undefined {
    return this.objectsById.get(id)
  }

  getAll(predicate: (object: O) => boolean = () => true): O[] {
    // optimize memory???
    let objects: O[] = []
    for (const id of this.ids) {
      const object = this.objectsById.get(id)
      if (object && predicate(object)) {
        objects.push(object)
      }
    }
    return objects
  }

  getAllRefs(predicate: (object: O) => boolean = () => true): DbObjectRef<K>[] {
    let refs: DbObjectRef<K>[] = []
    for (const id of this.ids) {
      const object = this.objectsById.get(id)
      if (object && predicate(object)) {
        refs.push(this.ref(id))
      }
    }
    return refs
  }
}

type QueryKey = string

class Queries {
  // Current state
  private queries: Map<QueryKey, DbQueryPlan<DbObjectKind, DbModels[DbObjectKind]>> = new Map()
  private queriesByKind: Map<DbObjectKind, Set<QueryKey>> = new Map()
  private subscriptions: Map<QueryKey, Set<() => void>> = new Map()

  // Cache
  private cachedResults: Map<QueryKey, unknown> = new Map()
  private dirtyQueries: Set<QueryKey> = new Set()

  subscribe<K extends DbObjectKind, O extends DbModels[K]>(
    query: DbQueryPlan<K, O>,
    callback: () => void,
  ) {
    this.queries.set(query.key, query as unknown as DbQueryPlan<DbObjectKind, DbModels[DbObjectKind]>)
    this.queriesByKindSet(query.kind).add(query.key)
    this.subscriptionSet(query.key).add(callback)
    this.dirtyQueries.add(query.key) // Needs initial compute

    // Unsubscribe
    return {
      unsubscribe: () => {
        this.subscriptions.get(query.key)?.delete(callback)

        // Do this with a delay to avoid immediate deletion of the query if the callback is re-added immediately
        // TODO: create a garbage collection mechanism for house keeping instead of setTimeout on every unsubscribe
        setTimeout(() => {
          this.maybeDeleteQueryIfNoSubscriptions(query.key)
        }, 50)
      },
    }
  }

  getQueriesByKind<K extends DbObjectKind, O extends DbModels[K], P extends DbQueryPlan<K, O>>(kind: K): P[] {
    let queryKeys = this.queriesByKind.get(kind)
    if (!queryKeys) return []
    let queries: P[] = []
    for (const queryKey of queryKeys) {
      let query = this.queries.get(queryKey) as P | undefined
      if (!query) continue
      queries.push(query)
    }
    return queries
  }

  getCallbacksForKey(key: QueryKey): (() => void)[] {
    return Array.from(this.subscriptions.get(key) ?? new Set())
  }

  // Cache methods

  /** Mark all queries for a kind as dirty. Future: check predicates here. */
  markKindDirty(kind: DbObjectKind) {
    let queryKeys = this.queriesByKind.get(kind)
    if (!queryKeys) return
    for (const key of queryKeys) {
      this.dirtyQueries.add(key)
    }
  }

  isDirty(key: QueryKey): boolean {
    return this.dirtyQueries.has(key) || !this.cachedResults.has(key)
  }

  getCachedResult<T>(key: QueryKey): T | undefined {
    return this.cachedResults.get(key) as T | undefined
  }

  setCachedResult(key: QueryKey, result: unknown) {
    this.cachedResults.set(key, result)
    this.dirtyQueries.delete(key)
  }

  // Private
  private queriesByKindSet(kind: DbObjectKind): Set<QueryKey> {
    if (!this.queriesByKind.has(kind)) {
      this.queriesByKind.set(kind, new Set())
    }
    return this.queriesByKind.get(kind) as Set<QueryKey>
  }

  private subscriptionSet(key: QueryKey): Set<() => void> {
    if (!this.subscriptions.has(key)) {
      this.subscriptions.set(key, new Set())
    }
    return this.subscriptions.get(key)!
  }

  private deleteQuery<K extends DbObjectKind, O extends DbModels[K]>(key: QueryKey) {
    let query = this.queries.get(key) as DbQueryPlan<K, O> | undefined
    if (!query) return
    this.queries.delete(key)
    this.queriesByKindSet(query.kind).delete(key)
    this.cachedResults.delete(key)
    this.dirtyQueries.delete(key)
  }

  private maybeDeleteQueryIfNoSubscriptions(key: QueryKey) {
    if (this.subscriptions.get(key)?.size === 0) {
      this.deleteQuery(key)
    }
  }
}

// TODO: Improve type-safety of object here

class ObjectSubscriptions {
  private subscriptions: Map<DbObjectRef<DbObjectKind>, Set<() => void>> = new Map()

  subscribe<K extends DbObjectKind>(ref: DbObjectRef<K>, callback: () => void) {
    this.subscriptionSet(ref).add(callback)

    return {
      unsubscribe: () => {
        this.subscriptionSet(ref).delete(callback)
      },
    }
  }

  getSubscriptionsForRef<K extends DbObjectKind>(ref: DbObjectRef<K>): Set<() => void> {
    return this.subscriptions.get(ref) ?? new Set()
  }

  private subscriptionSet(ref: DbObjectRef<DbObjectKind>): Set<() => void> {
    if (!this.subscriptions.has(ref)) {
      this.subscriptions.set(ref, new Set())
    }
    return this.subscriptions.get(ref)!
  }
}

export let db = new Db()
