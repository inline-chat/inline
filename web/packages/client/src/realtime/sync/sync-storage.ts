import type { SyncBucketCursor, SyncBucketKey, SyncState } from "./sync-types"
import { syncBucketId } from "./sync-types"

export interface SyncStorage {
  initialize(): Promise<void>
  getState(): Promise<SyncState>
  setState(state: SyncState): Promise<boolean>
  getBucketState(key: SyncBucketKey): Promise<SyncBucketCursor>
  setBucketState(key: SyncBucketKey, state: SyncBucketCursor): Promise<boolean>
  commitBucketState?(
    key: SyncBucketKey,
    state: SyncBucketCursor,
    apply: () => void,
  ): Promise<boolean>
  removeBucketState(key: SyncBucketKey): Promise<boolean>
  clear(): Promise<boolean>
}

export class MemorySyncStorage implements SyncStorage {
  private state: SyncState = { lastSyncDate: 0 }
  private readonly buckets = new Map<string, SyncBucketCursor>()

  async initialize() {}

  async getState() {
    return this.state
  }

  async setState(state: SyncState) {
    this.state = state
    return true
  }

  async getBucketState(key: SyncBucketKey) {
    return this.buckets.get(syncBucketId(key)) ?? { date: 0, seq: 0 }
  }

  async setBucketState(key: SyncBucketKey, state: SyncBucketCursor) {
    this.buckets.set(syncBucketId(key), state)
    return true
  }

  async removeBucketState(key: SyncBucketKey) {
    this.buckets.delete(syncBucketId(key))
    return true
  }

  async clear() {
    this.state = { lastSyncDate: 0 }
    this.buckets.clear()
    return true
  }
}
