import { userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import {
  Db,
  type DbResidentChangeBatch,
} from "../index"
import { DbObjectKind } from "../models"

const memoryDb = () =>
  new Db({
    autoHydrate: false,
    storageByKind: {
      [DbObjectKind.User]: null,
    },
  })

describe("Db resident change stream", () => {
  it("publishes one ordered batch for an atomic recipe", () => {
    const db = memoryDb()
    const batches: DbResidentChangeBatch[] = []
    db.subscribeToResidentChanges((batch) => {
      batches.push(batch)
    })

    db.batch(() => {
      db.insert({
        kind: DbObjectKind.User,
        id: userId(7),
        firstName: "Mo",
      })
      db.replace({
        kind: DbObjectKind.User,
        id: userId(8),
        firstName: "Dena",
      })
    })

    expect(batches).toHaveLength(1)
    expect(batches[0]?.revision).toBe(1)
    expect(
      batches[0]?.changes.map((change) => change.id),
    ).toEqual([userId(7), userId(8)])
    expect(db.residentSnapshot().revision).toBe(1)
  })

  it("publishes a tombstone for deletion", () => {
    const db = memoryDb()
    db.insert({
      kind: DbObjectKind.User,
      id: userId(7),
      firstName: "Mo",
    })
    const listener = vi.fn()
    db.subscribeToResidentChanges(listener)

    db.delete(db.ref(DbObjectKind.User, userId(7)))

    expect(listener).toHaveBeenCalledWith({
      revision: 1,
      changes: [
        {
          kind: DbObjectKind.User,
          id: userId(7),
        },
      ],
    })
  })

  it("does not publish an aborted recipe", () => {
    const db = memoryDb()
    const listener = vi.fn()
    db.subscribeToResidentChanges(listener)

    expect(() => {
      db.batch(() => {
        db.insert({
          kind: DbObjectKind.User,
          id: userId(7),
        })
        throw new Error("abort")
      })
    }).toThrow("abort")

    expect(listener).not.toHaveBeenCalled()
    expect(db.residentSnapshot().objects).toEqual([])
  })
})
