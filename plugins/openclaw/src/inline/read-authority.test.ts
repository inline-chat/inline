import { afterEach, describe, expect, it, vi } from "vitest"

type Chat = {
  chatId: bigint
  spaceId?: bigint
  parentChatId?: bigint
  peer?: unknown
  isPublic?: boolean
  participants?: bigint[]
}

const dmPeer = (userId: bigint) => ({ type: { oneofKind: "user", user: { userId } } })
const groupPeer = (chatId: bigint) => ({ type: { oneofKind: "chat", chat: { chatId } } })

// Space 9: private chats 100 (42, 77, 88) and 200 (42, 77), public chat 250;
// threads 110 under 100, 210 under 200 (no direct grants), 220 under 200 granted to 88.
// Space 8: chat 300.
// Home group 400 (no space; 42, 77) with threads 410, 420. Home group 500.
// Bot DM with user 42 is chat 600, with thread 610 under it. DM with user 43 is 700.
const CHATS: Chat[] = [
  { chatId: 100n, spaceId: 9n, peer: groupPeer(100n), participants: [42n, 77n, 88n] },
  { chatId: 110n, spaceId: 9n, parentChatId: 100n },
  { chatId: 200n, spaceId: 9n, peer: groupPeer(200n), participants: [42n, 77n] },
  { chatId: 210n, parentChatId: 200n },
  { chatId: 220n, spaceId: 9n, parentChatId: 200n, participants: [88n] },
  { chatId: 250n, spaceId: 9n, peer: groupPeer(250n), isPublic: true },
  { chatId: 300n, spaceId: 8n, peer: groupPeer(300n), participants: [42n] },
  { chatId: 400n, peer: groupPeer(400n), participants: [42n, 77n] },
  { chatId: 410n, parentChatId: 400n },
  { chatId: 420n, parentChatId: 400n },
  { chatId: 500n, peer: groupPeer(500n) },
  { chatId: 600n, peer: dmPeer(42n) },
  { chatId: 610n, parentChatId: 600n },
  { chatId: 700n, peer: dmPeer(43n) },
]

function harness() {
  const order: string[] = []
  const fence = vi.fn(() => {
    order.push("fence")
  })
  const client = {
    getChat: vi.fn(async ({ chatId }: { chatId: bigint }) => {
      order.push(`getChat:${chatId}`)
      const chat = CHATS.find((entry) => entry.chatId === chatId)
      if (!chat) throw new Error(`unknown chat ${chatId}`)
      return chat
    }),
    listChatParticipantIds: vi.fn(async ({ chatId }: { chatId: bigint }) => {
      order.push(`participants:${chatId}`)
      return CHATS.find((entry) => entry.chatId === chatId)?.participants ?? []
    }),
  }
  return { order, fence, client }
}

async function check(params: {
  current?: { chat?: string; thread?: string; provider?: string }
  target: { kind: "chat"; chatId: bigint } | { kind: "user"; userId: bigint }
  requester?: string
  origin?: "delegated" | "direct-operator"
}) {
  const { assertInlineReadAllowed } = await import("./read-authority")
  const h = harness()
  const promise = assertInlineReadAllowed({
    client: h.client,
    fence: h.fence,
    target: params.target,
    toolContext: params.current
      ? {
          currentChannelId: params.current.chat,
          currentThreadTs: params.current.thread,
          currentChannelProvider: params.current.provider,
        }
      : undefined,
    requesterSenderId: params.requester,
    conversationReadOrigin: params.origin,
  })
  return { ...h, promise }
}

