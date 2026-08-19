import { describe, expect, test } from "bun:test"
import { getBotPresence } from "./bot.getPresence"
import {
  defaultTestContext,
  setupTestLifecycle,
  testUtils,
} from "@in/server/__tests__/setup"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { setBotPresenceStateFn } from "./bot.setPresenceState"
import { BotPresenceState_Kind } from "@inline-chat/protocol/core"

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
})
