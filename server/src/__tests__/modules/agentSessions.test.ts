import { beforeEach, describe, expect, test } from "bun:test"
import {
  AgentSessionMessageRelation,
  AgentSessionMessageRole,
  AgentSessionMessageSyncState,
  AgentSessionProvider,
  AgentSessionSyncMode,
  ConnectAgentSessionState,
} from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import {
  agentSessionMessages,
  agentSessions,
  botMessageRoutes,
  chats,
  members,
  messages,
  spaces,
  users,
} from "@in/server/db/schema"
import {
  connectAgentSession,
  getAgentSession,
  syncAgentSessionMessages,
} from "@in/server/modules/agentSessions/service"
import { and, asc, eq } from "drizzle-orm"

describe("agent session continuity", () => {
  setupTestLifecycle()

  let ownerId = 0
  let botId = 0
  let teammateId = 0
  let chatId = 0

  beforeEach(async () => {
    const owner = await testUtils.createUser(`agent-owner-${crypto.randomUUID()}@example.com`)
    const bot = await testUtils.createUser(`agent-bot-${crypto.randomUUID()}@example.com`)
    const teammate = await testUtils.createUser(`agent-teammate-${crypto.randomUUID()}@example.com`)
    ownerId = owner.id
    botId = bot.id
    teammateId = teammate.id
    await db.update(users).set({ bot: true, botCreatorId: owner.id }).where(eq(users.id, bot.id))
    const chat = await testUtils.createChat(null, "Agent session", "thread", false, owner.id)
    if (!chat) throw new Error("chat not created")
    chatId = chat.id
    await Promise.all([
      testUtils.addParticipant(chat.id, owner.id),
      testUtils.addParticipant(chat.id, bot.id),
      testUtils.addParticipant(chat.id, teammate.id),
    ])
  })

  async function connect() {
    return connectAgentSession({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "codex-session",
      projectRef: "inline-public",
    }, ownerId)
  }

  test("imports one row per turn with canonical owner and bot authorship", async () => {
    const connected = await connect()
    expect(connected.state).toBe(ConnectAgentSessionState.CREATED)

    const synced = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [
        {
          role: AgentSessionMessageRole.USER,
          itemRef: "user-item",
          sourceDate: 1_700_000_000n,
          revisionRef: "user-r1",
          complete: true,
          operation: { oneofKind: "upsert", upsert: { text: "Run the tests" } },
        },
        {
          role: AgentSessionMessageRole.ASSISTANT,
          itemRef: "assistant-item",
          sourceDate: 1_700_000_001n,
          revisionRef: "assistant-r1",
          complete: false,
          operation: { oneofKind: "upsert", upsert: { text: "Running" } },
        },
      ],
    }, botId)

    expect(synced.messages.map((item) => item.state)).toEqual([
      AgentSessionMessageSyncState.CREATED,
      AgentSessionMessageSyncState.CREATED,
    ])
    const stored = await db.select().from(messages).where(eq(messages.chatId, chatId)).orderBy(asc(messages.messageId))
    expect(stored.map((message) => [message.fromId, message.countsAsUnread])).toEqual([
      [ownerId, false],
      [botId, false],
    ])
    const full = (await MessageModel.getMessagesByIds(chatId, stored.map((message) => BigInt(message.messageId))))
      .sort((left, right) => left.messageId - right.messageId)
    expect(full.map((message) => message.agentSession)).toEqual([
      {
        agentSessionId: connected.agentSession!.id,
        provider: AgentSessionProvider.CODEX,
        role: AgentSessionMessageRole.USER,
        relation: AgentSessionMessageRelation.IMPORTED,
      },
      {
        agentSessionId: connected.agentSession!.id,
        provider: AgentSessionProvider.CODEX,
        role: AgentSessionMessageRole.ASSISTANT,
        relation: AgentSessionMessageRelation.IMPORTED,
      },
    ])
  })

  test("parses imported assistant Markdown into Inline rich content", async () => {
    const connected = await connect()
    const synced = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        itemRef: "assistant-rich-item",
        sourceDate: 1_700_000_001n,
        revisionRef: "assistant-rich-r1",
        complete: true,
        operation: {
          oneofKind: "upsert",
          upsert: { text: "**Done**\n\n```sh\nbun test\n```" },
        },
      }],
    }, botId)

    expect(synced.messages[0]?.state).toBe(AgentSessionMessageSyncState.CREATED)
    const message = await MessageModel.getMessage(Number(synced.messages[0]!.messageId), chatId)
    expect(message.text).not.toContain("**")
    expect(message.blockContent).toBeDefined()

    const edited = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        itemRef: "assistant-rich-item",
        sourceDate: 1_700_000_001n,
        revisionRef: "assistant-rich-r2",
        baseRevisionRef: "assistant-rich-r1",
        complete: true,
        operation: { oneofKind: "upsert", upsert: { text: "Plain completion" } },
      }],
    }, botId)
    expect(edited.messages[0]?.state).toBe(AgentSessionMessageSyncState.EDITED)
    const plain = await MessageModel.getMessage(Number(synced.messages[0]!.messageId), chatId)
    expect(plain.text).toBe("Plain completion")
    expect(plain.blockContent?.blocks).toHaveLength(1)
    expect(plain.blockContent?.blocks[0]?.kind.oneofKind).toBe("paragraph")
  })

  test("stores one 90k assistant progress projection", async () => {
    const connected = await connect()
    const text = "x".repeat(90_000)
    const synced = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        itemRef: "assistant-large-progress",
        sourceDate: 1_700_000_001n,
        revisionRef: "assistant-large-r1",
        complete: false,
        operation: { oneofKind: "upsert", upsert: { text } },
      }],
    }, botId)

    expect(synced.messages[0]?.state).toBe(AgentSessionMessageSyncState.CREATED)
    const message = await MessageModel.getMessage(Number(synced.messages[0]!.messageId), chatId)
    expect(message.text).toBe(text)
  })

  test("deduplicates retries and compare-and-swap edits the same assistant row", async () => {
    const connected = await connect()
    const first = {
      role: AgentSessionMessageRole.ASSISTANT,
      itemRef: "stream-item",
      sourceDate: 1_700_000_001n,
      revisionRef: "r1",
      complete: false,
      operation: { oneofKind: "upsert" as const, upsert: { text: "First" } },
    }
    const created = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [first],
    }, botId)
    const retried = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [first],
    }, botId)
    const edited = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [{
        ...first,
        revisionRef: "r2",
        baseRevisionRef: "r1",
        complete: true,
        operation: { oneofKind: "upsert", upsert: { text: "Finished" } },
      }],
    }, botId)

    expect(created.messages[0]?.state).toBe(AgentSessionMessageSyncState.CREATED)
    expect(retried.messages[0]?.state).toBe(AgentSessionMessageSyncState.UNCHANGED)
    expect(edited.messages[0]?.state).toBe(AgentSessionMessageSyncState.EDITED)
    expect(retried.messages[0]?.messageId).toBe(created.messages[0]?.messageId)
    expect(edited.messages[0]?.messageId).toBe(created.messages[0]?.messageId)
    const stored = await db.select().from(messages).where(eq(messages.chatId, chatId))
    expect(stored).toHaveLength(1)
    expect((await MessageModel.getMessage(stored[0]!.messageId, chatId)).text).toBe("Finished")
  })

  test("links a routed teammate prompt without replacing its sender or text", async () => {
    const connected = await connect()
    const [prompt] = await db.insert(messages).values({
      chatId,
      messageId: 1,
      fromId: teammateId,
      text: "Please review this",
    }).returning()
    if (!prompt) throw new Error("prompt not created")
    await db.update(chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chatId))
    await db.insert(botMessageRoutes).values({
      botUserId: botId,
      chatId,
      messageId: 1,
      activationReason: "mention",
      expiresAt: new Date(Date.now() + 60_000),
    })

    const linked = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [{
        role: AgentSessionMessageRole.USER,
        correlationRef: "inline-correlation-1",
        complete: true,
        operation: { oneofKind: "link", link: { messageId: 1n } },
      }],
    }, botId)

    expect(linked.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    const storedPrompt = await MessageModel.getMessage(1, chatId)
    expect(storedPrompt.fromId).toBe(teammateId)
    expect(storedPrompt.text).toBe("Please review this")
    expect(storedPrompt.agentSession).toMatchObject({
      relation: AgentSessionMessageRelation.LINKED,
      role: AgentSessionMessageRole.USER,
    })
    const refs = await db.select().from(agentSessionMessages).where(and(
      eq(agentSessionMessages.agentSessionId, connected.agentSession!.id),
      eq(agentSessionMessages.messageGlobalId, prompt.globalId),
    ))
    expect(refs).toHaveLength(1)
  })

  test("links the owner's live prompt in the bound thread without a delivery route", async () => {
    const connected = await connect()
    await db.insert(messages).values({
      chatId,
      messageId: 1,
      fromId: ownerId,
      text: "Continue my connected session",
    })
    await db.update(chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chatId))

    const linked = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [{
        role: AgentSessionMessageRole.USER,
        correlationRef: "owner-live-correlation",
        complete: false,
        operation: { oneofKind: "link", link: { messageId: 1n } },
      }],
    }, botId)

    expect(linked.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    const storedPrompt = await MessageModel.getMessage(1, chatId)
    expect(storedPrompt.fromId).toBe(ownerId)
    expect(storedPrompt.text).toBe("Continue my connected session")
    expect(storedPrompt.agentSession).toMatchObject({
      relation: AgentSessionMessageRelation.LINKED,
      role: AgentSessionMessageRole.USER,
    })
  })

  test("owner-authorized history adopts a past teammate prompt without a durable route", async () => {
    const connected = await connect()
    const [prompt] = await db.insert(messages).values({
      chatId,
      messageId: 1,
      fromId: teammateId,
      text: "Continue this older request",
    }).returning()
    if (!prompt) throw new Error("prompt not created")
    await db.update(chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chatId))
    const linked = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.USER,
        itemRef: "older-provider-item",
        correlationRef: "older-inline-correlation",
        complete: true,
        operation: { oneofKind: "link", link: { messageId: 1n } },
      }],
    }, botId)

    expect(linked.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    const storedPrompt = await MessageModel.getMessage(1, chatId)
    expect(storedPrompt.fromId).toBe(teammateId)
    expect(storedPrompt.text).toBe("Continue this older request")
    expect(storedPrompt.agentSession).toMatchObject({
      relation: AgentSessionMessageRelation.LINKED,
      role: AgentSessionMessageRole.USER,
    })
  })

  test("history may adopt another bot prompt but rejects the session bot's own row", async () => {
    const connected = await connect()
    const otherBot = await testUtils.createUser(`agent-history-bot-${crypto.randomUUID()}@example.com`)
    await db.update(users).set({ bot: true, botCreatorId: ownerId }).where(eq(users.id, otherBot.id))
    await testUtils.addParticipant(chatId, otherBot.id)
    await db.insert(messages).values([
      {
        chatId,
        messageId: 1,
        fromId: otherBot.id,
        text: "A different agent's prompt",
      },
      {
        chatId,
        messageId: 2,
        fromId: botId,
        text: "The connected agent's own row",
      },
    ])
    await db.update(chats).set({ lastMsgId: 2, messageIdCounter: 2 }).where(eq(chats.id, chatId))

    const adopted = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.USER,
        itemRef: "other-agent-user-item",
        correlationRef: "other-agent-user-correlation",
        complete: true,
        operation: { oneofKind: "link", link: { messageId: 1n } },
      }],
    }, botId)

    expect(adopted.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    expect((await MessageModel.getMessage(1, chatId)).fromId).toBe(otherBot.id)
    await expect(syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.USER,
        itemRef: "self-authored-user-item",
        correlationRef: "self-authored-user-correlation",
        complete: true,
        operation: { oneofKind: "link", link: { messageId: 2n } },
      }],
    }, botId)).rejects.toMatchObject({ code: RealtimeRpcError.Code.MESSAGE_ID_INVALID })
  })

  test("live linking still rejects an expired routed prompt", async () => {
    const connected = await connect()
    await db.insert(messages).values({
      chatId,
      messageId: 1,
      fromId: teammateId,
      text: "Expired live request",
    })
    await db.update(chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chatId))
    await db.insert(botMessageRoutes).values({
      botUserId: botId,
      chatId,
      messageId: 1,
      activationReason: "mention",
      expiresAt: new Date(Date.now() - 60_000),
    })

    await expect(syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [{
        role: AgentSessionMessageRole.USER,
        correlationRef: "expired-inline-correlation",
        complete: false,
        operation: { oneofKind: "link", link: { messageId: 1n } },
      }],
    }, botId)).rejects.toMatchObject({ code: RealtimeRpcError.Code.MESSAGE_ID_INVALID })
  })

  test("live linking rejects an unrouted bot and the session bot even with a route", async () => {
    const connected = await connect()
    const otherBot = await testUtils.createUser(`agent-live-bot-${crypto.randomUUID()}@example.com`)
    await db.update(users).set({ bot: true, botCreatorId: ownerId }).where(eq(users.id, otherBot.id))
    await testUtils.addParticipant(chatId, otherBot.id)
    await db.insert(messages).values([
      {
        chatId,
        messageId: 1,
        fromId: otherBot.id,
        text: "Unrouted other agent prompt",
      },
      {
        chatId,
        messageId: 2,
        fromId: botId,
        text: "The connected agent's own routed row",
      },
    ])
    await db.update(chats).set({ lastMsgId: 2, messageIdCounter: 2 }).where(eq(chats.id, chatId))
    await db.insert(botMessageRoutes).values({
      botUserId: botId,
      chatId,
      messageId: 2,
      activationReason: "mention",
      expiresAt: new Date(Date.now() + 60_000),
    })

    for (const [messageId, correlationRef] of [
      [1n, "unrouted-other-agent"],
      [2n, "routed-session-agent"],
    ] as const) {
      await expect(syncAgentSessionMessages({
        agentSessionId: connected.agentSession!.id,
        mode: AgentSessionSyncMode.LIVE,
        messages: [{
          role: AgentSessionMessageRole.USER,
          correlationRef,
          complete: false,
          operation: { oneofKind: "link", link: { messageId } },
        }],
      }, botId)).rejects.toMatchObject({ code: RealtimeRpcError.Code.MESSAGE_ID_INVALID })
    }
  })

  test("lets two agent bots retain independent references to the same prompt", async () => {
    const first = await connect()
    const secondBot = await testUtils.createUser(`agent-bot-two-${crypto.randomUUID()}@example.com`)
    await db.update(users).set({ bot: true, botCreatorId: ownerId }).where(eq(users.id, secondBot.id))
    await testUtils.addParticipant(chatId, secondBot.id)
    const second = await connectAgentSession({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      botUserId: BigInt(secondBot.id),
      provider: AgentSessionProvider.CLAUDE,
      instanceRef: "claude-installation",
      sessionRef: "claude-session",
    }, ownerId)
    const [prompt] = await db.insert(messages).values({
      chatId,
      messageId: 1,
      fromId: teammateId,
      text: "Ask both agents",
    }).returning()
    if (!prompt) throw new Error("prompt not created")
    await db.update(chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chatId))
    await db.insert(botMessageRoutes).values([
      {
        botUserId: botId,
        chatId,
        messageId: 1,
        activationReason: "mention",
        expiresAt: new Date(Date.now() + 60_000),
      },
      {
        botUserId: secondBot.id,
        chatId,
        messageId: 1,
        activationReason: "mention",
        expiresAt: new Date(Date.now() + 60_000),
      },
    ])
    for (const [agentSessionId, routedBotId, correlationRef] of [
      [first.agentSession!.id, botId, "codex-correlation"],
      [second.agentSession!.id, secondBot.id, "claude-correlation"],
    ] as const) {
      const linked = await syncAgentSessionMessages({
        agentSessionId,
        mode: AgentSessionSyncMode.LIVE,
        messages: [{
          role: AgentSessionMessageRole.USER,
          correlationRef,
          complete: false,
          operation: { oneofKind: "link", link: { messageId: 1n } },
        }],
      }, routedBotId)
      expect(linked.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    }
    expect(await db.select().from(agentSessionMessages).where(eq(
      agentSessionMessages.messageGlobalId,
      prompt.globalId,
    ))).toHaveLength(2)
  })

  test("links the bot response and enriches it from later provider history", async () => {
    const connected = await connect()
    const [response] = await db.insert(messages).values({
      chatId,
      messageId: 1,
      fromId: botId,
      text: "Review complete",
    }).returning()
    if (!response) throw new Error("response not created")
    await db.update(chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chatId))

    const linked = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        correlationRef: "inline-agent-output:v1:turn-1",
        complete: true,
        operation: { oneofKind: "link", link: { messageId: 1n } },
      }],
    }, botId)
    const repaired = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        itemRef: "provider-assistant-item",
        correlationRef: "inline-agent-output:v1:turn-1",
        sourceDate: 1_700_000_001n,
        revisionRef: "provider-r1",
        complete: true,
        operation: { oneofKind: "upsert", upsert: { text: "Review complete" } },
      }],
    }, botId)

    expect(linked.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    expect(repaired.messages[0]?.state).toBe(AgentSessionMessageSyncState.UNCHANGED)
    const stored = await MessageModel.getMessage(1, chatId)
    expect(stored.fromId).toBe(botId)
    expect(stored.text).toBe("Review complete")
    expect(stored.agentSession).toMatchObject({
      relation: AgentSessionMessageRelation.LINKED,
      role: AgentSessionMessageRole.ASSISTANT,
    })
  })

  test("recovers an already-sent assistant row by its durable bot random ID", async () => {
    const connected = await connect()
    const assistantRandomId = 8_000_000_000_000_000_001n
    const [response] = await db.insert(messages).values({
      chatId,
      messageId: 1,
      fromId: botId,
      randomId: assistantRandomId,
      text: "Already delivered",
    }).returning()
    if (!response) throw new Error("response not created")
    await db.update(chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chatId))

    const repaired = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        itemRef: "provider-assistant-item",
        correlationRef: "inline-agent-output:v1:turn-crash",
        sourceDate: 1_700_000_001n,
        revisionRef: "provider-r1",
        complete: true,
        operation: {
          oneofKind: "upsert",
          upsert: { text: "Already delivered", assistantRandomId },
        },
      }],
    }, botId)

    expect(repaired.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    expect(repaired.messages[0]?.messageId).toBe(1n)
    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(1)
    expect((await MessageModel.getMessage(1, chatId)).agentSession).toMatchObject({
      relation: AgentSessionMessageRelation.LINKED,
      role: AgentSessionMessageRole.ASSISTANT,
    })
  })

  test("deduplicates when assistant history wins the race with the ordinary bot send", async () => {
    const connected = await connect()
    const projected = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        itemRef: "provider-race-item",
        correlationRef: "inline-agent-output:v1:turn-race",
        sourceDate: 1_700_000_001n,
        revisionRef: "provider-r1",
        complete: true,
        operation: {
          oneofKind: "upsert",
          upsert: { text: "Race-safe output", assistantRandomId: 778n },
        },
      }],
    }, botId)
    const messageId = projected.messages[0]?.messageId
    expect(projected.messages[0]?.state).toBe(AgentSessionMessageSyncState.CREATED)
    expect(messageId).toBeDefined()
    const [stored] = await db.select().from(messages).where(eq(messages.chatId, chatId))
    expect(stored?.randomId).toBe(778n)

    const adopted = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.LIVE,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        correlationRef: "inline-agent-output:v1:turn-race",
        complete: true,
        operation: { oneofKind: "link", link: { messageId: messageId! } },
      }],
    }, botId)

    expect(adopted.messages[0]?.state).toBe(AgentSessionMessageSyncState.LINKED)
    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(1)
    expect((await MessageModel.getMessage(Number(messageId), chatId)).agentSession).toMatchObject({
      relation: AgentSessionMessageRelation.LINKED,
    })
  })

  test("promotes item-only identity to correlation without duplicating later replays", async () => {
    const connected = await connect()
    const base = {
      role: AgentSessionMessageRole.ASSISTANT,
      itemRef: "provider-item",
      sourceDate: 1_700_000_001n,
      revisionRef: "provider-r1",
      complete: true,
      operation: { oneofKind: "upsert" as const, upsert: { text: "Stable output" } },
    }
    const created = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [base],
    }, botId)
    const enriched = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{ ...base, correlationRef: "turn-correlation" }],
    }, botId)
    const itemOnlyReplay = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [base],
    }, botId)
    const replayed = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{ ...base, itemRef: undefined, correlationRef: "turn-correlation" }],
    }, botId)

    expect(created.messages[0]?.state).toBe(AgentSessionMessageSyncState.CREATED)
    expect(enriched.messages[0]?.state).toBe(AgentSessionMessageSyncState.UNCHANGED)
    expect(itemOnlyReplay.messages[0]?.state).toBe(AgentSessionMessageSyncState.UNCHANGED)
    expect(replayed.messages[0]?.state).toBe(AgentSessionMessageSyncState.UNCHANGED)
    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(1)
    expect(await db.select().from(agentSessionMessages)).toHaveLength(1)
  })

  test("promotes tombstone identity so correlation-only replay cannot resurrect it", async () => {
    const connected = await connect()
    const base = {
      role: AgentSessionMessageRole.ASSISTANT,
      itemRef: "provider-deleted-item",
      sourceDate: 1_700_000_001n,
      revisionRef: "provider-r1",
      complete: true,
      operation: { oneofKind: "upsert" as const, upsert: { text: "Deleted output" } },
    }
    const created = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [base],
    }, botId)
    const [stored] = await db.select().from(messages).where(eq(messages.chatId, chatId))
    expect(created.messages[0]?.state).toBe(AgentSessionMessageSyncState.CREATED)
    expect(stored).toBeDefined()
    await MessageModel.deleteMessages([BigInt(stored!.messageId)], chatId)

    const enriched = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{ ...base, correlationRef: "deleted-turn-correlation" }],
    }, botId)
    const replayed = await syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{ ...base, itemRef: undefined, correlationRef: "deleted-turn-correlation" }],
    }, botId)

    expect(enriched.messages[0]?.state).toBe(AgentSessionMessageSyncState.TOMBSTONED)
    expect(replayed.messages[0]?.state).toBe(AgentSessionMessageSyncState.TOMBSTONED)
    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(0)
    expect(await db.select().from(agentSessionMessages)).toHaveLength(1)
  })

  test("returns the canonical thread when the same external session is already connected", async () => {
    const first = await connect()
    const recovered = await getAgentSession({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      botUserId: BigInt(botId),
    }, ownerId)
    expect(recovered.connection).toMatchObject({
      instanceRef: "codex-installation",
      sessionRef: "codex-session",
      projectRef: "inline-public",
    })
    const secondChat = await testUtils.createChat(null, "Other thread", "thread", false, ownerId)
    if (!secondChat) throw new Error("second chat not created")
    await Promise.all([
      testUtils.addParticipant(secondChat.id, ownerId),
      testUtils.addParticipant(secondChat.id, botId),
    ])

    const second = await connectAgentSession({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(secondChat.id) } } },
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "codex-session",
    }, ownerId)

    expect(second.state).toBe(ConnectAgentSessionState.CONNECTED_ELSEWHERE)
    expect(second.agentSession?.id).toBe(first.agentSession?.id)
    const canonicalPeer = second.agentSession?.peerId
    expect(canonicalPeer?.type.oneofKind).toBe("chat")
    if (canonicalPeer?.type.oneofKind === "chat") {
      expect(canonicalPeer.type.chat.chatId).toBe(BigInt(chatId))
    }

    const lookup = await connectAgentSession({
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "codex-session",
    }, ownerId)
    expect(lookup.state).toBe(ConnectAgentSessionState.ALREADY_CONNECTED)
    expect(lookup.agentSession?.id).toBe(first.agentSession?.id)
  })

  test("returns the authoritative parent for reply-thread session recovery", async () => {
    const parent = await testUtils.createChat(null, "Parent thread", "thread", false, ownerId)
    if (!parent) throw new Error("parent chat not created")
    await db.update(chats).set({ parentChatId: parent.id }).where(eq(chats.id, chatId))

    const connected = await connect()
    expect(connected.agentSession?.parentChatId).toBe(BigInt(parent.id))
    const lookup = await connectAgentSession({
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "codex-session",
      projectRef: "inline-public",
    }, ownerId)
    expect(lookup.agentSession?.parentChatId).toBe(BigInt(parent.id))
  })

  test("keeps the first project identity immutable across reconnects and lookups", async () => {
    await connect()

    const mismatched = {
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "codex-session",
      projectRef: "different-project",
    }
    await expect(connectAgentSession({
      ...mismatched,
      peerId: { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } },
    }, ownerId)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    await expect(connectAgentSession(mismatched, ownerId)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })

    const recovered = await getAgentSession({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      botUserId: BigInt(botId),
    }, ownerId)
    expect(recovered.connection?.projectRef).toBe("inline-public")
  })

  test("rejects provider timestamps outside the JavaScript Date range", async () => {
    const connected = await connect()
    await expect(syncAgentSessionMessages({
      agentSessionId: connected.agentSession!.id,
      mode: AgentSessionSyncMode.HISTORY,
      messages: [{
        role: AgentSessionMessageRole.ASSISTANT,
        itemRef: "invalid-date-item",
        sourceDate: 8_640_000_000_001n,
        revisionRef: "invalid-date-r1",
        complete: true,
        operation: { oneofKind: "upsert", upsert: { text: "Invalid timestamp" } },
      }],
    }, botId)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("canonical lookup misses without creating or reserving a session", async () => {
    const lookup = await connectAgentSession({
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "missing-session",
    }, ownerId)

    expect(lookup.state).toBe(ConnectAgentSessionState.UNSPECIFIED)
    expect(lookup.agentSession).toBeUndefined()
    expect(await db.select().from(agentSessions)).toHaveLength(0)
  })

  test("allows public threads in normal spaces but rejects internet-public spaces", async () => {
    const normalSpace = await testUtils.createSpace("Agent normal space")
    if (!normalSpace) throw new Error("normal space not created")
    await db.insert(members).values([
      { spaceId: normalSpace.id, userId: ownerId, role: "member" },
      { spaceId: normalSpace.id, userId: botId, role: "member" },
    ])
    const normalThread = await testUtils.createChat(
      normalSpace.id,
      "Visible normal-space thread",
      "thread",
      true,
      ownerId,
    )
    if (!normalThread) throw new Error("normal thread not created")
    const normal = await connectAgentSession({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(normalThread.id) } } },
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "normal-space-session",
    }, ownerId)
    expect(normal.state).toBe(ConnectAgentSessionState.CREATED)
    await db.update(spaces).set({ isPublic: true }).where(eq(spaces.id, normalSpace.id))
    await expect(connectAgentSession({
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "normal-space-session",
    }, ownerId)).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })

    const internetSpace = await testUtils.createSpace("Agent internet space")
    if (!internetSpace) throw new Error("internet space not created")
    await db.update(spaces).set({ isPublic: true }).where(eq(spaces.id, internetSpace.id))
    await db.insert(members).values([
      { spaceId: internetSpace.id, userId: ownerId, role: "member" },
      { spaceId: internetSpace.id, userId: botId, role: "member" },
    ])
    const internetThread = await testUtils.createChat(
      internetSpace.id,
      "Internet-public thread",
      "thread",
      true,
      ownerId,
    )
    if (!internetThread) throw new Error("internet thread not created")
    await expect(connectAgentSession({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(internetThread.id) } } },
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "internet-space-session",
    }, ownerId)).rejects.toBeDefined()
  })
})
