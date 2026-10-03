import { beforeEach, describe, expect, it, vi } from "vitest"
import { Method } from "@inline-chat/protocol/core"
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

  it("retains the confirmed creation receipt without a fallible catalog read", async () => {
    const api = createInlineApi({
      baseUrl: "https://api.inline.test", token: "test-token",
      allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false },
    })
    realtimeSdk.client.invoke.mockImplementation(async (method) => {
      if (method === Method.CREATE_CHAT) return { createChat: { chat: spaceChat(777n, "Proposal review", 10n, 0n) } }
      throw new Error("Catalog unavailable after confirmed creation")
    })
    try {
      await expect(api.createChat({ title: "Proposal review", spaceId: 10n, isPublic: false, participantUserIds: [2n] }))
        .resolves.toMatchObject({ chatId: 777n, title: "Proposal review", spaceId: 10n, kind: "space_chat" })
      expect(realtimeSdk.client.invoke).toHaveBeenCalledTimes(1)
      // The creation receipt does not become a bypass for subsequent access.
      await expect(api.recentMessages({ chatId: 777n, freshChatAuthorization: true })).rejects.toThrow("Catalog unavailable")
    } finally { await api.close() }
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

  it("reports an exhausted short history page so refresh can remove deleted oldest messages", async () => {
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    let rows = [message(100n, 7n, 2n, "Newer"), message(99n, 7n, 2n, "Oldest")]
    realtimeSdk.client.invoke.mockImplementation(async (method) => {
      if (method === Method.GET_CHATS) return { getChats: { chats: [spaceChat(7n, "Source", 10n, 100n)], dialogs: [], users: [], spaces: [], messages: [], folders: [] } }
      if (method === Method.GET_CHAT_HISTORY) return { getChatHistory: { messages: rows } }
      throw new Error(`unexpected method ${method}`)
    })
    try {
      expect((await api.recentMessages({ chatId: 7n, limit: 50 })).nextOffsetId).toBeNull()
      rows = rows.slice(0, 1)
      const refreshed = await api.recentMessages({ chatId: 7n, limit: 50 })
      expect(refreshed.messages.map((row) => row.id)).toEqual([100n])
      expect(refreshed.nextOffsetId).toBeNull()
    } finally { await api.close() }
  })

  it.each(["search", "filter-only search"])("%s reports continuation only when the source may have more rows", async (operation) => {
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
      expect(found.nextOffsetId).toBe(operation === "search" ? 99n : null)
    } finally { await api.close() }
  })
})
