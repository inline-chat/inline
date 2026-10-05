/**
 * Local synthetic protocol fixture for browser acceptance. Never import this
 * file from an application entry point or use it as a production server.
 * Run: bun --no-env-file web/tests/protocol-server.ts
 * Every identity, auth response, and message below is synthetic test data.
 */
import * as P from "../../packages/protocol/src/core"

export const TEST_EMAIL = "web-test@example.test"
export const TEST_CODE = "123456"
const TEST_TOKEN = "synthetic-inline-web-fixture-token"
export const TEST_USER_ID = 9007199254741001n
export const TEST_DESIGN_CHAT_ID = 9007199254741101n
export const TEST_ACCESS_SPACE_ID = 9007199254741400n
export const TEST_ACCESS_CHAT_ID = 9007199254741401n
export const TEST_ACCESS_CHILD_ID = 9007199254741402n
const AVA_ID = 9007199254741002n
const SAM_ID = 9007199254741003n
const SPACE_ID = 9007199254741201n
const now = () => BigInt(Math.floor(Date.now() / 1000))
const peer = (chatId: bigint) => P.Peer.create({ type: { oneofKind: "chat", chat: { chatId } } })
const userPeer = (userId: bigint) => P.Peer.create({ type: { oneofKind: "user", user: { userId } } })

