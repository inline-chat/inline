type InlineMediaMetadataEntry = {
  fileName: string
  size: number
  lastAccessedAt: number
}

type InlineMediaMetadataUsage = {
  id: "usage"
  totalBytes: number
}

const entriesStoreName = "entries"
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

/** Small account-scoped metadata index for OPFS bytes. File names are already
 * SHA-256 media-key digests, so the index never persists signed URLs. */
export class IndexedDbInlineMediaMetadata {
  private readonly database: Promise<IDBDatabase>

  constructor(accountId: string) {
    this.database = this.open(
      `inline-media-metadata:account-${accountId}`,
    )
  }

  async get(fileName: string) {
    const database = await this.database
    const transaction = database.transaction(
      entriesStoreName,
      "readonly",
    )
    return await requestResult<
      InlineMediaMetadataEntry | undefined
    >(transaction.objectStore(entriesStoreName).get(fileName))
  }

  async record(entry: InlineMediaMetadataEntry) {
    const database = await this.database
    const transaction = database.transaction(
      [entriesStoreName, stateStoreName],
      "readwrite",
    )
    const entries = transaction.objectStore(entriesStoreName)
    const state = transaction.objectStore(stateStoreName)
    const [previous, usage] = await Promise.all([
      requestResult<InlineMediaMetadataEntry | undefined>(
        entries.get(entry.fileName),
      ),
      this.readUsage(entries, state),
    ])
    entries.put(entry)
    state.put({
      id: "usage",
      totalBytes:
        usage.totalBytes - (previous?.size ?? 0) + entry.size,
    } satisfies InlineMediaMetadataUsage)
    await transactionDone(transaction)
  }

  async remove(fileName: string) {
    const database = await this.database
    const transaction = database.transaction(
      [entriesStoreName, stateStoreName],
      "readwrite",
    )
    const entries = transaction.objectStore(entriesStoreName)
    const state = transaction.objectStore(stateStoreName)
    const [previous, usage] = await Promise.all([
      requestResult<InlineMediaMetadataEntry | undefined>(
        entries.get(fileName),
      ),
      this.readUsage(entries, state),
    ])
    entries.delete(fileName)
    state.put({
      id: "usage",
      totalBytes: Math.max(
        0,
        usage.totalBytes - (previous?.size ?? 0),
      ),
    } satisfies InlineMediaMetadataUsage)
    await transactionDone(transaction)
  }

  async totalBytes() {
    const database = await this.database
    const transaction = database.transaction(
      [entriesStoreName, stateStoreName],
      "readwrite",
    )
    const usage = await this.readUsage(
      transaction.objectStore(entriesStoreName),
      transaction.objectStore(stateStoreName),
    )
    await transactionDone(transaction)
    return usage.totalBytes
  }

  async oldest(limit: number) {
    if (limit <= 0) return []
    const database = await this.database
    const transaction = database.transaction(
      entriesStoreName,
      "readonly",
    )
    const index = transaction
      .objectStore(entriesStoreName)
      .index("last-accessed-at")
    return await new Promise<InlineMediaMetadataEntry[]>(
      (resolve, reject) => {
        const entries: InlineMediaMetadataEntry[] = []
        const request = index.openCursor()
        request.onsuccess = () => {
          const cursor = request.result
          if (!cursor || entries.length >= limit) {
            resolve(entries)
            return
          }
          entries.push(cursor.value as InlineMediaMetadataEntry)
          cursor.continue()
        }
        request.onerror = () => reject(request.error)
      },
    )
  }

  async all() {
    const database = await this.database
    const transaction = database.transaction(
      entriesStoreName,
      "readonly",
    )
    return await requestResult<InlineMediaMetadataEntry[]>(
      transaction.objectStore(entriesStoreName).getAll(),
    )
  }

  private async readUsage(
    entries: IDBObjectStore,
    state: IDBObjectStore,
  ) {
    const existing = await requestResult<
      InlineMediaMetadataUsage | undefined
    >(state.get("usage"))
    if (existing) return existing

    const all = await requestResult<InlineMediaMetadataEntry[]>(
      entries.getAll(),
    )
    const usage: InlineMediaMetadataUsage = {
      id: "usage",
      totalBytes: all.reduce((sum, entry) => sum + entry.size, 0),
    }
    state.put(usage)
    return usage
  }

  private open(name: string) {
    return new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open(name, 1)
      request.onupgradeneeded = () => {
        const database = request.result
        const entries = database.createObjectStore(
          entriesStoreName,
          { keyPath: "fileName" },
        )
        entries.createIndex(
          "last-accessed-at",
          "lastAccessedAt",
        )
        database.createObjectStore(stateStoreName, {
          keyPath: "id",
        })
      }
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }
}
