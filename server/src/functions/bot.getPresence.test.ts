import { describe, expect, test } from "bun:test"
import { getBotPresence } from "./bot.getPresence"
import {
  defaultTestContext,
  setupTestLifecycle,
  testUtils,
} from "@in/server/__tests__/setup"
import { RealtimeRpcError } from "@in/server/realtime/errors"

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
})
