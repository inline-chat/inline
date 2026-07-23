import {
  IDBDatabase,
  IDBFactory,
  IDBKeyRange,
} from "fake-indexeddb"
import { afterEach, describe, expect, it, vi } from "vitest"
import { chatId, userId } from "@inline/ids"
import { Db } from "../index"
import {
  DbObjectKind,
  type User,
} from "../models"
import { createDatabaseStorage } from "../storage"

const installIndexedDb = () => {
  vi.stubGlobal("indexedDB", new IDBFactory())
  vi.stubGlobal("IDBKeyRange", IDBKeyRange)
}

describe("database atomic batches", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("writes all default-storage mutations through one readwrite transaction", async () => {
    installIndexedDb()
    const db = new Db({
      autoHydrate: false,
      storageNamespace: `atomic-${crypto.randomUUID()}`,
    })
    await db.hydrateKinds([
      DbObjectKind.User,
      DbObjectKind.Chat,
    ])

    const transactions = vi.spyOn(
      IDBDatabase.prototype,
      "transaction",
    )

    db.batch(() => {
      db.insert({
        kind: DbObjectKind.User,
        id: userId(7),
        firstName: "Dena",
      })
      db.insert({
        kind: DbObjectKind.Chat,
        id: chatId(10),
        title: "Foundation",
      })
    })
    await db.flushPersistence()

    expect(
      transactions.mock.calls.filter(
        ([, mode]) => mode === "readwrite",
      ),
    ).toHaveLength(1)
  })

  it("aborts the whole IndexedDB transaction when one row cannot be cloned", async () => {
    installIndexedDb()
    const storage = createDatabaseStorage(
      `atomic-abort-${crypto.randomUUID()}`,
    )
    if (!storage) throw new Error("IndexedDB storage unavailable")

    const valid: User = {
      kind: DbObjectKind.User,
      id: userId(7),
      firstName: "Dena",
    }
    const invalid = {
      kind: DbObjectKind.User,
      id: userId(8),
      firstName: "Invalid",
      uncloneable: () => undefined,
    } as unknown as User

    await expect(
      storage.write([
        { type: "put", object: valid },
        { type: "put", object: invalid },
      ]),
    ).rejects.toBeDefined()

    await storage.collection(DbObjectKind.User).init()
    await expect(
      storage.collection(DbObjectKind.User).get(valid.id),
    ).resolves.toBeUndefined()
  })

  it("keeps collection facades owned across close and reopen", async () => {
    installIndexedDb()
    const storage = createDatabaseStorage(
      `close-reopen-${crypto.randomUUID()}`,
    )
    if (!storage) throw new Error("IndexedDB storage unavailable")
    const users = storage.collection(DbObjectKind.User)
    const databaseCloses = vi.spyOn(IDBDatabase.prototype, "close")

    await storage.open()
    await users.put({
      kind: DbObjectKind.User,
      id: userId(7),
      firstName: "Dena",
    })
    await storage.close()
    const closesAfterFirstStop = databaseCloses.mock.calls.length

    await expect(users.get(userId(7))).resolves.toMatchObject({
      firstName: "Dena",
    })
    await storage.close()

    expect(databaseCloses.mock.calls.length).toBeGreaterThan(
      closesAfterFirstStop,
    )
  })

  it("persists replica authority metadata across close and reopen", async () => {
    installIndexedDb()
    const storage = createDatabaseStorage(
      `replica-metadata-${crypto.randomUUID()}`,
    )
    if (
      !storage?.getReplicaMetadata ||
      !storage.setReplicaMetadata
    ) {
      throw new Error("IndexedDB replica metadata unavailable")
    }

    await storage.open()
    await storage.setReplicaMetadata("authority", "sqlite")
    await storage.close()
    await expect(
      storage.getReplicaMetadata("authority"),
    ).resolves.toBe("sqlite")
    await storage.close()
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
