import "fake-indexeddb/auto"
import { Db, DbObjectKind, createIndexedDbPersistenceStore } from "@inline/client/core"
import { chatId, spaceId } from "@inline/ids"
import { GetChatResult, type RpcResult } from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { NavigationChat } from "./navigation-chat"

const id = chatId("9007199254741101")
const result: RpcResult["result"] = {
  oneofKind: "getChat",
  getChat: GetChatResult.create({
    chat: { id: BigInt(id), title: "Delayed private chat", date: 1n },
  }),
}
const fixture = () =>
  new Db({
    autoHydrate: false,
    persistenceStore: createIndexedDbPersistenceStore(`route-admission-${crypto.randomUUID()}`)!,
  })
const query = (current = () => true) =>
  new NavigationChat(
    { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(id) } } } },
    id,
    current
  )

describe("deep-link snapshot admission", () => {
  it("applies a current cache-miss response", async () => {
    const db = fixture()
    const transaction = query()
    transaction.beforeExecute(db)
    await db.commit(() => transaction.apply(result, db))
    transaction.dispose()
    expect(db.get(db.ref(DbObjectKind.Chat, id))?.title).toBe("Delayed private chat")
    await db.closePersistence()
  })

  it("rejects a response after committed deletion even when the chat was not cached", async () => {
    const db = fixture()
    const transaction = query()
    transaction.beforeExecute(db)
    await db.commit(() => db.delete(db.ref(DbObjectKind.Chat, id)))
    await db.commit(() => transaction.apply(result, db))
    transaction.dispose()
    expect(transaction.discarded).toBe(true)
    expect(db.get(db.ref(DbObjectKind.Chat, id))).toBeUndefined()
    await db.closePersistence()
  })

  it("rejects an old navigation or a delete/rejoin response without overwriting the new chat", async () => {
    const db = fixture()
    let current = true
    const cancelled = query(() => current)
    cancelled.beforeExecute(db)
    current = false
    await db.commit(() => cancelled.apply(result, db))
    cancelled.dispose()
    expect(db.get(db.ref(DbObjectKind.Chat, id))).toBeUndefined()
    const transaction = query()
    transaction.beforeExecute(db)
    await db.commit(() => db.delete(db.ref(DbObjectKind.Chat, id)))
    await db.commit(() => db.insert({ kind: DbObjectKind.Chat, id, title: "Rejoined chat" }))
    await db.commit(() => transaction.apply(result, db))
    transaction.dispose()
    expect(db.get(db.ref(DbObjectKind.Chat, id))?.title).toBe("Rejoined chat")
    await db.closePersistence()
  })

  it("rejects a cache-miss chat response after its Space was removed", async () => {
    const db = fixture()
    const owner = spaceId("9007199254741201")
    const transaction = query()
    transaction.beforeExecute(db)
    await db.commit(() => db.delete(db.ref(DbObjectKind.Space, owner)))
    const delayed = {
      oneofKind: "getChat" as const,
      getChat: GetChatResult.create({
        chat: { id: BigInt(id), spaceId: BigInt(owner), title: "Removed Space chat" },
      }),
    }
    await db.commit(() => transaction.apply(delayed, db))
    transaction.dispose()
    expect(transaction.discarded).toBe(true)
    expect(db.get(db.ref(DbObjectKind.Chat, id))).toBeUndefined()
    await db.closePersistence()
  })

  it("keeps a new Space grant and rejects an older in-flight chat snapshot", async () => {
    const db = fixture()
    const owner = spaceId("9007199254741201")
    const transaction = query()
    transaction.beforeExecute(db)
    await db.commit(() => db.delete(db.ref(DbObjectKind.Space, owner)))
    await db.commit(() =>
      db.insert({
        kind: DbObjectKind.Space,
        id: owner,
        name: "Rejoined Space",
        creator: false,
        date: 1,
      }),
    )
    const delayed = {
      oneofKind: "getChat" as const,
      getChat: GetChatResult.create({
        chat: { id: BigInt(id), spaceId: BigInt(owner), title: "Old grant chat" },
      }),
    }
    await db.commit(() => transaction.apply(delayed, db))
    transaction.dispose()
    expect(transaction.discarded).toBe(true)
    expect(db.get(db.ref(DbObjectKind.Space, owner))?.name).toBe("Rejoined Space")
    expect(db.get(db.ref(DbObjectKind.Chat, id))).toBeUndefined()
    await db.closePersistence()
  })

  it("allows a response when an unrelated Space changed", async () => {
    const db = fixture()
    const owner = spaceId("9007199254741201")
    const transaction = query()
    transaction.beforeExecute(db)
    await db.commit(() => db.delete(db.ref(DbObjectKind.Space, spaceId("9007199254741202"))))
    const current = {
      oneofKind: "getChat" as const,
      getChat: GetChatResult.create({
        chat: { id: BigInt(id), spaceId: BigInt(owner), title: "Current Space chat" },
      }),
    }
    await db.commit(() => transaction.apply(current, db))
    transaction.dispose()
    expect(transaction.discarded).toBe(false)
    expect(db.get(db.ref(DbObjectKind.Chat, id))?.title).toBe("Current Space chat")
    await db.closePersistence()
  })

  it("rejects a legacy child response with unknown inherited Space after a Space change", async () => {
    const db = fixture()
    const transaction = query()
    transaction.beforeExecute(db)
    await db.commit(() => db.delete(db.ref(DbObjectKind.Space, spaceId("9007199254741201"))))
    const inherited = {
      oneofKind: "getChat" as const,
      getChat: GetChatResult.create({
        chat: { id: BigInt(id), parentChatId: 9007199254741102n, title: "Old inherited chat" },
      }),
    }
    await db.commit(() => transaction.apply(inherited, db))
    transaction.dispose()
    expect(transaction.discarded).toBe(true)
    expect(db.get(db.ref(DbObjectKind.Chat, id))).toBeUndefined()
    await db.closePersistence()
  })
})
