import type { Database } from "@sqlite.org/sqlite-wasm"
import type { DbModels, DbObjectKind } from "../database/models"
import { isMessageSearchStore } from "../search/engine"
import type {
  InlinePersistenceOperation,
  InlinePersistenceScanPage,
  InlinePersistenceStore,
} from "../database/persistence"

/**
 * Wraps the account's persistence store to watch write outcomes, so the host
 * can report `storage: "full"` after a quota failure and clear it after the
 * next write that succeeds.
 */
export class TrackedStore implements InlinePersistenceStore {
  scan?: <K extends DbObjectKind>(
    kind: K,
    afterId: DbModels[K]["id"] | undefined,
    limit: number,
  ) => Promise<InlinePersistenceScanPage<K>>
  getReplicaMetadata?: (key: string) => Promise<string | undefined>
  setReplicaMetadata?: (key: string, value: string) => Promise<void>
  /** Local search's access to the replica (`search/engine.ts` `MessageSearchStore`), when the store has it. */
  readSearchIndex?: <T>(read: (db: Database) => T) => Promise<T>
  writeSearchIndex?: <T>(write: (db: Database) => T) => Promise<T>

  constructor(
    readonly inner: InlinePersistenceStore,
    private readonly onWriteSettled: (error?: unknown) => void = () => undefined,
  ) {
    if (inner.scan) this.scan = inner.scan.bind(inner)
    if (inner.getReplicaMetadata) this.getReplicaMetadata = inner.getReplicaMetadata.bind(inner)
    if (inner.setReplicaMetadata) this.setReplicaMetadata = inner.setReplicaMetadata.bind(inner)
    if (isMessageSearchStore(inner)) {
      this.readSearchIndex = inner.readSearchIndex.bind(inner)
      this.writeSearchIndex = inner.writeSearchIndex.bind(inner)
    }
  }

  open() {
    return this.inner.open()
  }

  collection<K extends DbObjectKind>(kind: K) {
    return this.inner.collection(kind)
  }

  write(operations: readonly InlinePersistenceOperation[]): Promise<void> {
    const write = this.inner.write(operations)
    write.then(
      () => this.onWriteSettled(),
      (error: unknown) => this.onWriteSettled(error ?? new Error("write failed")),
    )
    return write
  }

  close() {
    return this.inner.close()
  }
}