export function createProtocolFixture() {
  const users = [
    P.User.create({ id: TEST_USER_ID, firstName: "Web", lastName: "Tester", email: TEST_EMAIL }),
    P.User.create({ id: AVA_ID, firstName: "Ava", lastName: "Chen", username: "ava" }),
    P.User.create({ id: SAM_ID, firstName: "Sam", lastName: "Reed", username: "sam" }),
  ]
  const spaces = [P.Space.create({ id: SPACE_ID, name: "Inline test workspace", creator: true, date: now() - 86400n, seq: 0 })]
  const chats = new Map<bigint, P.Chat>()
  const dialogs = new Map<bigint, P.Dialog>()
  const histories = new Map<bigint, P.Message[]>()
  const updateLogs = new Map<string, P.Update[]>()
  const sends = new Map<bigint, { chatId: bigint; result: P.SendMessageResult }>()
  const methods: Record<string, number> = {}
  const replays: Record<string, number> = {}
  let nextChatId = 9007199254741300n
  let nextMessageId = 9007199254750000n
  let sendAttempts = 0
  let injectedMessages = 0
  let broadcast: (updates: P.Update[]) => void = () => {}
  let accessMemberId: bigint | undefined
  let previousAccessMemberId: bigint | undefined
  let nextAccessMemberId = 9007199254741500n

  // The opt-in public Space still requires current membership, as the real
  // server does. This is one synthetic member, not a second client ACL model.
  function owningSpace(chat: P.Chat): bigint | undefined {
    return chat.spaceId ?? (chat.parentChatId == null ? undefined : owningSpace(chats.get(chat.parentChatId)!))
  }
  const accessible = (chat: P.Chat) => owningSpace(chat) !== TEST_ACCESS_SPACE_ID || accessMemberId != null
  const visibleChats = () => [...chats.values()].filter(accessible)
  const visibleSpaces = () => spaces.filter((space) => space.id !== TEST_ACCESS_SPACE_ID || accessMemberId != null)

  function requireSpaceAccess(id: bigint) {
    if (id === TEST_ACCESS_SPACE_ID && accessMemberId == null) {
      throw Object.assign(new Error("Synthetic Space membership is no longer current"), { errorCode: P.RpcError_Code.SPACE_ID_INVALID })
    }
  }

  function chatFor(input?: P.InputPeer): P.Chat {
    let chat: P.Chat | undefined
    if (input?.type.oneofKind === "chat") chat = chats.get(input.type.chat.chatId)
    if (input?.type.oneofKind === "user") {
      const userId = input.type.user.userId
      chat = [...chats.values()].find((item) => item.peerId?.type.oneofKind === "user" && item.peerId.type.user.userId === userId)
    }
    if (input?.type.oneofKind === "self") chat = chats.get(9007199254741105n)
    if (!chat) throw new Error("Unknown synthetic peer")
    const space = owningSpace(chat)
    if (space != null) requireSpaceAccess(space)
    return chat
  }

  function appendUpdate(bucket: string, update: P.Update["update"]): P.Update {
    const log = updateLogs.get(bucket) ?? []
    const entry = P.Update.create({ seq: log.length + 1, date: now(), update })
    log.push(entry)
    updateLogs.set(bucket, log)
    return entry
  }

  function appendMessage(chat: P.Chat, text: string, fromId: bigint, replyToMsgId?: bigint): P.Message {
    const message = P.Message.create({
      id: ++nextMessageId, chatId: chat.id, peerId: chat.peerId,
      fromId, out: fromId === TEST_USER_ID, date: now(), message: text, replyToMsgId,
      // Current encodeMessage publishes revision zero for a new canonical row.
      rev: 0n,
    })
    const history = histories.get(chat.id) ?? []
    history.push(message)
    histories.set(chat.id, history)
    chat.lastMsgId = message.id
    return message
  }

  const subjects = [
    "The conversation should stay in place while older messages load.",
    "I like the quieter sidebar. The active thread is easy to find.",
    "Let's keep the composer close to the conversation and preserve drafts when switching threads.",
    "The latest review is ready. We can compare it with yesterday's direction.",
    "Small detail: multiline messages should wrap naturally.\nThis second line helps us check layout changes.",
    "Keyboard flow matters: Enter to send, Shift+Enter for a new line, Escape to close a reply.",
    "A cached conversation should open immediately, even when the connection is recovering.",
    "We have enough material for another pass on typography, spacing, and thread navigation.",
  ]
  const definitions = [
    { id: TEST_DESIGN_CHAT_ID, title: "Design thread", emoji: "✦", spaceId: SPACE_ID, count: 160 },
    { id: 9007199254741102n, title: "Product notes", emoji: "◈", spaceId: SPACE_ID, count: 12 },
    { id: 9007199254741103n, title: "Ava Chen", userId: AVA_ID, count: 10 },
    { id: 9007199254741104n, title: "Sam Reed", userId: SAM_ID, count: 8 },
    { id: 9007199254741105n, title: "Saved messages", userId: TEST_USER_ID, count: 3 },
  ]
  for (const definition of definitions) {
    const chatPeer = definition.userId ? userPeer(definition.userId) : peer(definition.id)
    const chat = P.Chat.create({
      id: definition.id, title: definition.title, emoji: definition.emoji, spaceId: definition.spaceId,
      peerId: chatPeer, isPublic: definition.spaceId != null, createdBy: TEST_USER_ID,
      date: now() - 86400n, permissions: { canUpdateInfo: true }, seq: 0,
    })
    chats.set(chat.id, chat)
    for (let index = 0; index < definition.count; index++) {
      const message = appendMessage(chat, `${subjects[index % subjects.length]} (${index + 1})`, index % 3 === 0 ? TEST_USER_ID : index % 2 === 0 ? AVA_ID : SAM_ID)
      message.date = now() - BigInt((definition.count - index) * 90)
    }
    const history = histories.get(chat.id)!
    dialogs.set(chat.id, P.Dialog.create({
      peer: chatPeer, chatId: chat.id, spaceId: chat.spaceId, open: true,
      readMaxId: history.at(-4)?.id ?? 0n, unreadCount: 3,
      pinned: chat.id === TEST_DESIGN_CHAT_ID, order: String(definitions.indexOf(definition)),
    }))
  }

  function historyPage(input: P.GetChatHistoryInput): P.Message[] {
    const rows = histories.get(chatFor(input.peerId).id) ?? []
    const limit = Math.min(100, Math.max(1, input.limit ?? 60))
    let result: P.Message[]
    switch (input.mode) {
      case P.GetChatHistoryMode.HISTORY_MODE_OLDER:
        result = rows.filter((row) => row.id < (input.beforeId ?? input.offsetId ?? 0n)).slice(-limit)
        break
      case P.GetChatHistoryMode.HISTORY_MODE_NEWER:
        result = rows.filter((row) => row.id > (input.afterId ?? 0n)).slice(0, limit)
        break
      case P.GetChatHistoryMode.HISTORY_MODE_AROUND: {
        const anchor = input.anchorId ?? 0n
        result = [
          ...rows.filter((row) => row.id < anchor).slice(-Math.min(100, Math.max(0, input.beforeLimit ?? 30))),
          ...(input.includeAnchor === false ? [] : rows.filter((row) => row.id === anchor)),
          ...rows.filter((row) => row.id > anchor).slice(0, Math.min(100, Math.max(0, input.afterLimit ?? 30))),
        ]
        break
      }
      default:
        result = (input.offsetId ? rows.filter((row) => row.id < input.offsetId!) : rows).slice(-limit)
    }
    return result.slice().reverse()
  }

  function replaySidecars(updates: P.Update[], bucket: string): P.UpdateSidecars | undefined {
    // Production EMPTY replay carries no repair catalog. Nonempty pages only
    // enrich chats/users referenced by this page, under current membership.
    if (updates.length === 0) return undefined
    const chatIds = new Set<bigint>()
    const userIds = new Set<bigint>()
    if (bucket.startsWith("chat:")) chatIds.add(BigInt(bucket.slice(5)))
    for (const entry of updates) {
      const update = entry.update
      if (update.oneofKind === "newMessage" && update.newMessage.message) {
        chatIds.add(update.newMessage.message.chatId)
        userIds.add(update.newMessage.message.fromId)
      } else if (update.oneofKind === "chatOpen" && update.chatOpen.chat) {
        chatIds.add(update.chatOpen.chat.id)
      } else if (update.oneofKind === "joinSpace") userIds.add(TEST_USER_ID)
      else if (update.oneofKind === "updateReadMaxId") {
        const target = update.updateReadMaxId.peerId?.type
        if (target?.oneofKind === "chat") chatIds.add(target.chat.chatId)
        if (target?.oneofKind === "user") {
          userIds.add(target.user.userId)
          for (const chat of chats.values()) if (chat.peerId?.type.oneofKind === "user" && chat.peerId.type.user.userId === target.user.userId) chatIds.add(chat.id)
        }
      }
    }
    const admitted = visibleChats().filter((chat) => chatIds.has(chat.id))
    const spaceIds = new Set(admitted.flatMap((chat) => {
      const space = owningSpace(chat)
      return space == null ? [] : [space]
    }))
    const admittedUsers = users.filter((user) => userIds.has(user.id))
    if (admitted.length === 0 && admittedUsers.length === 0) return undefined
    return P.UpdateSidecars.create({
      users: admittedUsers, chats: admitted,
      dialogs: admitted.flatMap((chat) => dialogs.get(chat.id) ?? []),
      spaces: visibleSpaces().filter((space) => spaceIds.has(space.id)),
    })
  }

  function execute(call: P.RpcCall): P.RpcResult["result"] {
    const input = call.input
    const method = input.oneofKind ?? String(call.method)
    methods[method] = (methods[method] ?? 0) + 1
    switch (input.oneofKind) {
      case "getMe":
        return { oneofKind: "getMe", getMe: P.GetMeResult.create({ user: users[0] }) }
      case "getChats":
        return { oneofKind: "getChats", getChats: P.GetChatsResult.create({
          users, spaces: visibleSpaces(), chats: visibleChats(),
          dialogs: visibleChats().flatMap((chat) => dialogs.get(chat.id) ?? []),
          messages: visibleChats().flatMap((chat) => histories.get(chat.id)?.slice(-1) ?? []),
        }) }
      case "getChat": {
        const chat = chatFor(input.getChat.peerId)
        return { oneofKind: "getChat", getChat: P.GetChatResult.create({
          chat, dialog: dialogs.get(chat.id),
          messages: input.getChat.includeRecentMessages ? histories.get(chat.id)?.slice(-30) : [],
          user: chat.peerId?.type.oneofKind === "user" ? users.find((user) => chat.peerId?.type.oneofKind === "user" && user.id === chat.peerId.type.user.userId) : undefined,
        }) }
      }
      case "getChatHistory":
        return { oneofKind: "getChatHistory", getChatHistory: P.GetChatHistoryResult.create({ messages: historyPage(input.getChatHistory) }) }
      case "sendMessage": {
        sendAttempts++
        const payload = input.sendMessage
        const chat = chatFor(payload.peerId)
        if (payload.randomId == null) throw new Error("Synthetic send requires a stable randomId")
        const prior = sends.get(payload.randomId)
        if (prior) {
          if (prior.chatId !== chat.id) throw new Error("randomId belongs to a different synthetic chat")
          return { oneofKind: "sendMessage", sendMessage: prior.result }
        }
        const message = appendMessage(chat, payload.message ?? "", TEST_USER_ID, payload.replyToMsgId)
        message.entities = payload.entities
        const updates = [
          appendUpdate("user", { oneofKind: "updateMessageId", updateMessageId: { randomId: payload.randomId, messageId: message.id } }),
          appendUpdate(`chat:${chat.id}`, { oneofKind: "newMessage", newMessage: { message } }),
        ]
        chat.seq = updates[1]!.seq
        const result = P.SendMessageResult.create({ updates })
        sends.set(payload.randomId, { chatId: chat.id, result })
        // Push and RPC acknowledgement deliberately share canonical updates.
        broadcast(updates)
        return { oneofKind: "sendMessage", sendMessage: result }
      }
      case "readMessages": {
        const payload = input.readMessages
        const chat = chatFor(payload.peerId)
        const dialog = dialogs.get(chat.id)!
        const maxId = payload.maxId ?? chat.lastMsgId ?? 0n
        const updates: P.Update[] = []
        if (maxId > (dialog.readMaxId ?? 0n)) {
          dialog.readMaxId = maxId
          dialog.unreadCount = (histories.get(chat.id) ?? []).filter((message) => !message.out && message.id > maxId).length
          updates.push(appendUpdate("user", { oneofKind: "updateReadMaxId", updateReadMaxId: { peerId: chat.peerId, readMaxId: maxId, unreadCount: dialog.unreadCount } }))
          broadcast(updates)
        }
        return { oneofKind: "readMessages", readMessages: P.ReadMessagesResult.create({ updates }) }
      }
      case "getUpdatesState": {
        const hints = visibleChats().filter((chat) => (chat.seq ?? 0) > 0).map((chat) => P.Update.create({
          date: now(), update: { oneofKind: "chatHasNewUpdates", chatHasNewUpdates: { chatId: chat.id, peerId: chat.peerId, updateSeq: chat.seq! } },
        }))
        broadcast(hints)
        return { oneofKind: "getUpdatesState", getUpdatesState: P.GetUpdatesStateResult.create({ date: now(), seq: updateLogs.get("user")?.length ?? 0, updatesFound: hints.length > 0 }) }
      }
      case "getUpdates": {
        const payload = input.getUpdates
        const bucket = payload.bucket?.type
        if (bucket?.oneofKind === "space") requireSpaceAccess(bucket.space.spaceId)
        const key = bucket?.oneofKind === "chat" ? `chat:${chatFor(bucket.chat.peerId).id}` : bucket?.oneofKind === "space" ? `space:${bucket.space.spaceId}` : "user"
        replays[key] = (replays[key] ?? 0) + 1
        const log = updateLogs.get(key) ?? []
        const ceiling = payload.seqEnd > 0n ? payload.seqEnd : BigInt(log.length)
        const rows = log.filter((update) => BigInt(update.seq!) > payload.startSeq && BigInt(update.seq!) <= ceiling)
        const updates = rows.slice(0, Math.min(100, Math.max(1, payload.limit || 100)))
        return { oneofKind: "getUpdates", getUpdates: P.GetUpdatesResult.create({
          updates, seq: updates.at(-1)?.seq != null ? BigInt(updates.at(-1)!.seq!) : payload.startSeq,
          date: now(), final: updates.length === rows.length,
          resultType: updates.length ? P.GetUpdatesResult_ResultType.SLICE : P.GetUpdatesResult_ResultType.EMPTY,
          sidecars: replaySidecars(updates, key),
        }) }
      }
      case "reserveChatIds":
        return { oneofKind: "reserveChatIds", reserveChatIds: P.ReserveChatIdsResult.create({
          reservations: Array.from({ length: Math.min(10, Math.max(1, input.reserveChatIds.count)) }, () => ({ chatId: ++nextChatId, expiresAt: now() + 3600n })),
        }) }
      case "createChat": {
        const payload = input.createChat
        if (payload.spaceId != null) requireSpaceAccess(payload.spaceId)
        const id = payload.reservedChatId ?? ++nextChatId
        let chat = chats.get(id)
        if (!chat) {
          chat = P.Chat.create({ id, title: payload.title || payload.placeholderTitle || "New thread", untitled: !payload.title,
            spaceId: payload.spaceId, description: payload.description, emoji: payload.emoji,
            isPublic: payload.isPublic, peerId: peer(id), createdBy: TEST_USER_ID, date: now(), seq: 0,
            permissions: { canUpdateInfo: true },
          })
          chats.set(id, chat)
          histories.set(id, [])
          dialogs.set(id, P.Dialog.create({ chatId: id, peer: chat.peerId, spaceId: chat.spaceId, open: true, readMaxId: 0n, unreadCount: 0 }))
        }
        return { oneofKind: "createChat", createChat: P.CreateChatResult.create({ chat, dialog: dialogs.get(id) }) }
      }
      default:
        throw new Error(`Unsupported synthetic RPC: ${method}`)
    }
  }

  return {
    execute,
    setBroadcast(value: typeof broadcast) { broadcast = value },
    access(action: "prepare" | "remove" | "rejoin" | "lateRemoval") {
      if (action === "prepare" && !chats.has(TEST_ACCESS_CHAT_ID)) {
        spaces.push(P.Space.create({ id: TEST_ACCESS_SPACE_ID, name: "Public access qualification", isPublic: true, creator: false, date: now(), seq: 0 }))
        for (const [id, parentChatId] of [[TEST_ACCESS_CHAT_ID, undefined], [TEST_ACCESS_CHILD_ID, TEST_ACCESS_CHAT_ID]] as const) {
          const chat = P.Chat.create({ id, title: parentChatId == null ? "Membership-bound public thread" : "Legacy inherited child", parentChatId,
            spaceId: parentChatId == null ? TEST_ACCESS_SPACE_ID : undefined, isPublic: true, peerId: peer(id), date: now(), seq: 0,
          })
          chats.set(id, chat)
          histories.set(id, [])
          appendMessage(chat, `Authorized ${parentChatId == null ? "parent" : "legacy child"} history`, AVA_ID)
          dialogs.set(id, P.Dialog.create({ chatId: id, peer: chat.peerId, spaceId: chat.spaceId, open: true, readMaxId: 0n, unreadCount: 1 }))
        }
      }
      if (!chats.has(TEST_ACCESS_CHAT_ID)) throw new Error("Prepare the synthetic access scenario first")
      if (action === "remove") {
        if (accessMemberId == null) throw new Error("Synthetic member is already absent")
        previousAccessMemberId = accessMemberId
        accessMemberId = undefined
        // Server's durable userSpaceMemberDelete projection intentionally has
        // no memberId. The ordered user cursor owns this access decision.
        appendUpdate("user", { oneofKind: "spaceMemberDelete", spaceMemberDelete: { spaceId: TEST_ACCESS_SPACE_ID, userId: TEST_USER_ID } })
        // Match removed-user live delivery: eviction is a generation-bearing
        // hint; its canonical durable row is obtained through user replay.
        broadcast([P.Update.create({ date: now(), update: { oneofKind: "spaceMemberDelete", spaceMemberDelete: { spaceId: TEST_ACCESS_SPACE_ID, userId: TEST_USER_ID, memberId: previousAccessMemberId } } })])
      } else if (action === "lateRemoval") {
        if (previousAccessMemberId == null) throw new Error("No old synthetic membership")
        // This delayed live eviction names its immutable, obsolete generation.
        broadcast([P.Update.create({ date: now(), update: { oneofKind: "spaceMemberDelete", spaceMemberDelete: { spaceId: TEST_ACCESS_SPACE_ID, userId: TEST_USER_ID, memberId: previousAccessMemberId } } })])
      } else if (accessMemberId == null) {
        accessMemberId = ++nextAccessMemberId
        const space = spaces.find((item) => item.id === TEST_ACCESS_SPACE_ID)!
        const updates = [appendUpdate("user", { oneofKind: "joinSpace", joinSpace: { space, member: { id: accessMemberId, spaceId: TEST_ACCESS_SPACE_ID, userId: TEST_USER_ID, date: now(), canAccessPublicChats: true } } })]
        for (const id of [TEST_ACCESS_CHAT_ID, TEST_ACCESS_CHILD_ID]) {
          updates.push(appendUpdate("user", { oneofKind: "chatOpen", chatOpen: { chat: chats.get(id), dialog: dialogs.get(id) } }))
        }
        broadcast(updates)
      }
      return { spaceId: String(TEST_ACCESS_SPACE_ID), parentChatId: String(TEST_ACCESS_CHAT_ID), childChatId: String(TEST_ACCESS_CHILD_ID),
        memberId: accessMemberId == null ? null : String(accessMemberId), previousMemberId: previousAccessMemberId == null ? null : String(previousAccessMemberId), userSeq: updateLogs.get("user")?.length ?? 0 }
    },
    inject(chatId = TEST_DESIGN_CHAT_ID, text = "A live fixture message arrived while you were reading.", fromId = AVA_ID) {
      const chat = chats.get(chatId)
      if (!chat) throw new Error("Unknown synthetic chat")
      if (!users.some((user) => user.id === fromId)) throw new Error("Unknown synthetic sender")
      const message = appendMessage(chat, text, fromId)
      const update = appendUpdate(`chat:${chat.id}`, { oneofKind: "newMessage", newMessage: { message } })
      chat.seq = update.seq
      injectedMessages++
      if (accessible(chat)) broadcast([update])
      return { chatId: String(chat.id), messageId: String(message.id) }
    },
    state() {
      return { methods: { ...methods }, replays: { ...replays }, sendAttempts, uniqueSentMessages: sends.size, injectedMessages,
        chats: [...chats.values()].map((chat) => ({ id: String(chat.id), title: chat.title, messageCount: histories.get(chat.id)?.length ?? 0, seq: chat.seq ?? 0 })),
      }
    },
  }
}

