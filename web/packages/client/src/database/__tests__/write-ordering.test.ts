import { userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { DatabaseCommitError, Db, type DbResidentChangeBatch } from "../index"
import { DbObjectKind, type User } from "../models"
import { createFaultableSqliteStore } from "../../testing/faultable-sqlite-store"
import { createGatedStore } from "./gated-store"

const user = (id: number, firstName: string): User => ({
  kind: DbObjectKind.User,
  id: userId(id),
  firstName,
})

const putIds = (operations: { type: string; object?: { id: unknown } }[]) =>
  operations.map((operation) => String(operation.object?.id))

describe("invariant 6: one writer per account, one ordered write queue", () => {
  it("invariant 6: bare writes, batches and commits reach storage in acceptance order", async () => {
    const gated = createGatedStore()
    const db = new Db({ autoHydrate: false, persistenceStore: gated.store })
    await db.openPersistence()

    gated.holdWrites()
    db.insert(user(1, "bare"))
    db.batch(() => {
      db.insert(user(2, "batch"))
      db.insert(user(3, "batch"))
    })
    const committed = db.commit(() => db.insert(user(4, "commit")))
    db.update(user(5, "bare after commit was requested"))

    // Memory holds every accepted write at once.
    expect(db.get(db.ref(DbObjectKind.User, userId(5)))?.firstName).toBe(
      "bare after commit was requested",
    )
    gated.releaseWrites()
    await committed
    await db.flushPersistence()

    expect(gated.writes.map(putIds)).toEqual([
      ["1"],
      ["2", "3"],
      ["5"],
      ["4"],
    ])
  })

  it("invariant 6: a failed batch write rolls memory back like a failed commit", async () => {
    const faults = createFaultableSqliteStore()
    const db = new Db({ autoHydrate: false, persistenceStore: faults.store })
    await db.openPersistence()
    const observer = vi.fn()
    db.subscribeToObject(db.ref(DbObjectKind.User, userId(1)), observer)

    faults.failNextWrite(new Error("disk full"))
    db.batch(() => db.insert(user(1, "transient")))
    expect(db.get(db.ref(DbObjectKind.User, userId(1)))?.firstName).toBe(
      "transient",
    )

    await expect(db.flushPersistence()).rejects.toThrow(
      "Inline database persistence failed",
    )
    expect(db.get(db.ref(DbObjectKind.User, userId(1)))).toBeUndefined()
    expect(observer).not.toHaveBeenCalled()

    // The queue keeps working after the failure.
    db.insert(user(1, "durable"))
    await db.flushPersistence()
    const reloaded = new Db({ autoHydrate: false, persistenceStore: faults.store })
    await reloaded.hydrateKinds([DbObjectKind.User])
    expect(
      reloaded.get(reloaded.ref(DbObjectKind.User, userId(1)))?.firstName,
    ).toBe("durable")
  })

  it("invariant 6: writes queued behind a failed write are undone too, so memory equals disk", async () => {
    const faults = createFaultableSqliteStore()
    const db = new Db({ autoHydrate: false, persistenceStore: faults.store })
    await db.openPersistence()
    db.insert(user(1, "committed"))
    await db.flushPersistence()

    faults.failNextWrite(new Error("disk full"))
    db.update(user(1, "fails"))
    db.update({ ...user(1, "built on the failure"), lastName: "later" })
    db.insert(user(2, "queued behind"))
    // A commit waits for every earlier write to settle, then runs its
    // recipe on committed state.
    const later = db.commit(() => {
      const current = db.get(db.ref(DbObjectKind.User, userId(1)))
      db.insert(user(3, `saw ${current?.firstName}`))
    })

    await later
    await expect(db.flushPersistence()).rejects.toThrow()
    expect(db.get(db.ref(DbObjectKind.User, userId(1)))).toEqual(
      user(1, "committed"),
    )
    expect(db.get(db.ref(DbObjectKind.User, userId(2)))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.User, userId(3)))?.firstName).toBe(
      "saw committed",
    )
  })
})

describe("invariant 1: nothing is published before the write that contains it commits", () => {
  it("invariant 1: observers and the resident stream hear of a write only after its commit", async () => {
    const gated = createGatedStore()
    const db = new Db({ autoHydrate: false, persistenceStore: gated.store })
    await db.openPersistence()
    const batches: DbResidentChangeBatch[] = []
    db.subscribeToResidentChanges((batch) => batches.push(batch))
    const observer = vi.fn()
    db.subscribeToObject(db.ref(DbObjectKind.User, userId(1)), observer)

    gated.holdWrites()
    db.insert(user(1, "first"))
    db.update(user(1, "second"))
    await Promise.resolve()
    expect(batches).toHaveLength(0)
    expect(observer).not.toHaveBeenCalled()

    gated.releaseWrites()
    await db.flushPersistence()

    // Each committed write is published with the value it committed.
    expect(
      batches.map((batch) => [
        batch.revision,
        (batch.changes[0]?.object as User | undefined)?.firstName,
      ]),
    ).toEqual([
      [1, "first"],
      [2, "second"],
    ])
    expect(observer).toHaveBeenCalledTimes(2)
  })

  it("invariant 1: the resident snapshot leaves out accepted writes that have not committed", async () => {
    const gated = createGatedStore()
    const db = new Db({ autoHydrate: false, persistenceStore: gated.store })
    await db.openPersistence()
    db.subscribeToResidentChanges(() => {})
    db.insert(user(1, "committed"))
    await db.flushPersistence()

    gated.holdWrites()
    db.update(user(1, "pending"))
    db.insert(user(2, "pending"))
    const snapshot = db.residentSnapshot([DbObjectKind.User])
    expect(snapshot.revision).toBe(1)
    expect(
      snapshot.objects.map((object) => (object as User).firstName),
    ).toEqual(["committed"])

    gated.releaseWrites()
    await db.flushPersistence()
    expect(db.residentSnapshot([DbObjectKind.User]).revision).toBe(3)
  })

  it("invariant 1: a sync page and its cursor commit in one transaction before anything is published", async () => {
    const faults = createFaultableSqliteStore()
    const db = new Db({ autoHydrate: false, persistenceStore: faults.store })
    await db.openPersistence()
    const listener = vi.fn()
    db.subscribeToResidentChanges(listener)

    faults.failNextWrite(new Error("disk full"))
    await expect(
      db.commit(() => {
        db.batch(() => db.insert(user(1, "from page")))
        db.replace({
          kind: DbObjectKind.SyncBucketState,
          id: "user",
          seq: 10,
          date: 1_000,
        })
      }),
    ).rejects.toBeInstanceOf(DatabaseCommitError)
    expect(listener).not.toHaveBeenCalled()
    expect(db.get(db.ref(DbObjectKind.User, userId(1)))).toBeUndefined()
    expect(
      db.get(db.ref(DbObjectKind.SyncBucketState, "user")),
    ).toBeUndefined()
  })
})
