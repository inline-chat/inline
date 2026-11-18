import type { Database } from "@sqlite.org/sqlite-wasm"
import type { DbModels, DbObjectKind } from "../database/models"
import type {
  InlinePersistenceCollection,
  InlinePersistenceOperation,
  InlinePersistenceStore,
} from "../database/persistence"
import {
  SQLitePersistenceStore,
  type InlineSqliteWriteCheckpoint,
} from "../database/sqlite/SQLitePersistenceStore"

/**
 * One in-memory SQLite database that outlives the "processes" using it, so a
 * test can kill a core at a commit checkpoint and start a new one on the same
 * replica.
 *
 * It uses the same mechanism as `createFaultableSqliteStore`: the store's
 * `onWriteCheckpoint` hook, which throws inside the write transaction so
 * SQLite rolls it back (or, after `COMMIT`, keeps it). What this adds is
 * knowing which write a checkpoint belongs to, and a process generation:
 * once a process has crashed, every later write from it fails before
 * `BEGIN`, as a dead process writes nothing.
 */

export type CheckpointPhase = InlineSqliteWriteCheckpoint["phase"]

export type CrashRule = {
  phase: CheckpointPhase
  /** Crash on the first write whose operations match. */
  when: (operations: readonly InlinePersistenceOperation[]) => boolean
}

export class ProcessCrashedError extends Error {
  constructor(readonly phase?: CheckpointPhase) {
    super(phase ? `Process crashed at ${phase}` : "Process is dead")
    this.name = "ProcessCrashedError"
  }
}

type Sqlite = Awaited<ReturnType<typeof import("@sqlite.org/sqlite-wasm")["default"]>>

let sqlitePromise: Promise<Sqlite> | undefined

const loadSqlite = () => {
  sqlitePromise ??= import("@sqlite.org/sqlite-wasm").then(
    ({ default: initialize }) => initialize(),
  )
  return sqlitePromise
}

export class CrashableDisk {
  private database: Promise<Database> | undefined
  private generation = 0
  private disposed = false

  /** Crashes that fired, in order. */
  readonly crashes: Array<{ generation: number; phase: CheckpointPhase }> = []

  /** A store for a new process. At most one process is alive at a time. */
  openStore(options: { crashRule?: CrashRule } = {}): CrashableStore {
    this.generation += 1
    return new CrashableStore(this, this.generation, options.crashRule)
  }

  /** Kill the live process: its later writes fail before touching disk. */
  crash() {
    this.generation += 1
  }

  isAlive(generation: number) {
    return generation === this.generation && !this.disposed
  }

  recordCrash(generation: number, phase: CheckpointPhase) {
    this.crashes.push({ generation, phase })
    if (this.generation === generation) this.generation += 1
  }

  sharedDatabase(): Promise<Database> {
    this.database ??= loadSqlite().then(
      (sqlite3) => new sqlite3.oo1.DB(":memory:", "c"),
    )
    return this.database
  }

  async dispose() {
    this.disposed = true
    const database = await this.database?.catch(() => undefined)
    database?.close()
    this.database = undefined
  }
}

/** A process's view of the disk. Closing it never closes the shared file. */
export class CrashableStore implements InlinePersistenceStore {
  private readonly inner: SQLitePersistenceStore
  private readonly inFlight: Array<readonly InlinePersistenceOperation[]> = []
  private crashRule: CrashRule | undefined

  constructor(
    private readonly disk: CrashableDisk,
    readonly generation: number,
    crashRule?: CrashRule,
  ) {
    this.crashRule = crashRule
    this.inner = new SQLitePersistenceStore(() => disk.sharedDatabase(), {
      onWriteCheckpoint: ({ phase }) => this.checkpoint(phase),
    })
  }

  get alive() {
    return this.disk.isAlive(this.generation)
  }

  /** Arm (or replace) the crash rule for this process. */
  crashWhen(rule: CrashRule | undefined) {
    this.crashRule = rule
  }

  open() {
    return this.inner.open()
  }

  collection<K extends DbObjectKind>(kind: K): InlinePersistenceCollection<DbModels[K]> {
    const collection = this.inner.collection(kind)
    const put = (object: DbModels[K]) => this.write([{ type: "put", object }])
    const remove = (id: DbModels[K]["id"]) => this.write([{ type: "delete", kind, id }])
    return new Proxy(collection, {
      get: (target, property, receiver) => {
        if (property === "put") return put
        if (property === "delete") return remove
        const value: unknown = Reflect.get(target, property, receiver)
        return typeof value === "function" ? value.bind(target) : value
      },
    })
  }

  write(operations: readonly InlinePersistenceOperation[]): Promise<void> {
    if (!this.alive) return Promise.reject(new ProcessCrashedError())
    if (operations.length === 0) return Promise.resolve()
    this.inFlight.push(operations)
    return this.inner.write(operations).finally(() => {
      const index = this.inFlight.indexOf(operations)
      if (index >= 0) this.inFlight.splice(index, 1)
    })
  }

  getReplicaMetadata(key: string) {
    return this.inner.getReplicaMetadata(key)
  }

  setReplicaMetadata(key: string, value: string) {
    return this.inner.setReplicaMetadata(key, value)
  }

  /** Releases nothing: the disk owns the file. */
  async close() {}

  private checkpoint(phase: CheckpointPhase) {
    if (!this.alive) throw new ProcessCrashedError(phase)
    const operations = this.inFlight[0]
    const rule = this.crashRule
    if (!rule || !operations || rule.phase !== phase || !rule.when(operations)) return
    this.crashRule = undefined
    this.disk.recordCrash(this.generation, phase)
    throw new ProcessCrashedError(phase)
  }
}