export function startProtocolTestServer(options: { port?: number } = {}) {
  const fixture = createProtocolFixture()
  const sockets = new Set<Bun.ServerWebSocket<{ authenticated: boolean }>>()
  let online = true
  let authorized = true
  let serverMessageId = 0n
  let heldHistoryChatId: bigint | undefined
  const heldHistory: Array<() => void> = []
  let holdUserReplay = false
  const heldUserReplays: Array<{ release: () => void; seq: string; updateCount: number; hasSidecars: boolean }> = []
  const send = (socket: Bun.ServerWebSocket<{ authenticated: boolean }>, body: P.ServerProtocolMessage["body"]) => {
    socket.send(P.ServerProtocolMessage.toBinary(P.ServerProtocolMessage.create({ id: ++serverMessageId, body })))
  }
  fixture.setBroadcast((updates) => {
    if (!online || updates.length === 0) return
    for (const socket of sockets) if (socket.data.authenticated) send(socket, { oneofKind: "message", message: { payload: { oneofKind: "update", update: { updates } } } })
  })
  const json = (request: Request, value: unknown, status = 200) => {
    const headers = new Headers({ "Content-Type": "application/json", "Cache-Control": "no-store" })
    const origin = request.headers.get("Origin")
    if (origin === "http://127.0.0.1:8011" || origin === "http://127.0.0.1:8010") headers.set("Access-Control-Allow-Origin", origin)
    headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type")
    headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    headers.set("Vary", "Origin")
    return new Response(JSON.stringify(value), { status, headers })
  }
  return Bun.serve<{ authenticated: boolean }>({
    hostname: "127.0.0.1", port: options.port ?? 8012,
    async fetch(request, server) {
      const url = new URL(request.url)
      if (request.method === "OPTIONS") return json(request, {}, 200)
      if (url.pathname === "/test/state" && request.method === "GET") return json(request, { online, openSockets: sockets.size, heldHistoryCount: heldHistory.length, heldUserReplayCount: heldUserReplays.length,
        heldUserReplayPages: heldUserReplays.map(({ seq, updateCount, hasSidecars }) => ({ seq, updateCount, hasSidecars })), ...fixture.state() })
      if (url.pathname === "/test/access" && request.method === "POST") {
        const body = await request.json().catch(() => null)
        if (!["prepare", "remove", "rejoin", "lateRemoval"].includes(body?.action)) return json(request, { error: "Invalid synthetic access action" }, 400)
        try { return json(request, fixture.access(body.action)) }
        catch (error) { return json(request, { error: error instanceof Error ? error.message : "Synthetic access action failed" }, 400) }
      }
      if (url.pathname === "/test/history" && request.method === "POST") {
        const body = await request.json().catch(() => null)
        if (typeof body?.hold !== "boolean" || (body.hold && typeof body.chatId !== "string")) return json(request, { error: "Expected {hold:boolean,chatId?:string}" }, 400)
        if (body.hold) {
          try { heldHistoryChatId = BigInt(body.chatId) }
          catch { return json(request, { error: "Invalid synthetic history chat" }, 400) }
        } else {
          heldHistoryChatId = undefined
          for (const release of heldHistory.splice(0)) release()
        }
        return json(request, { heldHistoryCount: heldHistory.length })
      }
      if (url.pathname === "/test/replay" && request.method === "POST") {
        const body = await request.json().catch(() => null)
        if (typeof body?.hold !== "boolean") return json(request, { error: "Expected {hold:boolean}" }, 400)
        holdUserReplay = body.hold
        if (!holdUserReplay) for (const { release } of heldUserReplays.splice(0)) release()
        return json(request, { heldUserReplayCount: heldUserReplays.length })
      }
      if (url.pathname === "/test/network" && request.method === "POST") {
        const body = await request.json().catch(() => null)
        if (typeof body?.online !== "boolean") return json(request, { error: "Expected {online:boolean}" }, 400)
        online = body.online
        if (!online) for (const socket of sockets) socket.close(1012, "Synthetic network interruption")
        return json(request, { online })
      }
      if (url.pathname === "/test/message" && request.method === "POST") {
        try {
          const body = await request.json()
          if (body.message != null && typeof body.message !== "string") throw new Error("Expected string message")
          const result = fixture.inject(body.chatId == null ? undefined : BigInt(body.chatId), body.message, body.fromId == null ? undefined : BigInt(body.fromId))
          return json(request, result)
        } catch { return json(request, { error: "Invalid synthetic message" }, 400) }
      }
      if (!online) return json(request, { ok: false, description: "Synthetic network unavailable" }, 503)
      if (url.pathname === "/realtime") {
        if (server.upgrade(request, { data: { authenticated: false } })) return
        return json(request, { error: "WebSocket upgrade required" }, 400)
      }
      if (url.pathname === "/v1/sendEmailCode" || url.pathname === "/v1/verifyEmailCode") {
        const params = request.method === "POST" ? await request.json().catch(() => null) : Object.fromEntries(url.searchParams)
        if (params?.email !== TEST_EMAIL) return json(request, { ok: false, description: "Use the synthetic test email" }, 400)
        if (url.pathname.endsWith("sendEmailCode")) return json(request, { ok: true, result: { challengeToken: "synthetic-email-challenge" } })
        if (params.code !== TEST_CODE) return json(request, { ok: false, description: "Invalid synthetic code" }, 400)
        authorized = true
        return json(request, { ok: true, result: { userId: String(TEST_USER_ID), token: TEST_TOKEN } })
      }
      if (url.pathname === "/v1/logout" && request.method === "POST") {
        authorized = false
        for (const socket of sockets) socket.close(1000, "Synthetic session ended")
        return json(request, { ok: true, result: {} })
      }
      return json(request, { error: "Unknown synthetic fixture endpoint" }, 404)
    },
    websocket: {
      open(socket) { sockets.add(socket) },
      close(socket) { sockets.delete(socket) },
      message(socket, bytes) {
        if (!online) { socket.close(1012, "Synthetic network interruption"); return }
        if (typeof bytes === "string") { socket.close(1003, "Binary protocol required"); return }
        let request: P.ClientMessage
        try { request = P.ClientMessage.fromBinary(new Uint8Array(bytes)) }
        catch { socket.close(1003, "Malformed synthetic protocol frame"); return }
        if (request.body.oneofKind === "connectionInit") {
          if (!authorized || request.body.connectionInit.token !== TEST_TOKEN) {
            send(socket, { oneofKind: "connectionError", connectionError: { reason: P.ConnectionError_Reason.UNAUTHORIZED } })
            socket.close(1008, "Synthetic authentication required")
            return
          }
          socket.data.authenticated = true
          send(socket, { oneofKind: "connectionOpen", connectionOpen: {} })
          return
        }
        if (!socket.data.authenticated) { socket.close(1008, "Initialize the synthetic connection first"); return }
        if (request.body.oneofKind === "ping") { send(socket, { oneofKind: "pong", pong: request.body.ping }); return }
        if (request.body.oneofKind !== "rpcCall") return
        send(socket, { oneofKind: "ack", ack: { msgId: request.id } })
        try {
          // Encode/decode at execution time so a held page is an immutable
          // pre-removal server response, rather than a live fixture reference.
          const result = P.RpcResult.fromBinary(P.RpcResult.toBinary(P.RpcResult.create({ reqMsgId: request.id, result: fixture.execute(request.body.rpcCall) })))
          const call = request.body.rpcCall.input
          const release = () => send(socket, { oneofKind: "rpcResult", rpcResult: result })
          if (call.oneofKind === "getChatHistory" && call.getChatHistory.peerId?.type.oneofKind === "chat" && call.getChatHistory.peerId.type.chat.chatId === heldHistoryChatId) heldHistory.push(release)
          else if (call.oneofKind === "getUpdates" && call.getUpdates.bucket?.type.oneofKind === "user" && holdUserReplay && result.result.oneofKind === "getUpdates") {
            heldUserReplays.push({ release, seq: String(result.result.getUpdates.seq), updateCount: result.result.getUpdates.updates.length, hasSidecars: result.result.getUpdates.sidecars != null })
          }
          else release()
        } catch (error) {
          send(socket, { oneofKind: "rpcError", rpcError: { reqMsgId: request.id, errorCode: error instanceof Error && "errorCode" in error ? error.errorCode as P.RpcError_Code : P.RpcError_Code.BAD_REQUEST, code: 400, message: error instanceof Error ? error.message : "Synthetic RPC failed" } })
        }
      },
    },
  })
}

if (import.meta.main) {
  const server = startProtocolTestServer()
  console.log(`Synthetic Inline protocol fixture listening at ${server.url}`)
}