describe("inline/read-authority guard", () => {
  it("leaves direct operators and context-free turns to host admission", async () => {
    const operator = await check({
      origin: "direct-operator",
      current: { chat: "100" },
      target: { kind: "chat", chatId: 700n },
    })
    await expect(operator.promise).resolves.toBeUndefined()
    expect(operator.client.getChat).not.toHaveBeenCalled()

    const contextFree = await check({ target: { kind: "chat", chatId: 700n } })
    await expect(contextFree.promise).resolves.toBeUndefined()
    expect(contextFree.client.getChat).not.toHaveBeenCalled()
  })

  it("allows the current conversation without lookups", async () => {
    const thread = await check({ current: { chat: "inline:100", thread: "110" }, target: { kind: "chat", chatId: 110n } })
    await expect(thread.promise).resolves.toBeUndefined()
    const chat = await check({ current: { chat: "inline:100" }, target: { kind: "chat", chatId: 100n } })
    await expect(chat.promise).resolves.toBeUndefined()
    expect(thread.client.getChat).not.toHaveBeenCalled()
    expect(chat.client.getChat).not.toHaveBeenCalled()
    expect(thread.client.listChatParticipantIds).not.toHaveBeenCalled()
  })

  it("allows another thread in the same space, fencing every lookup", async () => {
    const run = await check({
      current: { chat: "100", thread: "110" },
      target: { kind: "chat", chatId: 210n },
      requester: "42",
    })
    await expect(run.promise).resolves.toBeUndefined()
    // 210 has no spaceId of its own; its space comes from parent 200, and so
    // does the asker's access (no direct grant on 210).
    expect(run.order).toEqual([
      "fence", "getChat:110",
      "fence", "getChat:100",
      "fence", "getChat:210",
      "fence", "getChat:200",
      "fence", "participants:210",
      "fence", "participants:200",
    ])
  })

  it("requires the asker to be a participant of the target chat", async () => {
    const notInPrivate = await check({ current: { chat: "100" }, target: { kind: "chat", chatId: 200n }, requester: "88" })
    await expect(notInPrivate.promise).rejects.toThrow(/asker isn't a participant/)
    const notInThread = await check({ current: { chat: "100" }, target: { kind: "chat", chatId: 210n }, requester: "88" })
    await expect(notInThread.promise).rejects.toThrow(/asker isn't a participant/)
    const missingRequester = await check({ current: { chat: "100" }, target: { kind: "chat", chatId: 200n } })
    await expect(missingRequester.promise).rejects.toThrow(/needs the asking Inline user/)

    const inBoth = await check({ current: { chat: "100" }, target: { kind: "chat", chatId: 200n }, requester: "42" })
    await expect(inBoth.promise).resolves.toBeUndefined()
    expect(inBoth.order.filter((step) => step.startsWith("participants:"))).toEqual(["participants:200"])
    const threadGrant = await check({ current: { chat: "100" }, target: { kind: "chat", chatId: 220n }, requester: "88" })
    await expect(threadGrant.promise).resolves.toBeUndefined()
  })

  it("treats a public space chat as open to the asker without a participants lookup", async () => {
    const run = await check({ current: { chat: "100" }, target: { kind: "chat", chatId: 250n }, requester: "88" })
    await expect(run.promise).resolves.toBeUndefined()
    expect(run.client.listChatParticipantIds).not.toHaveBeenCalled()
  })

  it("allows sibling threads under the same home group", async () => {
    const run = await check({ current: { chat: "400", thread: "410" }, target: { kind: "chat", chatId: 420n }, requester: "42" })
    await expect(run.promise).resolves.toBeUndefined()
    const parent = await check({ current: { chat: "400", thread: "410" }, target: { kind: "chat", chatId: 400n }, requester: "42" })
    await expect(parent.promise).resolves.toBeUndefined()
  })

  it("denies chats outside the current space or parent chat", async () => {
    const otherSpace = await check({ current: { chat: "100" }, target: { kind: "chat", chatId: 300n }, requester: "42" })
    await expect(otherSpace.promise).rejects.toThrow(/current space or under the current parent chat/)
    const otherHomeGroup = await check({ current: { chat: "400", thread: "410" }, target: { kind: "chat", chatId: 500n }, requester: "42" })
    await expect(otherHomeGroup.promise).rejects.toThrow(/current space or under the current parent chat/)
  })

  it("keeps a DM's thread participants out of the parent DM", async () => {
    const childOnly = await check({ current: { chat: "600", thread: "610" }, target: { kind: "chat", chatId: 600n }, requester: "77" })
    await expect(childOnly.promise).rejects.toThrow(/allowed only for that DM's user/)
    const missingRequester = await check({ current: { chat: "600", thread: "610" }, target: { kind: "chat", chatId: 600n } })
    await expect(missingRequester.promise).rejects.toThrow(/allowed only for that DM's user/)
    const owner = await check({ current: { chat: "600", thread: "610" }, target: { kind: "chat", chatId: 600n }, requester: "42" })
    await expect(owner.promise).resolves.toBeUndefined()
  })

  it("denies other DMs, including reads aimed at the DM's user", async () => {
    const otherDm = await check({ current: { chat: "600" }, target: { kind: "chat", chatId: 700n }, requester: "42" })
    await expect(otherDm.promise).rejects.toThrow(/allowed only for that DM's user/)
    const otherUser = await check({ current: { chat: "600" }, target: { kind: "user", userId: 43n }, requester: "42" })
    await expect(otherUser.promise).rejects.toThrow(/another person's DM/)
    expect(otherUser.client.getChat).not.toHaveBeenCalled()
    const ownDmFromSpace = await check({ current: { chat: "100" }, target: { kind: "user", userId: 42n }, requester: "42" })
    await expect(ownDmFromSpace.promise).rejects.toThrow(/only from that DM or its threads/)
    const ownDmFromThread = await check({ current: { chat: "600", thread: "610" }, target: { kind: "user", userId: 42n }, requester: "42" })
    await expect(ownDmFromThread.promise).resolves.toBeUndefined()
  })

  it("denies reads started from another channel or an unknown current conversation", async () => {
    const slack = await check({ current: { chat: "C123", provider: "slack" }, target: { kind: "chat", chatId: 100n } })
    await expect(slack.promise).rejects.toThrow(/another channel's conversation/)
    const malformed = await check({ current: { chat: "user:42" }, target: { kind: "chat", chatId: 100n } })
    await expect(malformed.promise).rejects.toThrow(/needs an Inline chat id/)
  })

  it("stops before the lookup when the fence throws", async () => {
    const { assertInlineReadAllowed } = await import("./read-authority")
    const h = harness()
    const fence = vi.fn(() => {
      throw new Error("Channel read authority is no longer active.")
    })
    await expect(
      assertInlineReadAllowed({
        client: h.client,
        fence,
        target: { kind: "chat", chatId: 200n },
        toolContext: { currentChannelId: "100" },
        requesterSenderId: "42",
      }),
    ).rejects.toThrow("no longer active")
    expect(fence).toHaveBeenCalledTimes(1)
    expect(h.client.getChat).not.toHaveBeenCalled()
  })
})

describe("inline/read-authority fence", () => {
  afterEach(() => {
    vi.doUnmock("openclaw/plugin-sdk/fetch-runtime")
    vi.resetModules()
  })

  it("captures the host read authority once and checks it with the handoff on each call", async () => {
    vi.resetModules()
    const readAuthority = vi.fn()
    const capture = vi.fn(() => readAuthority)
    vi.doMock("openclaw/plugin-sdk/fetch-runtime", () => ({ captureChannelReadAuthority: capture }))
    const { captureInlineReadFence } = await import("./read-authority")
    const handoff = vi.fn()

    const fence = captureInlineReadFence({ assertDirectAdapterHandoff: handoff })
    fence()
    fence()

    expect(capture).toHaveBeenCalledTimes(1)
    expect(readAuthority).toHaveBeenCalledTimes(2)
    expect(handoff).toHaveBeenCalledTimes(2)
  })

  it("is a no-op on hosts without the read-authority export or scope", async () => {
    vi.resetModules()
    // Older hosts: the subpath exists but lacks the export.
    vi.doMock("openclaw/plugin-sdk/fetch-runtime", () => ({ captureChannelReadAuthority: undefined }))
    const { captureInlineReadFence } = await import("./read-authority")
    expect(() => captureInlineReadFence({})()).not.toThrow()

    vi.resetModules()
    vi.doMock("openclaw/plugin-sdk/fetch-runtime", () => ({ captureChannelReadAuthority: () => undefined }))
    const reloaded = await import("./read-authority")
    expect(() => reloaded.captureInlineReadFence({})()).not.toThrow()
  })
})

describe("inline/actions read authority", () => {
  afterEach(() => {
    vi.doUnmock("openclaw/plugin-sdk/fetch-runtime")
    vi.doUnmock("@inline-chat/realtime-sdk")
    vi.resetModules()
  })

  const cfg = { channels: { inline: { token: "token", baseUrl: "https://api.inline.chat" } } }

  async function loadActions(params: { readAuthority: () => void; order: string[] }) {
    vi.resetModules()
    vi.doMock("openclaw/plugin-sdk/fetch-runtime", () => ({
      captureChannelReadAuthority: () => params.readAuthority,
    }))
    const invokeRaw = vi.fn(async (method: number, input: { getChatParticipants?: { chatId: bigint } }) => {
      if (method === 14) {
        const chatId = input.getChatParticipants?.chatId
        params.order.push(`participants:${chatId}`)
        const ids = CHATS.find((entry) => entry.chatId === chatId)?.participants ?? []
        return {
          oneofKind: "getChatParticipants",
          getChatParticipants: { participants: ids.map((userId) => ({ userId, date: 0n })), users: [] },
        }
      }
      params.order.push("history")
      return { oneofKind: "getChatHistory", getChatHistory: { messages: [] } }
    })
    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: { GET_CHAT_HISTORY: 5, GET_CHAT_PARTICIPANTS: 14 },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {
          params.order.push("connect")
        })
        close = vi.fn(async () => {})
        getChat = vi.fn(async ({ chatId }: { chatId: bigint }) => {
          params.order.push(`getChat:${chatId}`)
          const chat = CHATS.find((entry) => entry.chatId === chatId)
          if (!chat) throw new Error(`unknown chat ${chatId}`)
          return chat
        })
        invokeRaw = invokeRaw
      },
    }))
    const { inlineMessageActions } = await import("./actions")
    return { inlineMessageActions, invokeRaw }
  }

  it("declares read as a fenced, provider-owned read action", async () => {
    const { inlineMessageActions } = await loadActions({ readAuthority: () => {}, order: [] })
    expect(inlineMessageActions.readAuthorityActions).toEqual(["read"])
    expect(inlineMessageActions.providerOwnedReadGates).toEqual(["read"])
  })

  it("fences connect, every target lookup, and the history request", async () => {
    const order: string[] = []
    const { inlineMessageActions } = await loadActions({ readAuthority: () => order.push("read-fence"), order })
    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "read",
      cfg,
      params: { threadId: "210", limit: 5 },
      toolContext: { currentChannelId: "100", currentThreadTs: "110", currentChannelProvider: "inline" },
      requesterSenderId: "42",
      conversationReadOrigin: "delegated",
      assertDirectAdapterHandoff: () => order.push("handoff"),
    } as any)

    expect(result).toMatchObject({ details: { ok: true, chatId: "210", threadId: "210" } })
    const fenced = (step: string) => ["read-fence", "handoff", step]
    expect(order).toEqual([
      ...fenced("connect"),
      ...fenced("getChat:110"),
      ...fenced("getChat:100"),
      ...fenced("getChat:210"),
      ...fenced("getChat:200"),
      ...fenced("participants:210"),
      ...fenced("participants:200"),
      ...fenced("history"),
    ])
  })

  it("rejects a child-only participant reading the parent DM before history", async () => {
    const order: string[] = []
    const { inlineMessageActions, invokeRaw } = await loadActions({ readAuthority: () => {}, order })
    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "read",
        cfg,
        params: { to: "600" },
        toolContext: { currentChannelId: "600", currentThreadTs: "610" },
        requesterSenderId: "77",
      } as any),
    ).rejects.toThrow(/allowed only for that DM's user/)
    expect(invokeRaw).not.toHaveBeenCalled()
  })

  it("stops without retrying once the host revokes read authority", async () => {
    const order: string[] = []
    let calls = 0
    const { inlineMessageActions, invokeRaw } = await loadActions({
      readAuthority: () => {
        calls += 1
        if (calls > 1) throw new Error("Channel read authority is no longer active.")
      },
      order,
    })
    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "read",
        cfg,
        params: { to: "100" },
        toolContext: { currentChannelId: "100" },
      } as any),
    ).rejects.toThrow("no longer active")
    expect(order).toEqual(["connect"])
    expect(invokeRaw).not.toHaveBeenCalled()
  })
})
