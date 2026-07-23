import {
  defaultInlineMediaCacheBytes,
  type InlineMediaCache,
  type InlineMediaCacheOptions,
} from "./InlineMediaCache"

type MediaMetadata = {
  key: string
  size: number
  lastAccessedAt: number
}

type MediaUsage = {
  id: "usage"
  totalBytes: number
}

const fileStoreName = "files"
const metadataStoreName = "metadata"
const stateStoreName = "state"

const requestResult = <T>(request: IDBRequest<T>) =>
  new Promise<T>((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })

const transactionDone = (transaction: IDBTransaction) =>
  new Promise<void>((resolve, reject) => {
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(transaction.error)
    transaction.onabort = () => reject(transaction.error)
  })

export class IndexedDbInlineMediaCache implements InlineMediaCache {
  private readonly maxBytes: number
  private readonly database: Promise<IDBDatabase>
  private mutationTail = Promise.resolve()

  constructor({ accountId, maxBytes = defaultInlineMediaCacheBytes }: InlineMediaCacheOptions) {
    this.maxBytes = maxBytes
    this.database = this.open(`inline-media-cache:account-${accountId}`)
  }

  async get(key: string) {
    const database = await this.database
    const transaction = database.transaction(
      [fileStoreName, metadataStoreName],
      "readwrite",
    )
    const blob = await requestResult<Blob | undefined>(
      transaction.objectStore(fileStoreName).get(key),
    )
    if (blob) {
      transaction.objectStore(metadataStoreName).put({
        key,
        size: blob.size,
        lastAccessedAt: Date.now(),
      } satisfies MediaMetadata)
    }
    await transactionDone(transaction)
    return blob
  }

  async put(key: string, blob: Blob) {
    if (blob.size > this.maxBytes) return
    return await this.mutate(async () => {
      const database = await this.database
      const previous = await this.metadataFor(database, key)
      await this.evict(
        database,
        Math.max(0, this.maxBytes - blob.size + (previous?.size ?? 0)),
        key,
      )
      try {
        await this.putEntry(database, key, blob)
      } catch (cause) {
        if (!this.isQuotaError(cause)) throw cause
        await this.evict(database, 0, key)
        await this.putEntry(database, key, blob)
      }
    })
  }

  private open(name: string) {
    return new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open(name, 2)
      request.onupgradeneeded = () => {
        const database = request.result
        if (!database.objectStoreNames.contains(fileStoreName)) {
          database.createObjectStore(fileStoreName)
        }
        if (!database.objectStoreNames.contains(metadataStoreName)) {
          const metadata = database.createObjectStore(metadataStoreName, { keyPath: "key" })
          metadata.createIndex("last-accessed-at", "lastAccessedAt")
        }
        if (!database.objectStoreNames.contains(stateStoreName)) {
          database.createObjectStore(stateStoreName, {
            keyPath: "id",
          })
        }
      }
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  private async putEntry(
    database: IDBDatabase,
    key: string,
    blob: Blob,
  ) {
    const transaction = database.transaction(
      [fileStoreName, metadataStoreName, stateStoreName],
      "readwrite",
    )
    const files = transaction.objectStore(fileStoreName)
    const metadata = transaction.objectStore(metadataStoreName)
    const state = transaction.objectStore(stateStoreName)
    const [previous, usage] = await Promise.all([
      requestResult<MediaMetadata | undefined>(metadata.get(key)),
      this.readUsage(metadata, state),
    ])
    files.put(blob, key)
    metadata.put({
      key,
      size: blob.size,
      lastAccessedAt: Date.now(),
    } satisfies MediaMetadata)
    state.put({
      id: "usage",
      totalBytes:
        usage.totalBytes - (previous?.size ?? 0) + blob.size,
    } satisfies MediaUsage)
    await transactionDone(transaction)
  }

  private async evict(
    database: IDBDatabase,
    targetBytes: number,
    excludedKey?: string,
  ) {
    const transaction = database.transaction(
      [fileStoreName, metadataStoreName, stateStoreName],
      "readwrite",
    )
    const files = transaction.objectStore(fileStoreName)
    const metadata = transaction.objectStore(metadataStoreName)
    const state = transaction.objectStore(stateStoreName)
    const usage = await this.readUsage(metadata, state)
    let totalBytes = usage.totalBytes
    if (totalBytes > targetBytes) {
      const index = metadata.index("last-accessed-at")
      await new Promise<void>((resolve, reject) => {
        const request = index.openCursor()
        request.onsuccess = () => {
          const cursor = request.result
          if (!cursor || totalBytes <= targetBytes) {
            resolve()
            return
          }
          const entry = cursor.value as MediaMetadata
          if (entry.key === excludedKey) {
            cursor.continue()
            return
          }
          files.delete(entry.key)
          cursor.delete()
          totalBytes = Math.max(0, totalBytes - entry.size)
          cursor.continue()
        }
        request.onerror = () => reject(request.error)
      })
    }
    state.put({ id: "usage", totalBytes } satisfies MediaUsage)
    await transactionDone(transaction)
  }

  private async metadataFor(database: IDBDatabase, key: string) {
    const transaction = database.transaction(metadataStoreName, "readonly")
    const result = await requestResult<MediaMetadata | undefined>(
      transaction.objectStore(metadataStoreName).get(key),
    )
    await transactionDone(transaction)
    return result
  }

  private mutate<T>(operation: () => Promise<T>) {
    const result = this.mutationTail.then(operation, operation)
    this.mutationTail = result.then(
      () => undefined,
      () => undefined,
    )
    return result
  }

  private async readUsage(
    metadata: IDBObjectStore,
    state: IDBObjectStore,
  ) {
    const existing = await requestResult<MediaUsage | undefined>(
      state.get("usage"),
    )
    if (existing) return existing
    const entries = await requestResult<MediaMetadata[]>(metadata.getAll())
    const usage: MediaUsage = {
      id: "usage",
      totalBytes: entries.reduce((sum, entry) => sum + entry.size, 0),
    }
    state.put(usage)
    return usage
  }

  private isQuotaError(cause: unknown) {
    return cause instanceof DOMException && cause.name === "QuotaExceededError"
  }
}
