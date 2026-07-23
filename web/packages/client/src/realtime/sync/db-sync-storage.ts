import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import type { SyncBucketCursor, SyncBucketKey, SyncState } from "./sync-types"
import { syncBucketId } from "./sync-types"
import type { SyncStorage } from "./sync-storage"

export class DbSyncStorage implements SyncStorage {
  private initializeTask: Promise<void> | null = null
  private state: SyncState = { lastSyncDate: 0 }
  private readonly buckets = new Map<string, SyncBucketCursor>()

  constructor(private readonly db: Db) {}

  initialize() {
    this.initializeTask ??= (async () => {
      await this.db.hydrateKinds([
        DbObjectKind.SyncGlobalState,
        DbObjectKind.SyncBucketState,
      ])
      const state = this.db.get(
        this.db.ref(DbObjectKind.SyncGlobalState, 0),
      )
      this.state = {
        lastSyncDate: state?.lastSyncDate ?? 0,
      }
      const buckets = this.db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.SyncBucketState,
        () => true,
      )
      this.buckets.clear()
      for (const bucket of buckets) {
        this.buckets.set(bucket.id, {
          seq: bucket.seq,
          date: bucket.date,
        })
      }
    })()
    return this.initializeTask
  }

  async getState(): Promise<SyncState> {
    await this.initialize()
    return { ...this.state }
  }

  async setState(state: SyncState) {
    await this.initialize()
    try {
      await this.db.commit(() => {
        this.db.replace({
          kind: DbObjectKind.SyncGlobalState,
          id: 0,
          lastSyncDate: state.lastSyncDate,
        })
      })
      this.state = { ...state }
      return true
    } catch {
      return false
    }
  }

  async getBucketState(key: SyncBucketKey): Promise<SyncBucketCursor> {
    await this.initialize()
    return {
      ...(this.buckets.get(syncBucketId(key)) ?? { date: 0, seq: 0 }),
    }
  }

  async setBucketState(key: SyncBucketKey, state: SyncBucketCursor) {
    return await this.commitBucketState(key, state, () => undefined)
  }

  async commitBucketState(
    key: SyncBucketKey,
    state: SyncBucketCursor,
    apply: () => void,
  ) {
    await this.initialize()
    const id = syncBucketId(key)
    try {
      await this.db.commit(() => {
        apply()
        this.db.replace({
          kind: DbObjectKind.SyncBucketState,
          id,
          seq: state.seq,
          date: state.date,
        })
      })
      this.buckets.set(id, { ...state })
      return true
    } catch {
      return false
    }
  }

  async removeBucketState(key: SyncBucketKey) {
    await this.initialize()
    const id = syncBucketId(key)
    try {
      await this.db.commit(() => {
        this.db.delete(
          this.db.ref(DbObjectKind.SyncBucketState, id),
        )
      })
      this.buckets.delete(id)
      return true
    } catch {
      return false
    }
  }

  async clear() {
    await this.initialize()
    const buckets = this.db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.SyncBucketState,
      () => true,
    )
    try {
      await this.db.commit(() => {
        for (const bucket of buckets) {
          this.db.delete(
            this.db.ref(
              DbObjectKind.SyncBucketState,
              bucket.id,
            ),
          )
        }
        this.db.delete(
          this.db.ref(DbObjectKind.SyncGlobalState, 0),
        )
      })
      this.state = { lastSyncDate: 0 }
      this.buckets.clear()
      return true
    } catch {
      return false
    }
  }
}
