import { afterEach, describe, expect, it, vi } from "vitest"
import { userId } from "@inline/ids"
import { Db } from "../index"
import { DbObjectKind } from "../models"

describe("database atomic batches", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("rolls memory back and suppresses observers when a recipe throws", () => {
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.User]: null,
      },
    })
    const ref = db.ref(DbObjectKind.User, userId(7))
    const observer = vi.fn()
    db.subscribeToObject(ref, observer)
    db.insert({
      kind: DbObjectKind.User,
      id: userId(7),
      firstName: "Before",
    })
    observer.mockClear()

    expect(() =>
      db.batch(() => {
        db.replace({
          kind: DbObjectKind.User,
          id: userId(7),
          firstName: "After",
        })
        db.insert({
          kind: DbObjectKind.User,
          id: userId(8),
          firstName: "Transient",
        })
        throw new Error("recipe failed")
      }),
    ).toThrow("recipe failed")

    expect(db.get(ref)?.firstName).toBe("Before")
    expect(
      db.get(db.ref(DbObjectKind.User, userId(8))),
    ).toBeUndefined()
    expect(observer).not.toHaveBeenCalled()
  })

  it("rolls memory back when an asynchronous commit is rejected", async () => {
    const put = vi.fn(async () => {
      throw new Error("disk full")
    })
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.User]: {
          init: async () => {},
          get: async () => undefined,
          getAll: async () => [],
          put,
          delete: async () => {},
        },
      },
    })
    const ref = db.ref(DbObjectKind.User, userId(7))
    const observer = vi.fn()
    db.subscribeToObject(ref, observer)

    await expect(
      db.commit(() => {
        db.insert({
          kind: DbObjectKind.User,
          id: userId(7),
          firstName: "Transient",
        })
      }),
    ).rejects.toThrow("disk full")

    expect(db.get(ref)).toBeUndefined()
    expect(observer).not.toHaveBeenCalled()
  })
})
