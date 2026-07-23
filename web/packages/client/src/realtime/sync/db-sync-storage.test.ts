import {
  IDBDatabase,
  IDBFactory,
  IDBKeyRange,
} from "fake-indexeddb"
import { afterEach, describe, expect, it, vi } from "vitest"
import { userId } from "@inline/ids"
import { Db } from "../../database"
import {
  DbObjectKind,
  type SyncBucketState as DbSyncBucketState,
} from "../../database/models"
import type { CollectionStorage } from "../../database/storage"
import { DbSyncStorage } from "./db-sync-storage"
import type { SyncBucketKey } from "./sync-types"

const userKey: SyncBucketKey = { kind: "user" }

const storage = (
  put: CollectionStorage<DbSyncBucketState>["put"],
): CollectionStorage<DbSyncBucketState> => ({
  init: async () => {},
  get: async () => undefined,
  getAll: async () => [],
  put,
  delete: async () => {},
})

describe("DbSyncStorage", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("does not expose an advanced cursor when its write fails", async () => {
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.SyncBucketState]: storage(async () => {
          throw new Error("disk full")
        }),
      },
    })
    const syncStorage = new DbSyncStorage(db)

    await expect(
      syncStorage.setBucketState(userKey, { seq: 42, date: 100 }),
    ).resolves.toBe(false)
    await expect(syncStorage.getBucketState(userKey)).resolves.toEqual({
      seq: 0,
      date: 0,
    })
  })

  it("rolls materialized memory back when cursor persistence fails", async () => {
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.User]: null,
        [DbObjectKind.SyncBucketState]: storage(async () => {
          throw new Error("disk full")
        }),
      },
    })
    const syncStorage = new DbSyncStorage(db)

    await expect(
      syncStorage.commitBucketState(
        userKey,
        { seq: 42, date: 100 },
        () => {
          db.insert({
            kind: DbObjectKind.User,
            id: userId(7),
            firstName: "Transient",
          })
        },
      ),
    ).resolves.toBe(false)

    expect(
      db.get(db.ref(DbObjectKind.User, userId(7))),
    ).toBeUndefined()
    expect(
      db.get(
        db.ref(DbObjectKind.SyncBucketState, "user"),
      ),
    ).toBeUndefined()
  })

  it("commits materialized objects and the bucket cursor in one IndexedDB transaction", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `sync-atomic-${crypto.randomUUID()}`
    const db = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    const syncStorage = new DbSyncStorage(db)
    await syncStorage.initialize()
    const transactions = vi.spyOn(
      IDBDatabase.prototype,
      "transaction",
    )

    await expect(
      syncStorage.commitBucketState(
        userKey,
        { seq: 42, date: 100 },
        () => {
          db.insert({
            kind: DbObjectKind.User,
            id: userId(7),
            firstName: "Dena",
          })
        },
      ),
    ).resolves.toBe(true)

    expect(
      transactions.mock.calls.filter(
        ([, mode]) => mode === "readwrite",
      ),
    ).toHaveLength(1)

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await reloaded.hydrateKinds([
      DbObjectKind.User,
      DbObjectKind.SyncBucketState,
    ])
    expect(
      reloaded.get(
        reloaded.ref(DbObjectKind.User, userId(7)),
      )?.firstName,
    ).toBe("Dena")
    expect(
      reloaded.get(
        reloaded.ref(DbObjectKind.SyncBucketState, "user"),
      ),
    ).toMatchObject({ seq: 42, date: 100 })
  })
})
