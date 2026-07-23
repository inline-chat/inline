import { describe, expect, it, vi } from "vitest"
import { chatId, messageId, userId } from "@inline/ids"
import { Db } from "../index"
import { DbQueryPlanType } from "../types"
import {
  DbObjectKind,
  messageKey,
  type Message,
} from "../models"
import type { CollectionStorage } from "../storage"

const storedMessage = (text: string): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId(10), messageId(20)),
  messageId: messageId(20),
  chatId: chatId(10),
  fromId: userId(30),
  message: text,
})

describe("non-resident database objects", () => {
  it("reads an exact persisted message without widening the resident window", async () => {
    const object = storedMessage("Persisted reply")
    const storage: CollectionStorage<Message> = {
      init: vi.fn(async () => undefined),
      get: vi.fn(async (id) => (id === object.id ? object : undefined)),
      getMany: vi.fn(async (ids) =>
        ids.includes(object.id) ? [object] : [],
      ),
      getAll: vi.fn(async () => [object]),
      put: vi.fn(async () => undefined),
      delete: vi.fn(async () => undefined),
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: { [DbObjectKind.Message]: storage },
    })

    const loaded = await db.readStoredObjects(DbObjectKind.Message, [
      object.id,
    ])

    expect(loaded).toEqual([object])
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
      ),
    ).toEqual([])
    expect(storage.getAll).not.toHaveBeenCalled()
  })

  it("persists a side reference without making it resident", async () => {
    const put = vi.fn(async (_object: Message) => undefined)
    const storage: CollectionStorage<Message> = {
      init: vi.fn(async () => undefined),
      get: vi.fn(async () => undefined),
      getAll: vi.fn(async () => []),
      put,
      delete: vi.fn(async () => undefined),
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: { [DbObjectKind.Message]: storage },
    })
    const object = storedMessage("Remote reply")

    db.storeNonResidentObject(object)
    await db.flushPersistence()

    expect(put).toHaveBeenCalledWith(object)
    expect(db.get(db.ref(DbObjectKind.Message, object.id))).toBeUndefined()
  })
})
