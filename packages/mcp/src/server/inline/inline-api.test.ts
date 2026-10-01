import { beforeEach, describe, expect, it, vi } from "vitest"
import { GetChatHistoryMode, Method } from "@inline-chat/protocol/core"
import type { Chat, GetChatsResult, GetSpaceMembersResult, Message, Space, User } from "@inline-chat/protocol/core"
import { createInlineApi } from "./inline-api"

const realtimeSdk = vi.hoisted(() => {
  const client = {
    close: vi.fn(),
    connect: vi.fn(),
    events: vi.fn(),
    invoke: vi.fn(),
    sendMessage: vi.fn(),
  }
  return {
    client,
    InlineSdkClient: vi.fn(function InlineSdkClient() {
      return client
    }),
  }
})

vi.mock("@inline-chat/realtime-sdk", () => ({
  InlineSdkClient: realtimeSdk.InlineSdkClient,
}))

function space(id: bigint, name: string): Space {
  return { id, name, creator: false, date: 1n }
}

function user(id: bigint, firstName: string, lastName: string, username: string): User {
  return { id, firstName, lastName, username }
}

function spaceChat(id: bigint, title: string, spaceId: bigint, lastMsgId: bigint): Chat {
  return { id, title, spaceId, lastMsgId, date: 1n }
}

function message(id: bigint, chatId: bigint, fromId: bigint, text: string): Message {
  return { id, chatId, fromId, message: text, out: false, date: id }
}

