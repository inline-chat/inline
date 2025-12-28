import { DbModels, DbObjectKind } from "./models"

type CollectionStorage<O extends { id: number }> = {
  init: () => Promise<void>
  get: (id: number) => Promise<O | undefined>
  getAll: () => Promise<O[]>
  put: (object: O) => Promise<void>
  delete: (id: number) => Promise<void>
}

const DEFAULT_DB_NAME = "inline-client-db"
const DEFAULT_STORE_NAME = "objects"
const DEFAULT_KIND_INDEX = "kind"

class IndexedDbStorage<K extends DbObjectKind, O extends DbModels[K]> implements CollectionStorage<O> {
  private dbPromise: Promise<IDBDatabase> | null = null

  constructor(
    private kind: K,
    private dbName: string = DEFAULT_DB_NAME,
    private storeName: string = DEFAULT_STORE_NAME,
    private kindIndex: string = DEFAULT_KIND_INDEX,
  ) {}

  async init(): Promise<void> {
    await this.open()
  }

  async get(id: number): Promise<O | undefined> {
    return this.read((store) => store.get([this.kind, id])) as Promise<O | undefined>
  }

  async getAll(): Promise<O[]> {
    return this.read((store) => store.index(this.kindIndex).getAll(this.kind)) as Promise<O[]>
  }

  async put(object: O): Promise<void> {
    await this.write((store) => {
      store.put(object)
    })
  }

  async delete(id: number): Promise<void> {
    await this.write((store) => {
      store.delete([this.kind, id])
    })
  }

  private open(): Promise<IDBDatabase> {
    if (!this.dbPromise) {
      this.dbPromise = new Promise((resolve, reject) => {
        const request = indexedDB.open(this.dbName, 1)
        request.onupgradeneeded = () => {
          const db = request.result
          let store: IDBObjectStore
          if (!db.objectStoreNames.contains(this.storeName)) {
            store = db.createObjectStore(this.storeName, { keyPath: ["kind", "id"] })
          } else {
            store = request.transaction!.objectStore(this.storeName)
          }
          if (!store.indexNames.contains(this.kindIndex)) {
            store.createIndex(this.kindIndex, "kind", { unique: false })
          }
        }
        request.onsuccess = () => resolve(request.result)
        request.onerror = () => reject(request.error)
      })
    }
    return this.dbPromise
  }

  private async read<T>(fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.open()
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readonly")
      const store = transaction.objectStore(this.storeName)
      const request = fn(store)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  private async write(fn: (store: IDBObjectStore) => void): Promise<void> {
    const db = await this.open()
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readwrite")
      const store = transaction.objectStore(this.storeName)
      fn(store)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }
}

const supportsIndexedDb = () => typeof indexedDB !== "undefined" && typeof indexedDB.open === "function"

const createCollectionStorage = <K extends DbObjectKind, O extends DbModels[K]>(
  kind: K,
): CollectionStorage<O> | null => {
  if (supportsIndexedDb()) {
    return new IndexedDbStorage(kind)
  }
  return null
}

export { createCollectionStorage }
export type { CollectionStorage }
