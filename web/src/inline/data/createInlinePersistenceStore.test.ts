import {
  IDBFactory,
  IDBKeyRange,
} from "fake-indexeddb"
import {
  createIndexedDbPersistenceStore,
  DbObjectKind,
  INLINE_SQLITE_AUTHORITY_MARKER,
  InlinePersistenceReplicaPromotedError,
} from "@inline/client/core"
import { userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import { createInlinePersistenceStore } from "./createInlinePersistenceStore"

const accountId = userId(7)

const installIndexedDb = () => {
  vi.stubGlobal("indexedDB", new IDBFactory())
  vi.stubGlobal("IDBKeyRange", IDBKeyRange)
}

describe("createInlinePersistenceStore", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("keeps the current IndexedDB runtime usable before promotion", async () => {
    installIndexedDb()
    const store = createInlinePersistenceStore({ accountId })
    if (!store) throw new Error("IndexedDB unavailable")

    await store.open()
    await store.write([
      {
        type: "put",
        object: {
          kind: DbObjectKind.User,
          id: accountId,
          firstName: "Dena",
        },
      },
    ])
    await expect(
      store.collection(DbObjectKind.User).get(accountId),
    ).resolves.toMatchObject({ firstName: "Dena" })
    await store.close()
  })

  it("refuses the retained IndexedDB replica after SQLite promotion", async () => {
    installIndexedDb()
    const retained = createIndexedDbPersistenceStore(
      `user-${accountId}`,
    )
    if (!retained?.setReplicaMetadata) {
      throw new Error("IndexedDB metadata unavailable")
    }
    await retained.open()
    await retained.setReplicaMetadata(
      INLINE_SQLITE_AUTHORITY_MARKER,
      "complete",
    )
    await retained.close()

    const store = createInlinePersistenceStore({ accountId })
    if (!store) throw new Error("IndexedDB unavailable")
    await expect(store.open()).rejects.toBeInstanceOf(
      InlinePersistenceReplicaPromotedError,
    )
    await store.close()
  })
})