describe("createInlineApi", () => {
  beforeEach(() => {
    realtimeSdk.InlineSdkClient.mockClear()
    realtimeSdk.client.close.mockReset().mockResolvedValue(undefined)
    realtimeSdk.client.connect.mockReset().mockResolvedValue(undefined)
    realtimeSdk.client.events.mockReset().mockReturnValue({
      async *[Symbol.asyncIterator]() {},
    })
    realtimeSdk.client.invoke.mockReset()
    realtimeSdk.client.sendMessage.mockReset().mockResolvedValue({ messageId: 300n })
  })

  it.each(["text", "caption", "blank caption"])("forwards %s through the SDK without changing Markdown", async (kind) => {
    const api = createInlineApi({
      baseUrl: "https://api.inline.test",
      token: "test-token",
      allowed: { allowedSpaceIds: [], allowDms: true, allowHomeThreads: false },
    })
    const text = kind === "blank caption" ? " \n\t " : "    code();\n\n**Ready** ~~old~~ ==new== <u>reviewed</u> $x^2$\n"
    const common = { userId: 2n, text, replyToMsgId: 9n, sendMode: "silent" as const, parseMarkdown: true }
    try {
      if (kind === "text") await api.sendMessage(common)
      else await api.sendMediaMessage({ ...common, media: { kind: "photo", id: 501n } })
      expect(realtimeSdk.client.sendMessage).toHaveBeenCalledWith({
        userId: 2n,
        replyToMsgId: 9n,
        sendMode: "silent",
        ...(kind === "blank caption" ? {} : { text, parseMarkdown: true }),
        ...(kind === "text" ? {} : { media: { kind: "photo", photoId: 501n } }),
      })
    } finally {
      await api.close()
    }
  })

  it("acknowledges the SDK event stream and joins it on close", async () => {
    const next = vi.fn()
      .mockResolvedValueOnce({ value: { kind: "chat.updated" }, done: false })
      .mockResolvedValueOnce({ value: undefined, done: true })
    realtimeSdk.client.events.mockReturnValue({
      [Symbol.asyncIterator]: () => ({ next }),
    })

    const api = createInlineApi({
      baseUrl: "https://api.inline.test",
      token: "test-token",
      allowed: {
        allowedSpaceIds: [],
        allowDms: false,
        allowHomeThreads: false,
      },
    })
    realtimeSdk.client.invoke.mockResolvedValue({
      getChats: { dialogs: [], folders: [], chats: [], spaces: [], users: [], messages: [] },
    })

    await api.listSpaces({ limit: 1 })
    await vi.waitFor(() => expect(next).toHaveBeenCalledTimes(2))
    await api.close()

    expect(realtimeSdk.client.events).toHaveBeenCalledTimes(1)
    expect(realtimeSdk.client.close).toHaveBeenCalledTimes(1)
  })

  it("closes before connecting and joins the event stream", async () => {
    let finishDrain: ((result: IteratorResult<unknown>) => void) | undefined
    realtimeSdk.client.events.mockReturnValue({
      [Symbol.asyncIterator]: () => ({
        next: () => new Promise<IteratorResult<unknown>>((resolve) => {
          finishDrain = resolve
        }),
      }),
    })
    realtimeSdk.client.close.mockImplementationOnce(async () => {
      finishDrain?.({ value: undefined, done: true })
    })
    const api = createInlineApi({
      baseUrl: "https://api.inline.test",
      token: "test-token",
      allowed: {
        allowedSpaceIds: [],
        allowDms: false,
        allowHomeThreads: false,
      },
    })

    await api.close()

    expect(realtimeSdk.client.connect).not.toHaveBeenCalled()
    expect(realtimeSdk.client.close).toHaveBeenCalledTimes(1)
  })

  it("limits people search to users from allowed contexts", async () => {
    const allowedPayloadUser = user(2n, "Ali", "Allowed", "ali")
    const disallowedPayloadUser = user(3n, "Dena", "Secret", "dena")
    const allowedMemberUser = user(4n, "Sam", "Member", "sam")
    const requestedSpaceIds: bigint[] = []
    const getChats: GetChatsResult = {
      dialogs: [],
      folders: [],
      chats: [spaceChat(7n, "Allowed", 10n, 100n), spaceChat(8n, "Secret", 20n, 200n)],
      spaces: [space(10n, "Allowed Space"), space(20n, "Secret Space")],
      users: [allowedPayloadUser, disallowedPayloadUser],
      messages: [message(100n, 7n, 2n, "allowed"), message(200n, 8n, 3n, "secret")],
    }
    const getSpaceMembers: GetSpaceMembersResult = {
      members: [{ id: 1n, spaceId: 10n, userId: 4n, date: 1n, canAccessPublicChats: true }],
      users: [allowedMemberUser],
    }

    realtimeSdk.client.invoke.mockImplementation(async (method: Method, input: { getSpaceMembers?: { spaceId: bigint } }) => {
      if (method === Method.GET_CHATS) return { getChats }
      if (method === Method.GET_SPACE_MEMBERS) {
        const spaceId = input.getSpaceMembers?.spaceId
        if (spaceId == null) throw new Error("missing spaceId")
        requestedSpaceIds.push(spaceId)
        return { getSpaceMembers }
      }
      throw new Error(`unexpected method ${method}`)
    })

    const api = createInlineApi({
      baseUrl: "https://api.inline.test",
      token: "test-token",
      allowed: {
        allowedSpaceIds: [10n],
        allowDms: false,
        allowHomeThreads: false,
      },
    })

    const result = await api.searchPeople({ limit: 10 })

    expect(result.items.map((item) => item.userId)).toContain(2n)
    expect(result.items.map((item) => item.userId)).toContain(4n)
    expect(result.items.map((item) => item.userId)).not.toContain(3n)
    expect(requestedSpaceIds).toEqual([10n])
  })

  it.each(["recent", "search", "filter-only search"])("%s includes names and avatar URLs only for returned authors without profile RPCs", async (operation) => {
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    const invokeContext = async (method: Method) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Source", 10n, 100n)], dialogs: [], users: [] as User[], spaces: [], messages: [], folders: [] } }
      throw new Error(`unexpected method ${method}`)
    }
    const messages = [message(100n, 7n, 2n, "Visible author"), message(99n, 7n, 4n, "Unknown author")]
    realtimeSdk.client.invoke.mockImplementation(async (method) => {
      if (method === Method.GET_CHAT_HISTORY) return { getChatHistory: { messages } }
      if (method === Method.SEARCH_MESSAGES) return { searchMessages: { messages } }
      const result = await invokeContext(method)
      if (method === Method.GET_CHATS) result.getChats.users = [
        { ...user(2n, "Dena", "Example", "dena"), profilePhoto: { cdnUrl: "https://api.inline.chat/file?id=avatar_two&exp=1999999999&sig=fixture" } },
        { ...user(3n, "Unrelated", "Person", "other"), profilePhoto: { cdnUrl: "https://api.inline.chat/file?id=avatar_three&exp=1999999999&sig=fixture" } },
      ]
      return result
    })
    try {
      const result = operation === "recent"
        ? await api.recentMessages({ chatId: 7n })
        : await api.searchMessages({ chatId: 7n, query: operation === "search" ? "author" : undefined })
      expect(result.senderDisplayNames).toEqual({ "2": "Dena Example" })
      expect(result.senderAvatarUrls).toEqual({ "2": "https://api.inline.chat/file?id=avatar_two&exp=1999999999&sig=fixture" })
      expect(realtimeSdk.client.invoke.mock.calls.map(([method]) => method)).toEqual([
        Method.GET_CHATS, operation === "search" ? Method.SEARCH_MESSAGES : Method.GET_CHAT_HISTORY,
      ])
    } finally { await api.close() }
  })


  it.each([
    "https://example.com/file?id=avatar&exp=1999999999&sig=fixture",
    "http://api.inline.chat/file?id=avatar&exp=1999999999&sig=fixture",
    "https://api.inline.chat/other?id=avatar&exp=1999999999&sig=fixture",
    "https://user:pass@api.inline.chat/file?id=avatar&exp=1999999999&sig=fixture",
    "https://api.inline.chat/file?id=avatar&exp=1999999999&sig=fixture#fragment",
    "https://api.inline.chat/file?id=avatar",
    "data:image/svg+xml,<svg/>",
  ])("omits unsupported profile image URL %s", async (cdnUrl) => {
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    realtimeSdk.client.invoke.mockImplementation(async (method) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Source", 10n, 100n)], dialogs: [], users: [{ ...user(2n, "Dena", "Example", "dena"), profilePhoto: { cdnUrl } }], spaces: [], messages: [], folders: [] } }
      if (method === Method.GET_CHAT_HISTORY) return { getChatHistory: { messages: [message(100n, 7n, 2n, "Hello")] } }
      throw new Error(`unexpected method ${method}`)
    })
    try {
      const result = await api.recentMessages({ chatId: 7n })
      expect(result.senderAvatarUrls).toEqual({})
      expect(result.senderDisplayNames).toEqual({ "2": "Dena Example" })
    } finally { await api.close() }
  })

  it("continues after the last returned row when only 20 of 50 fetched rows fit", async () => {
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    const rows = Array.from({ length: 70 }, (_, index) => message(BigInt(100 - index), 7n, 2n, "Context"))
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Source", 10n, 100n)], dialogs: [], users: [], spaces: [], messages: [], folders: [] } }
      if (method === Method.GET_CHAT_HISTORY) {
        const offset = input.getChatHistory.offsetId
        return { getChatHistory: { messages: rows.filter((row) => offset == null || row.id < offset).slice(0, input.getChatHistory.limit) } }
      }
      throw new Error(`unexpected method ${method}`)
    })
    try {
      const first = await api.recentMessages({ chatId: 7n, limit: 20 })
      expect(first.messages.map((row) => row.id)).toEqual(rows.slice(0, 20).map((row) => row.id))
      expect(first.nextOffsetId).toBe(81n)
      const second = await api.recentMessages({ chatId: 7n, limit: 20, offsetId: first.nextOffsetId! })
      expect(second.messages.map((row) => row.id)).toEqual(rows.slice(20, 40).map((row) => row.id))
    } finally { await api.close() }
  })

  it.each(["search", "filter-only search"])("%s preserves continuation before client-side filters remove every row", async (operation) => {
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    const rows = [message(100n, 7n, 2n, "Source"), message(99n, 7n, 2n, "Source")]
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Source", 10n, 100n)], dialogs: [], users: [], spaces: [], messages: [], folders: [] } }
      if (method === Method.SEARCH_MESSAGES) return { searchMessages: { messages: rows } }
      if (method === Method.GET_CHAT_HISTORY) return { getChatHistory: { messages: input.getChatHistory.offsetId == null ? rows : [] } }
      throw new Error(`unexpected method ${method}`)
    })
    try {
      const found = await api.searchMessages({ chatId: 7n, limit: 2, query: operation === "search" ? "Source" : undefined, until: 90n })
      expect(found.messages).toEqual([])
      expect(found.nextOffsetId).toBe(99n)
    } finally { await api.close() }
  })

  it("freshly reauthorizes selected messages instead of trusting cached discovery", async () => {
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n] } })
    realtimeSdk.client.invoke.mockImplementation(async (method) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Previously allowed", 10n, 100n)], dialogs: [], users: [], spaces: [], messages: [], folders: [] } }
      if (method === Method.GET_CHAT) return { getChat: { chat: spaceChat(7n, "Moved outside scope", 20n, 100n), messages: [] } }
      throw new Error(`unexpected method ${method}`)
    })
    try {
      await api.getEligibleChats()
      await expect(api.getMessages({ chatId: 7n, messageIds: [100n], freshChatAuthorization: true })).rejects.toThrow("allowed context")
      expect(realtimeSdk.client.invoke.mock.calls.map(([method]) => method)).toEqual([Method.GET_CHATS, Method.GET_CHAT])
    } finally { await api.close() }
  })

  function historyFixture(rows: Message[], dialog: Record<string, unknown> = { readMaxId: 50n, unreadCount: 75 }) {
    const calls: any[] = []
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Source", 10n, 150n)], dialogs: [{ chatId: 7n, readMaxId: 999n, unreadCount: 0 }], users: [user(2n, "Dena", "Example", "dena")], spaces: [], messages: [], folders: [] } }
      if (method === Method.GET_CHAT) return { getChat: { chat: spaceChat(7n, "Source", 10n, 150n), dialog: { chatId: 7n, ...dialog }, messages: [] } }
      if (method === Method.GET_MESSAGES) return { getMessages: { messages: rows.filter((row) => input.getMessages.messageIds.includes(row.id)) } }
      if (method === Method.GET_CHAT_HISTORY) {
        const request = input.getChatHistory
        calls.push(request)
        const sorted = [...rows].sort((left, right) => left.id < right.id ? -1 : 1)
        const selected = request.mode === GetChatHistoryMode.HISTORY_MODE_NEWER
          ? sorted.filter((row) => row.id > request.afterId).slice(0, request.limit)
          : request.mode === GetChatHistoryMode.HISTORY_MODE_AROUND
            ? [...sorted.filter((row) => row.id < request.anchorId).slice(-request.beforeLimit), ...sorted.filter((row) => row.id === request.anchorId), ...sorted.filter((row) => row.id > request.anchorId).slice(0, request.afterLimit)]
            : sorted.filter((row) => request.beforeId == null || row.id < request.beforeId).slice(-request.limit)
        return { getChatHistory: { messages: selected.reverse() } }
      }
      throw new Error(`unexpected method ${method}`)
    })
    return calls
  }

  it("starts after the fresh read boundary and pages forward through more than 50 unread messages", async () => {
    const rows = Array.from({ length: 150 }, (_, index) => ({ ...message(BigInt(index + 1), 7n, 2n, "History"), out: (index + 1) % 4 === 0 }))
    const calls = historyFixture(rows)
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n] } })
    try {
      const first = await api.historyMessages({ chatId: 7n, startAt: "unread" })
      expect(first.chat.readMaxId).toBe(50n)
      expect(first.messages.map((row) => row.id)).toEqual(rows.slice(50, 100).map((row) => row.id))
      expect(first.nextAfterId).toBe(100n)
      expect(first.firstUnreadMessageId).toBeNull()
      expect(first.note).toContain("may include messages that don't count as unread")
      const next = await api.historyMessages({ chatId: 7n, afterId: first.nextAfterId! })
      expect(next.messages.map((row) => row.id)).toEqual(rows.slice(100).map((row) => row.id))
      expect(next.nextAfterId).toBeNull()
      expect(calls.map((call) => call.afterId)).toEqual([50n, 100n])
      expect(calls.every((call) => call.mode === GetChatHistoryMode.HISTORY_MODE_NEWER)).toBe(true)
    } finally { await api.close() }
  })

  it.each([null, 5n])("does not require the last-read row %s to exist or invent first-unread identity from a matching count", async (readMaxId) => {
    const rows = [message(7n, 7n, 2n, "Incoming"), { ...message(6n, 7n, 1n, "Outgoing"), out: true }, message(9n, 7n, 2n, "Incoming")]
    historyFixture(rows, { readMaxId: readMaxId ?? undefined, unreadCount: 2 })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n] } })
    try {
      const result = await api.historyMessages({ chatId: 7n, startAt: "unread" })
      expect(result.messages.map((row) => row.id)).toEqual([6n, 7n, 9n])
      expect(result.firstUnreadMessageId).toBeNull()
      expect(result.kind).toBe(readMaxId ? "unread" : "latest")
      if (!readMaxId) expect(result.note).toContain("read boundary is unavailable")
    } finally { await api.close() }
  })

  it("does not invent a first-unread message when incoming history contains replay rows", async () => {
    historyFixture([message(6n, 7n, 2n, "Imported replay"), message(7n, 7n, 2n, "Live")], { readMaxId: 5n, unreadCount: 1 })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n] } })
    try {
      const result = await api.historyMessages({ chatId: 7n, startAt: "unread" })
      expect(result.firstUnreadMessageId).toBeNull()
      expect(result.messages.map((row) => row.id)).toEqual([6n, 7n])
      expect(result.note).toContain("last-read position")
    } finally { await api.close() }
  })

  it("uses strict older cursors without skipping the probe row and reports a missing context anchor", async () => {
    const rows = Array.from({ length: 70 }, (_, index) => message(BigInt(index + 1), 7n, 2n, "History"))
    const calls = historyFixture(rows)
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n] } })
    try {
      const latest = await api.historyMessages({ chatId: 7n })
      expect(latest.messages.map((row) => row.id)).toEqual(rows.slice(20).map((row) => row.id))
      expect(latest.nextOffsetId).toBe(21n)
      const older = await api.historyMessages({ chatId: 7n, offsetId: latest.nextOffsetId! })
      expect(older.messages.map((row) => row.id)).toEqual(rows.slice(0, 20).map((row) => row.id))
      expect(older.nextOffsetId).toBeNull()
      expect(calls[1].beforeId).toBe(21n)
      const context = await api.historyMessages({ chatId: 7n, anchorMessageId: 75n })
      expect(context.note).toContain("selected message is unavailable")
      expect(context.anchorMessageId).toBe(75n)
    } finally { await api.close() }
  })

  it("continues search with the returned server cursor even when local filters emptied the preceding page", async () => {
    const rows = [message(100n, 7n, 2n, "Match"), message(99n, 7n, 2n, "Match"), message(90n, 7n, 2n, "Match")]
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Source", 10n, 100n)], dialogs: [], users: [], spaces: [], messages: [], folders: [] } }
      if (method === Method.SEARCH_MESSAGES) return { searchMessages: { messages: rows.filter((row) => input.searchMessages.offsetId == null || row.id < input.searchMessages.offsetId).slice(0, input.searchMessages.limit) } }
      throw new Error(`unexpected method ${method}`)
    })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n] } })
    try {
      const first = await api.searchMessages({ chatId: 7n, query: "Match", limit: 2, until: 90n })
      expect(first.messages).toEqual([])
      expect(first.nextOffsetId).toBe(99n)
      const second = await api.searchMessages({ chatId: 7n, query: "Match", limit: 2, until: 90n, offsetId: first.nextOffsetId! })
      expect(second.messages.map((message) => message.id)).toEqual([90n])
      expect(second.nextOffsetId).toBeNull()
    } finally { await api.close() }
  })
})
