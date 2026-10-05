import { AuthStore } from "@inline/auth/core"
import { Db, DbObjectKind, RealtimeClient, applyUpdates, messageKey } from "@inline/client/core"
import { MockTransport } from "@inline/client/realtime/transport/mock-transport"
import {
  GetChatsResult,
  Method,
  ServerProtocolMessage,
  Update,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import { NavigationRefresh } from "./navigation-refresh"

const peer = { type: { oneofKind: "chat" as const, chat: { chatId: 10n } } }
const staleSnapshot: RpcResult["result"] = {
  oneofKind: "getChats",
  getChats: GetChatsResult.create({
    chats: [{ id: 10n, title: "Stale title", lastMsgId: 12n, peerId: peer }],
    dialogs: [{ chatId: 10n, peer, readMaxId: 12n, unreadCount: 4 }],
    messages: [{ id: 12n, chatId: 10n, fromId: 7n, date: 100n, out: false, message: "Stale preview" }],
  }),
}

const owners: Array<{ db: Db; auth: AuthStore; realtime: RealtimeClient; refreshes: NavigationRefresh[] }> = []

const fixture = async () => {
  const auth = new AuthStore({ persistence: "memory" })
  await auth.ready
  await auth.login({ userId: userId(7), token: "test-session" })
  const db = new Db({ autoHydrate: false, persistence: false })
  await db.commit(() => {
    db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Current title", lastMsgId: messageId(12) })
    db.insert({ kind: DbObjectKind.Dialog, id: dialogId(10), chatId: chatId(10), peerThreadId: chatId(10), readMaxId: messageId(12), unreadCount: 4 })
    db.insert({ kind: DbObjectKind.Message, id: messageKey(chatId(10), messageId(12)), chatId: chatId(10), messageId: messageId(12), fromId: userId(7), date: 100, message: "Current preview" })
  })
  const transport = new MockTransport()
  const realtime = new RealtimeClient({ auth, db, transport, sync: false })
  const refreshes: NavigationRefresh[] = []
  owners.push({ db, auth, realtime, refreshes })
  await realtime.start()
  await transport.connect()
  await transport.emitMessage(ServerProtocolMessage.create({ body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
  await vi.waitFor(() => expect(realtime.connectionState).toBe("connected"))
  const begin = async (current = () => true) => {
    const refresh = new NavigationRefresh(current)
    refreshes.push(refresh)
    const pending = realtime.query(refresh)
    await vi.waitFor(() => expect(transport.sent.some((message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHATS)).toBe(true))
    const request = transport.sent.find((message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHATS)!
    const settle = async () => {
      await transport.emitMessage(ServerProtocolMessage.create({
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: request.id, result: staleSnapshot } },
      }))
      await pending
      refresh.dispose()
    }
    return { refresh, settle }
  }
  return { db, begin }
}

afterEach(async () => {
  for (const owner of owners.splice(0)) {
    await owner.realtime.stop()
    for (const refresh of owner.refreshes) refresh.dispose()
    await owner.db.closePersistence()
    owner.auth.dispose()
  }
})

describe("navigation snapshot admission", () => {
  it("does not resurrect a chat, dialog, or preview deleted after the RPC began", async () => {
    const { db, begin } = await fixture()
    const request = await begin()
    await db.commit(() => {
      applyUpdates(db, [Update.create({ update: { oneofKind: "deleteChat", deleteChat: { peerId: peer } } })])
    })
    await request.settle()
    expect(request.refresh.discarded).toBe(true)
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(10)))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(10)))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(chatId(10), messageId(12))))).toBeUndefined()
  })

  it("does not regress the unread count or read frontier committed during the RPC", async () => {
    const { db, begin } = await fixture()
    const request = await begin()
    await db.commit(() => {
      applyUpdates(db, [Update.create({ update: { oneofKind: "updateReadMaxId", updateReadMaxId: { peerId: peer, readMaxId: 20n, unreadCount: 0 } } })])
    })
    await request.settle()
    expect(request.refresh.discarded).toBe(true)
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(10)))).toMatchObject({ readMaxId: messageId(20), unreadCount: 0 })
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(10)))?.title).toBe("Current title")
  })

  it("admits a snapshot across local draft and sync bookkeeping changes", async () => {
    const { db, begin } = await fixture()
    const request = await begin()
    await db.commit(() => {
      db.insert({ kind: DbObjectKind.MessageDraft, id: `chat:${chatId(10)}`, peerKind: "chat", peerThreadId: chatId(10), text: "Local draft", revision: 1, updatedAt: 1 })
      db.insert({ kind: DbObjectKind.SyncGlobalState, id: 0, lastSyncDate: 100 })
    })
    await request.settle()
    expect(request.refresh.discarded).toBe(false)
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(10)))?.title).toBe("Stale title")
  })

  it("drops a snapshot from a retired owner generation even if no models changed", async () => {
    const { db, begin } = await fixture()
    let current = true
    const request = await begin(() => current)
    current = false
    await request.settle()
    expect(request.refresh.discarded).toBe(true)
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(10)))?.title).toBe("Current title")
  })
})
