import { Db, DbObjectKind, messageKey } from "@inline/client"
import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"

const openLegacyDatabase = async (name: string) => {
  const database = await new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(name, 2)
    request.onupgradeneeded = () => {
      const store = request.result.createObjectStore("objects", {
        keyPath: ["kind", "id"],
      })
      store.createIndex("kind", "kind", { unique: false })
      store.createIndex("message-chat-id", ["kind", "chatId", "id"], {
        unique: false,
      })
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })

  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction("objects", "readwrite")
    transaction.objectStore("objects").put({
      kind: DbObjectKind.Message,
      id: 7,
      chatId: 10,
      fromId: 1,
      message: "Persisted before composite keys",
    })
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(transaction.error)
    transaction.onabort = () => reject(transaction.error)
  })

  return database
}

describe("message cache key migration", () => {
  it("forward-migrates numeric message keys to chat-scoped keys", async () => {
    const namespace = `message-key-migration-${crypto.randomUUID()}`
    const databaseName = `inline-client-db:${namespace}`
    const legacyDatabase = await openLegacyDatabase(databaseName)
    legacyDatabase.close()

    const db = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })

    await expect(
      db.hydrateObjects(DbObjectKind.Message, [
        messageKey(chatId(10), messageId(7)),
      ]),
    ).resolves.toBe(1)

    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(7)),
        ),
      ),
    ).toMatchObject({
      id: "10:7",
      messageId: messageId(7),
      chatId: chatId(10),
      message: "Persisted before composite keys",
    })

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await expect(
      reloaded.hydrateMessageWindow(chatId(10), { limit: 50 }),
    ).resolves.toBe(1)
    expect(
      reloaded.get(
        reloaded.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(7)),
        ),
      )?.messageId,
    ).toBe(messageId(7))
  })

  it("surfaces a blocked upgrade instead of pretending the cache is empty", async () => {
    const namespace = `message-key-blocked-${crypto.randomUUID()}`
    const databaseName = `inline-client-db:${namespace}`
    const blockingDatabase = await openLegacyDatabase(databaseName)
    const db = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })

    await expect(
      db.hydrateObjects(DbObjectKind.Message, [
        messageKey(chatId(10), messageId(7)),
      ]),
    ).rejects.toThrow("IndexedDB upgrade blocked")

    blockingDatabase.close()
  })
})
