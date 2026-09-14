import { describe, expect, it, vi } from "vitest"
import { chatId, messageId, userId } from "@inline/ids"
import { Db } from "../index"
import { DbObjectKind, messageKey, type Message, type User } from "../models"
import type { CollectionStorage } from "../storage"

const userStorage = (
  put: CollectionStorage<User>["put"],
): CollectionStorage<User> => ({
  init: async () => {},
  get: async () => undefined,
  getAll: async () => [],
  put,
  delete: async () => {},
})

describe("database persistence barriers", () => {
  it("waits for pending writes before resolving", async () => {
    let finishPut: (() => void) | undefined
    const put = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          finishPut = resolve
        }),
    )
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.User]: userStorage(put),
      },
    })

    db.insert({
      kind: DbObjectKind.User,
      id: userId(1),
      firstName: "Dena",
    })
    let flushed = false
    const barrier = db.flushPersistence().then(() => {
      flushed = true
    })

    await Promise.resolve()
    expect(flushed).toBe(false)
    finishPut?.()
    await barrier
    expect(flushed).toBe(true)
  })

  it("rejects when a scheduled write fails", async () => {
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.User]: userStorage(async () => {
          throw new Error("disk full")
        }),
      },
    })

    db.insert({
      kind: DbObjectKind.User,
      id: userId(1),
      firstName: "Dena",
    })

    await expect(db.flushPersistence()).rejects.toThrow(
      "Inline database persistence failed",
    )
  })

  it("clears unloaded and hydrated chat history through the storage index", async () => {
    const deleteAllByChatId = vi.fn(async () => {})
    const storage: CollectionStorage<Message> = {
      init: async () => {},
      get: async () => undefined,
      getAll: async () => [],
      put: async () => {},
      delete: async () => {},
      deleteAllByChatId,
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.Message]: storage,
      },
    })
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(1)),
      messageId: messageId(1),
      chatId: chatId(10),
      fromId: userId(7),
      message: "remove",
    })
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(chatId(20), messageId(1)),
      messageId: messageId(1),
      chatId: chatId(20),
      fromId: userId(7),
      message: "keep",
    })
    await db.flushPersistence()

    db.clearMessagesForChat(chatId(10))
    await db.flushPersistence()

    expect(deleteAllByChatId).toHaveBeenCalledWith(chatId(10))
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(1)),
        ),
      ),
    ).toBeUndefined()
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(20), messageId(1)),
        ),
      )?.message,
    ).toBe(
      "keep",
    )
  })
})
