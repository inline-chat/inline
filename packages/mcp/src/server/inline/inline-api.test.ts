import { beforeEach, describe, expect, it, vi } from "vitest"
import { CreateSubthreadResult, ForwardMessagesResult, GetChatParticipantsResult, Method, RpcResult, Update } from "@inline-chat/protocol/core"
import type { Chat, GetChatsResult, GetSpaceMembersResult, Message, Space, User } from "@inline-chat/protocol/core"
import { createInlineApi } from "./inline-api"

const realtimeSdk = vi.hoisted(() => {
  const client = {
    close: vi.fn(),
    connect: vi.fn(),
    events: vi.fn(),
    invoke: vi.fn(),
    invokeRaw: vi.fn(),
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
    realtimeSdk.client.invokeRaw.mockReset()
    realtimeSdk.client.sendMessage.mockReset().mockResolvedValue({ messageId: 300n })
  })

  it("loads only the credential-bound self profile, including email, without catalog access", async () => {
    const self = { ...user(42n, " Jonny ", " Person ", " jonny "), email: " jonny@example.test ", phoneNumber: "+123", bio: "Private bio" }
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      expect(method).toBe(Method.GET_ME)
      expect(input).toEqual({ oneofKind: "getMe", getMe: {} })
      return RpcResult.fromBinary(RpcResult.toBinary(RpcResult.create({ result: { oneofKind: "getMe", getMe: { user: self } } }))).result
    })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [], allowDms: false, allowHomeThreads: false } })
    try {
      await expect(api.getProfile()).resolves.toEqual({ id: 42n, name: "Jonny Person", email: "jonny@example.test", nickname: "jonny" })
      expect(realtimeSdk.client.connect).toHaveBeenCalledTimes(1)
      expect(realtimeSdk.client.invoke).toHaveBeenCalledTimes(1)
    } finally { await api.close() }
  })

  it("omits unavailable labels and reads fresh metadata without changing identity", async () => {
    realtimeSdk.client.invoke.mockResolvedValueOnce({ getMe: { user: { id: 42n, firstName: "  ", username: " " } } })
      .mockResolvedValueOnce({ getMe: { user: { id: 42n, firstName: "New name", email: "new@example.test" } } })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [] } })
    try {
      await expect(api.getProfile()).resolves.toEqual({ id: 42n })
      await expect(api.getProfile()).resolves.toEqual({ id: 42n, name: "New name", email: "new@example.test" })
      expect(realtimeSdk.client.invoke).toHaveBeenCalledTimes(2)
    } finally { await api.close() }
  })

  it.each([undefined, { id: 0n }, { id: -1n }])("rejects unavailable self identity without an invented profile", async (self) => {
    realtimeSdk.client.invoke.mockResolvedValue({ getMe: { user: self } })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [] } })
    try { await expect(api.getProfile()).rejects.toThrow("Authenticated Inline profile is unavailable") }
    finally { await api.close() }
  })

  it("propagates a self read failure instead of using a prior profile or catalog", async () => {
    const failure = new Error("Self read unavailable")
    realtimeSdk.client.invoke.mockResolvedValueOnce({ getMe: { user: { id: 42n, email: "jonny@example.test" } } })
      .mockRejectedValueOnce(failure)
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [] } })
    try {
      await expect(api.getProfile()).resolves.toEqual({ id: 42n, email: "jonny@example.test" })
      await expect(api.getProfile()).rejects.toBe(failure)
      expect(realtimeSdk.client.invoke.mock.calls.map(([method]) => method)).toEqual([Method.GET_ME, Method.GET_ME])
    } finally { await api.close() }
  })

  it("requests expanded discovery, filters grants, and keeps ordinary discovery unchanged", async () => {
    const root = spaceChat(1n, "Root", 10n, 1n)
    const child = { ...spaceChat(3n, "Hidden child", 10n, 2n), parentChatId: 1n }
    const outside = { ...spaceChat(4n, "Other context", 20n, 1n), parentChatId: 2n }
    const dm: Chat = { id: 5n, title: "DM", date: 1n, peerId: { type: { oneofKind: "user", user: { userId: 2n } } } }
    const home: Chat = { id: 6n, title: "Home", date: 1n, peerId: { type: { oneofKind: "chat", chat: { chatId: 6n } } } }
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      expect(method).toBe(Method.GET_CHATS)
      const expanded = input.getChats.includeSubthreads === true
      return { getChats: { chats: expanded ? [root, child, outside, dm, home] : [root], dialogs: [], users: [], spaces: [], messages: [], folders: [] } }
    })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    try {
      expect((await api.getEligibleChats()).map((chat) => chat.chatId)).toEqual([1n])
      expect((await api.getEligibleChats({ includeSubthreads: true })).map((chat) => chat.chatId)).toEqual([3n, 1n])
      expect((await api.getEligibleChats()).map((chat) => chat.chatId)).toEqual([1n])
      expect(realtimeSdk.client.invoke).toHaveBeenCalledTimes(2)
      expect(realtimeSdk.client.invoke.mock.calls[1]?.[1]).toMatchObject({ getChats: { includeSubthreads: true } })
    } finally { await api.close() }
  })

  it("returns an empty expanded discovery result", async () => {
    realtimeSdk.client.invoke.mockResolvedValue({ getChats: { chats: [], dialogs: [], users: [], spaces: [], messages: [], folders: [] } })
    const api = createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed: { allowedSpaceIds: [], allowDms: true, allowHomeThreads: true } })
    try { expect(await api.getEligibleChats({ includeSubthreads: true })).toEqual([]) } finally { await api.close() }
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

  function fixtureApi(allowed = { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false }) {
    const chats = [spaceChat(7n, "Source", 10n, 100n), spaceChat(8n, "Destination", 10n, 90n)]
    realtimeSdk.client.invoke.mockImplementation(async (method: Method, input: any) => {
      if (method === Method.GET_CHATS) return { getChats: { chats, dialogs: [], users: [], spaces: [], messages: [], folders: [] } }
      if (method === Method.GET_CHAT) return { getChat: { chat: chats.find((chat) => chat.id === input.getChat.peerId.type.chat.chatId) } }
      throw new Error(`unexpected method ${method}`)
    })
    return { chats, api: createInlineApi({ baseUrl: "https://api.inline.test", token: "test-token", allowed }) }
  }

  it.each(["conversation", "history", "context", "messages", "search"] as const)("legacy %s reads refuse missing DMs without invoking mutation-capable user-peer RPCs", async (operation) => {
    const { api } = fixtureApi({ allowedSpaceIds: [], allowDms: true, allowHomeThreads: false })
    const read = {
      conversation: () => api.getConversation({ userId: 2n }),
      history: () => api.recentMessages({ userId: 2n }),
      context: () => api.messageContext({ userId: 2n, anchorMessageId: 100n }),
      messages: () => api.getMessages({ userId: 2n, messageIds: [100n] }),
      search: () => api.searchMessages({ userId: 2n, query: "topic" }),
    }
    try {
      await expect(read[operation]()).rejects.toThrow("no existing approved DM conversation")
      expect(realtimeSdk.client.invoke.mock.calls.map(([method]) => method)).toEqual([Method.GET_CHATS])
      expect(realtimeSdk.client.sendMessage).not.toHaveBeenCalled()
    } finally { await api.close() }
  })

  it.each(["conversation", "history", "context", "messages", "search"] as const)("legacy %s reads resolve approved existing DMs to a stable chat peer", async (operation) => {
    const { api, chats } = fixtureApi({ allowedSpaceIds: [], allowDms: true, allowHomeThreads: false })
    chats[0] = { ...chats[0]!, spaceId: undefined, peerId: { type: { oneofKind: "user", user: { userId: 2n } } } }
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      if (method === Method.GET_CHAT_PARTICIPANTS) return { getChatParticipants: GetChatParticipantsResult.create() }
      if (method === Method.GET_CHAT_HISTORY) return { getChatHistory: { messages: [] } }
      if (method === Method.GET_MESSAGES) return { getMessages: { messages: [] } }
      if (method === Method.SEARCH_MESSAGES) return { searchMessages: { messages: [] } }
      return invokeContext(method, input)
    })
    const read = {
      conversation: () => api.getConversation({ userId: 2n }),
      history: () => api.recentMessages({ userId: 2n }),
      context: () => api.messageContext({ userId: 2n, anchorMessageId: 100n }),
      messages: () => api.getMessages({ userId: 2n, messageIds: [100n] }),
      search: () => api.searchMessages({ userId: 2n, query: "topic" }),
    }
    try {
      expect(await read[operation]()).toMatchObject({ chat: { chatId: 7n, peerUserId: 2n } })
      const reads = realtimeSdk.client.invoke.mock.calls.filter(([method]) => method !== Method.GET_CHATS && method !== Method.GET_CHAT_PARTICIPANTS)
      expect(reads.length).toBeGreaterThan(0)
      for (const [, input] of reads) expect(input[input.oneofKind].peerId).toEqual({ type: { oneofKind: "chat", chat: { chatId: 7n } } })
    } finally { await api.close() }
  })

  it("refreshes existing-DM metadata rather than rejecting a DM created after the discovery cache warmed", async () => {
    const { api, chats } = fixtureApi({ allowedSpaceIds: [], allowDms: true, allowHomeThreads: false })
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => method === Method.GET_CHAT_HISTORY ? { getChatHistory: { messages: [] } } : invokeContext(method, input))
    try {
      expect(await api.getEligibleChats()).toEqual([])
      chats[0] = { ...chats[0]!, spaceId: undefined, peerId: { type: { oneofKind: "user", user: { userId: 2n } } } }
      expect(await api.recentMessages({ userId: 2n })).toMatchObject({ chat: { chatId: 7n } })
      expect(realtimeSdk.client.invoke.mock.calls.filter(([method]) => method === Method.GET_CHATS)).toHaveLength(2)
    } finally { await api.close() }
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

  it("continues recent history after the last consumed row without skipping the rest of a fetched page", async () => {
    const { api } = fixtureApi()
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    const history = Array.from({ length: 100 }, (_, index) => message(BigInt(100 - index), 7n, index % 2 === 0 ? 2n : 3n, "text"))
    realtimeSdk.client.invoke.mockImplementation(async (method, input: any) => {
      if (method !== Method.GET_CHAT_HISTORY) return invokeContext(method, input)
      return { getChatHistory: { messages: history.filter((item) => input.getChatHistory.offsetId == null || item.id < input.getChatHistory.offsetId).slice(0, input.getChatHistory.limit) } }
    })
    try {
      const first = await api.recentMessages({ chatId: 7n, limit: 2, senderUserId: 2n })
      expect(first.messages.map((item) => item.id)).toEqual([100n, 98n])
      expect(first.nextOffsetId).toBe(98n)
      expect(first.scannedCount).toBe(3)
      const second = await api.recentMessages({ chatId: 7n, limit: 2, senderUserId: 2n, offsetId: first.nextOffsetId! })
      expect(second.messages.map((item) => item.id)).toEqual([96n, 94n])
      const last = await api.recentMessages({ chatId: 7n, offsetId: 4n, limit: 20 })
      expect(last.messages.map((item) => item.id)).toEqual([3n, 2n, 1n])
      expect(last.nextOffsetId).toBeNull()
    } finally { await api.close() }
  })

  it("filters and sorts conversation candidates before applying the requested limit", async () => {
    const { api, chats } = fixtureApi({ allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: true })
    chats[0]!.title = "Alpha"
    chats[1]!.title = "Alpha Roadmap"
    chats.push({ id: 9n, title: "Alpha", peerId: { type: { oneofKind: "chat", chat: { chatId: 9n } } }, date: 1n })
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      const result = await invokeContext(method, input)
      if (method === Method.GET_CHATS) {
        result.getChats.dialogs = [{ chatId: 8n, unreadCount: 2 }, { chatId: 9n, unreadCount: 2 }]
        result.getChats.messages = [message(100n, 7n, 1n, "read"), message(90n, 8n, 1n, "unread"), message(110n, 9n, 1n, "home")]
      }
      return result
    })
    try {
      const unread = await api.resolveConversation("Alpha", 1, { unreadOnly: true, spaceId: 10n, kind: "space_chat" })
      expect(unread.candidates.map((chat) => chat.chatId)).toEqual([8n])
      const recent = await api.resolveConversation("Alpha", 1, { sort: "recent" })
      expect(recent.candidates.map((chat) => chat.chatId)).toEqual([9n])
    } finally { await api.close() }
  })

  it("honors conversation limits above twenty within the advertised bound", async () => {
    const { api, chats } = fixtureApi()
    for (let index = 0; index < 30; index++) chats.push(spaceChat(BigInt(100 + index), "Alpha", 10n, 1n))
    try { expect((await api.resolveConversation("Alpha", 30)).candidates).toHaveLength(30) }
    finally { await api.close() }
  })

  it.each(["recent", "unread", "relevance"] as const)("keeps %s query order stable across limits with equal date and unread count", async (sort) => {
    const { api, chats } = fixtureApi({ allowedSpaceIds: [10n], allowDms: true, allowHomeThreads: false })
    chats[0] = { ...chats[0]!, title: "Alpha", spaceId: undefined, peerId: { type: { oneofKind: "user", user: { userId: 2n } } } }
    chats[1]!.title = "Alpha Roadmap"
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      const result = await invokeContext(method, input)
      if (method === Method.GET_CHATS) {
        result.getChats.dialogs = [{ chatId: 7n, unreadCount: 2 }, { chatId: 8n, unreadCount: 2 }]
        result.getChats.messages = [
          { ...message(100n, 7n, 2n, "exact DM match"), date: 1700000000n },
          { ...message(90n, 8n, 2n, "partial thread match"), date: 1700000000n },
        ]
      }
      return result
    })
    try {
      const one = await api.resolveConversation("Alpha", 1, { sort })
      const two = await api.resolveConversation("Alpha", 2, { sort })
      const expected = sort === "relevance" ? [7n, 8n] : [8n, 7n]
      expect(two.candidates.map((chat) => chat.chatId)).toEqual(expected)
      expect(one.selected?.chatId).toBe(expected[0])
      expect(two.selected?.chatId).toBe(one.selected?.chatId)
      expect(two.candidates.find((chat) => chat.chatId === 7n)!.score).toBeGreaterThan(two.candidates.find((chat) => chat.chatId === 8n)!.score)
    } finally { await api.close() }
  })

  it.each([{ name: "zero", groupIds: [] }, { name: "two", groupIds: [20n, 21n] }])("counts $name explicit group grants without expanding them into direct participants", async ({ groupIds }) => {
    const { api } = fixtureApi()
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      if (method !== Method.GET_CHAT_PARTICIPANTS) return invokeContext(method, input)
      return { getChatParticipants: GetChatParticipantsResult.create({
        groupParticipants: groupIds.map((groupId) => ({ groupId, date: 1n })),
        users: [user(2n, "Group", "Member", "member")],
      }) }
    })
    try {
      const details = await api.getConversation({ chatId: 7n })
      expect(details.groupParticipantCount).toBe(groupIds.length)
      expect(details.participants).toEqual([])
    } finally { await api.close() }
  })

  it("keeps a search cursor on an empty page filtered by sender/time and forwards it to the next request", async () => {
    const { api } = fixtureApi()
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    realtimeSdk.client.invoke.mockImplementation(async (method, input: any) => {
      if (method !== Method.SEARCH_MESSAGES) return invokeContext(method, input)
      return { searchMessages: { messages: input.searchMessages.offsetId == null
        ? [message(100n, 7n, 3n, "topic"), message(99n, 7n, 3n, "topic")]
        : [message(98n, 7n, 2n, "topic")] } }
    })
    try {
      const first = await api.searchMessages({ chatId: 7n, query: "topic", limit: 2, senderUserId: 2n, until: 98n })
      expect(first.messages).toEqual([])
      expect(first.nextOffsetId).toBe(99n)
      expect(first.scannedCount).toBe(2)
      const second = await api.searchMessages({ chatId: 7n, query: "topic", limit: 2, senderUserId: 2n, until: 98n, offsetId: first.nextOffsetId! })
      expect(second.messages.map((item) => item.id)).toEqual([98n])
      expect(second.nextOffsetId).toBeNull()
      expect(realtimeSdk.client.invoke).toHaveBeenLastCalledWith(Method.SEARCH_MESSAGES, expect.objectContaining({ searchMessages: expect.objectContaining({ offsetId: 99n }) }))
    } finally { await api.close() }
  })

  it("creates a subthread through its actual wire result and preserves inherited context", async () => {
    const { api, chats } = fixtureApi()
    const child = { ...spaceChat(9n, "Child", 10n, 1n), parentChatId: 7n, parentMessageId: 100n }
    const wireResult = RpcResult.fromBinary(RpcResult.toBinary(RpcResult.create({ result: { oneofKind: "createSubthread", createSubthread: CreateSubthreadResult.create({ chat: child, anchorMessage: message(100n, 7n, 1n, "anchor") }) } }))).result
    realtimeSdk.client.invokeRaw.mockImplementation(async () => { chats.push(child); return wireResult })
    try {
      expect(await api.createSubthread({ parentChatId: 7n, parentMessageId: 100n, title: " Child ", participantUserIds: [2n, 2n] })).toMatchObject({ chat: { chatId: 9n, spaceId: 10n }, parentChatId: 7n, parentMessageId: 100n, anchorMessageId: 100n })
      expect(realtimeSdk.client.invokeRaw).toHaveBeenCalledWith(Method.CREATE_SUBTHREAD, expect.objectContaining({ createSubthread: expect.objectContaining({ parentChatId: 7n, parentMessageId: 100n, title: "Child", participants: [{ userId: 2n }] }) }))
    } finally { await api.close() }
  })

  it.each(["unavailable", "denied"])("retains the subthread receipt when a subsequent read is %s", async (failure) => {
    const { api } = fixtureApi()
    const child = { ...spaceChat(777n, "Confirmed child", 10n, 0n), parentChatId: 7n, parentMessageId: 100n }
    const wireResult = RpcResult.fromBinary(RpcResult.toBinary(RpcResult.create({ result: {
      oneofKind: "createSubthread",
      createSubthread: CreateSubthreadResult.create({ chat: child, anchorMessage: message(100n, 7n, 1n, "anchor") }),
    } }))).result
    let readsBeforeReceipt = 0
    realtimeSdk.client.invokeRaw.mockImplementation(async () => {
      readsBeforeReceipt = realtimeSdk.client.invoke.mock.calls.length
      realtimeSdk.client.invoke.mockImplementation(async (method) => {
        if (failure === "denied" && method === Method.GET_CHAT) return { getChat: { chat: { ...child, spaceId: 20n } } }
        throw new Error("Read unavailable after confirmed subthread creation")
      })
      return wireResult
    })
    try {
      await expect(api.createSubthread({ parentChatId: 7n, parentMessageId: 100n, title: "Confirmed child" }))
        .resolves.toMatchObject({ chat: { chatId: 777n, title: "Confirmed child", spaceId: 10n, kind: "space_chat" }, parentChatId: 7n, parentMessageId: 100n, anchorMessageId: 100n })
      expect(realtimeSdk.client.invokeRaw).toHaveBeenCalledTimes(1)
      expect(realtimeSdk.client.invoke).toHaveBeenCalledTimes(readsBeforeReceipt)
      // Creation invalidates discovery but never seeds an authorization bypass.
      await expect(api.getEligibleChats()).rejects.toThrow("Read unavailable")
      await expect(api.recentMessages({ chatId: 777n, freshChatAuthorization: true }))
        .rejects.toThrow(failure === "denied" ? "allowed context" : "Read unavailable")
    } finally { await api.close() }
  })

  it("rejects DM child creation without home access before invoking a mutation", async () => {
    const { api, chats } = fixtureApi({ allowedSpaceIds: [], allowDms: true, allowHomeThreads: false })
    chats[0] = { ...chats[0]!, spaceId: undefined, peerId: { type: { oneofKind: "user", user: { userId: 2n } } } }
    try {
      await expect(api.createSubthread({ parentChatId: 7n })).rejects.toThrow("requires home thread access")
      expect(realtimeSdk.client.invokeRaw).not.toHaveBeenCalled()
    } finally { await api.close() }
  })

  it("maps ordered forwarding receipts from protobuf updates, preserving repeated source IDs", async () => {
    const { api } = fixtureApi()
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    const updates = [501n, 502n, 503n].map((messageId) => Update.create({ update: { oneofKind: "updateMessageId", updateMessageId: { messageId, randomId: 0n } } }))
    const wireResult = ForwardMessagesResult.fromBinary(ForwardMessagesResult.toBinary(ForwardMessagesResult.create({ updates })))
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => method === Method.FORWARD_MESSAGES ? { forwardMessages: wireResult } : invokeContext(method, input))
    try {
      const result = await api.forwardMessages({ sourceChatId: 7n, destinationChatId: 8n, messageIds: [100n, 90n, 100n], shareForwardHeader: false })
      expect(result.messages).toEqual([{ sourceMessageId: 100n, destinationMessageId: 501n }, { sourceMessageId: 90n, destinationMessageId: 502n }, { sourceMessageId: 100n, destinationMessageId: 503n }])
      expect(realtimeSdk.client.invoke).toHaveBeenLastCalledWith(Method.FORWARD_MESSAGES, expect.objectContaining({ forwardMessages: expect.objectContaining({ messageIds: [100n, 90n, 100n], shareForwardHeader: false }) }))
    } finally { await api.close() }
  })

  it.each(["source", "destination"])("checks %s forwarding context before invoking a mutation", async (disallowed) => {
    const { api, chats } = fixtureApi()
    chats[disallowed === "source" ? 0 : 1]!.spaceId = 20n
    try {
      await expect(api.forwardMessages({ sourceChatId: 7n, destinationChatId: 8n, messageIds: [100n] })).rejects.toThrow("allowed context")
      expect(realtimeSdk.client.invoke.mock.calls.some(([method]) => method === Method.FORWARD_MESSAGES)).toBe(false)
    } finally { await api.close() }
  })

  it.each(["rpc error", "incomplete receipts"])("reports possible partial delivery after %s", async (failure) => {
    const { api } = fixtureApi()
    const invokeContext = realtimeSdk.client.invoke.getMockImplementation()!
    realtimeSdk.client.invoke.mockImplementation(async (method, input) => {
      if (method !== Method.FORWARD_MESSAGES) return invokeContext(method, input)
      if (failure === "rpc error") throw new Error("MESSAGE_ID_INVALID")
      return { forwardMessages: ForwardMessagesResult.create({ updates: [] }) }
    })
    try {
      await expect(api.forwardMessages({ sourceChatId: 7n, destinationChatId: 8n, messageIds: [100n, 99n] })).rejects.toThrow("Some messages may already have been delivered")
      expect(realtimeSdk.client.invoke.mock.calls.filter(([method]) => method === Method.FORWARD_MESSAGES)).toHaveLength(1)
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
