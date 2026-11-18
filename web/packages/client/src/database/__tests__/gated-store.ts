import type { DbModels, DbObjectKind } from "../models"
import type {
  InlinePersistenceCollection,
  InlinePersistenceOperation,
  InlinePersistenceStore,
} from "../persistence"
import { createSqliteMemoryPersistenceStore } from "../sqlite/openers"

type Gate = { promise: Promise<void>; release: () => void }

const gate = (): Gate => {
  let release!: () => void
  const promise = new Promise<void>((resolve) => {
    release = resolve
  })
  return { promise, release }
}

const readMethods = [
  "get",
  "getMany",
  "getAll",
  "getDeferredUpdatesByTargetKeys",
  "getMessageWindowByChatId",
  "getMessageWindowAroundMessageId",
] as const

/**
 * The real SQLite store, in memory, with reads and writes a test can hold.
 *
 * A held read runs against SQLite at once (it sees the disk as it is when
 * the read starts) and delivers its rows only when the test releases reads.
 * That is exactly a read that began before a later write. A held write
 * waits before it starts its transaction.
 */
export const createGatedStore = () => {
  const inner = createSqliteMemoryPersistenceStore()
  let readGate: Gate | null = null
  let writeGate: Gate | null = null
  let heldReads = 0
  const writes: InlinePersistenceOperation[][] = []
  const collections = new Map<
    DbObjectKind,
    InlinePersistenceCollection<any>
  >()

  const store: InlinePersistenceStore = {
    open: () => inner.open(),
    close: () => inner.close(),
    collection<K extends DbObjectKind>(kind: K) {
      let collection = collections.get(kind)
      if (!collection) {
        const source = inner.collection(kind) as unknown as Record<
          string,
          (...args: unknown[]) => Promise<unknown>
        >
        const wrapped: Record<string, unknown> = {}
        for (const method of [
          "init",
          "put",
          "delete",
          "deleteAllByChatId",
        ]) {
          wrapped[method] = source[method]?.bind(source)
        }
        for (const method of readMethods) {
          const original = source[method]?.bind(source)
          if (!original) continue
          wrapped[method] = async (...args: unknown[]) => {
            const result = await original(...args)
            const held = readGate
            if (held) {
              heldReads += 1
              await held.promise
            }
            return result
          }
        }
        collection =
          wrapped as unknown as InlinePersistenceCollection<any>
        collections.set(kind, collection)
      }
      return collection as InlinePersistenceCollection<
        DbModels[K]
      >
    },
    async write(operations) {
      const held = writeGate
      if (held) await held.promise
      writes.push([...operations])
      await inner.write(operations)
    },
  }

  return {
    store,
    inner,
    writes,
    holdReads() {
      readGate = gate()
    },
    releaseReads() {
      const held = readGate
      readGate = null
      held?.release()
    },
    holdWrites() {
      writeGate = gate()
    },
    releaseWrites() {
      const held = writeGate
      writeGate = null
      held?.release()
    },
    /** Reads that ran against SQLite and are waiting to deliver. */
    get heldReads() {
      return heldReads
    },
  }
}
