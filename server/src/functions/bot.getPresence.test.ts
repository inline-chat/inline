import { describe, expect, spyOn, test } from "bun:test"
import { getBotPresence } from "./bot.getPresence"
import {
  defaultTestContext,
  setupTestLifecycle,
  testUtils,
} from "@in/server/__tests__/setup"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db, schema } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { setBotPresenceStateFn } from "./bot.setPresenceState"
import { BotPresenceState_Kind } from "@inline-chat/protocol/core"
import { RealtimeUpdates } from "@in/server/realtime/message"

describe("getBotPresence", () => {
  setupTestLifecycle()

  test("maps a missing chat peer to a client error", async () => {
    const user = await testUtils.createUser(
      "bot-presence-missing-chat@example.com",
    )
    if (!user) throw new Error("User not created")

    await expect(
      getBotPresence(
        {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 9_999_999n },
            },
          },
        },
        {
          currentUserId: user.id,
          currentSessionId: defaultTestContext.sessionId,
        },
      ),
    ).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
      codeNumber: 400,
    })
  })

  test("identifies a bot without requiring an avatar", async () => {
    const human = await testUtils.createUser("bot-presence-human@example.com")
    const bot = await testUtils.createUser("bot-presence-no-avatar@example.com")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    await testUtils.createPrivateChat(human, bot)

    const result = await getBotPresence(
      {
        peerId: {
          type: {
            oneofKind: "user",
            user: { userId: BigInt(bot.id) },
          },
        },
      },
      {
        currentUserId: human.id,
        currentSessionId: defaultTestContext.sessionId,
      },
    )

    expect(result.botUserId).toBe(BigInt(bot.id))
    expect(result.avatar).toBeUndefined()
    expect(result.state?.kind).toBe(BotPresenceState_Kind.IDLE)
  })

  test("allows a bot without an avatar to publish presence", async () => {
    const human = await testUtils.createUser("bot-presence-publish-human@example.com")
    const bot = await testUtils.createUser("bot-presence-publish-no-avatar@example.com")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    await testUtils.createPrivateChat(human, bot)

    await expect(setBotPresenceStateFn(
      {
        peerId: {
          type: {
            oneofKind: "user",
            user: { userId: BigInt(human.id) },
          },
        },
        state: { kind: BotPresenceState_Kind.RUNNING },
      },
      {
        currentUserId: bot.id,
        currentSessionId: defaultTestContext.sessionId,
      },
    )).resolves.toEqual({})
  })

  test("allows a bot to set and clear presence for the correct inherited DM reply-thread recipient", async () => {
    const human = await testUtils.createUser("bot-presence-dm-reply-human@example.com")
    const bot = await testUtils.createUser("bot-presence-dm-reply-bot@example.com")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    const parent = await testUtils.createPrivateChat(human, bot)
    if (!parent) throw new Error("Parent direct message not created")
    await db.insert(schema.messages).values({
      chatId: parent.id,
      messageId: 1,
      fromId: human.id,
      text: "Reply-thread anchor",
    })
    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        publicThread: false,
        parentChatId: parent.id,
        parentMessageId: 1,
        createdBy: human.id,
      })
      .returning()
    if (!replyThread) throw new Error("Reply thread not created")

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      const peerId = {
        type: {
          oneofKind: "chat" as const,
          chat: { chatId: BigInt(replyThread.id) },
        },
      }
      for (const kind of [BotPresenceState_Kind.RUNNING, BotPresenceState_Kind.IDLE]) {
        await expect(setBotPresenceStateFn(
          {
            peerId,
            state: { kind },
          },
          {
            currentUserId: bot.id,
            currentSessionId: defaultTestContext.sessionId,
          },
        )).resolves.toEqual({})
      }

      expect(push).toHaveBeenCalledTimes(2)
      expect(push.mock.calls.map(([userId]) => userId)).toEqual([human.id, human.id])
      expect(push.mock.calls.map(([, updates]) => updates[0]?.update)).toEqual([
        {
          oneofKind: "botPresence",
          botPresence: {
            botUserId: BigInt(bot.id),
            peerId,
            state: { kind: BotPresenceState_Kind.RUNNING },
            avatarChanged: false,
          },
        },
        {
          oneofKind: "botPresence",
          botPresence: {
            botUserId: BigInt(bot.id),
            peerId,
            state: { kind: BotPresenceState_Kind.IDLE },
            avatarChanged: false,
          },
        },
      ])
    } finally {
      push.mockRestore()
    }
  })

  test("publishes inherited Space reply-thread presence to the correct parent participants", async () => {
    const { space, users: [human, bot] } = await testUtils.createSpaceWithMembers(
      "Bot presence reply thread",
      ["bot-presence-thread-reply-human@example.com", "bot-presence-thread-reply-bot@example.com"],
    )
    if (!space || !human || !bot) throw new Error("Space fixture not created")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    const parent = await testUtils.createChat(space.id, "Parent thread", "thread", false, human.id)
    if (!parent) throw new Error("Parent thread not created")
    await testUtils.addParticipant(parent.id, human.id)
    await testUtils.addParticipant(parent.id, bot.id)
    await db.insert(schema.messages).values({
      chatId: parent.id,
      messageId: 1,
      fromId: human.id,
      text: "Reply-thread anchor",
    })
    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        publicThread: false,
        parentChatId: parent.id,
        parentMessageId: 1,
        createdBy: human.id,
      })
      .returning()
    if (!replyThread) throw new Error("Reply thread not created")

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      const peerId = {
        type: {
          oneofKind: "chat" as const,
          chat: { chatId: BigInt(replyThread.id) },
        },
      }
      await expect(setBotPresenceStateFn(
        {
          peerId,
          state: { kind: BotPresenceState_Kind.RUNNING },
        },
        {
          currentUserId: bot.id,
          currentSessionId: defaultTestContext.sessionId,
        },
      )).resolves.toEqual({})

      expect(push).toHaveBeenCalledTimes(1)
      expect(push).toHaveBeenCalledWith(human.id, [
        {
          update: {
            oneofKind: "botPresence",
            botPresence: {
              botUserId: BigInt(bot.id),
              peerId,
              state: { kind: BotPresenceState_Kind.RUNNING },
              avatarChanged: false,
            },
          },
        },
      ])
    } finally {
      push.mockRestore()
    }
  })

  test("rejects reply-thread presence when the bot cannot access the parent", async () => {
    const human = await testUtils.createUser("bot-presence-reply-owner@example.com")
    const bot = await testUtils.createUser("bot-presence-reply-outsider@example.com")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    const parent = await testUtils.createChat(null, "Restricted parent", "thread", false, human.id)
    if (!parent) throw new Error("Parent thread not created")
    await testUtils.addParticipant(parent.id, human.id)
    await db.insert(schema.messages).values({
      chatId: parent.id,
      messageId: 1,
      fromId: human.id,
      text: "Reply-thread anchor",
    })
    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        publicThread: false,
        parentChatId: parent.id,
        parentMessageId: 1,
        createdBy: human.id,
      })
      .returning()
    if (!replyThread) throw new Error("Reply thread not created")

    await expect(setBotPresenceStateFn(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(replyThread.id) },
          },
        },
        state: { kind: BotPresenceState_Kind.RUNNING },
      },
      {
        currentUserId: bot.id,
        currentSessionId: defaultTestContext.sessionId,
      },
    )).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
      codeNumber: 400,
    })
  })

  test("rejects inherited reply-thread presence after Space membership is revoked", async () => {
    const { space, users: [human, bot] } = await testUtils.createSpaceWithMembers(
      "Revoked bot presence reply thread",
      ["bot-presence-revoked-human@example.com", "bot-presence-revoked-bot@example.com"],
    )
    if (!space || !human || !bot) throw new Error("Space fixture not created")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    const parent = await testUtils.createChat(space.id, "Revoked parent", "thread", false, human.id)
    if (!parent) throw new Error("Parent thread not created")
    await testUtils.addParticipant(parent.id, human.id)
    await testUtils.addParticipant(parent.id, bot.id)
    await db.insert(schema.messages).values({
      chatId: parent.id,
      messageId: 1,
      fromId: human.id,
      text: "Reply-thread anchor",
    })
    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        publicThread: false,
        parentChatId: parent.id,
        parentMessageId: 1,
        createdBy: human.id,
      })
      .returning()
    if (!replyThread) throw new Error("Reply thread not created")

    await db.delete(schema.members).where(
      and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, bot.id)),
    )

    await expect(setBotPresenceStateFn(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(replyThread.id) },
          },
        },
        state: { kind: BotPresenceState_Kind.RUNNING },
      },
      {
        currentUserId: bot.id,
        currentSessionId: defaultTestContext.sessionId,
      },
    )).rejects.toMatchObject({
      code: RealtimeRpcError.Code.SPACE_ID_INVALID,
      codeNumber: 400,
    })
  })
})
