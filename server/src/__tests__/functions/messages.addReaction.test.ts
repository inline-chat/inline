import { describe, expect, test } from "bun:test"
import { addReaction } from "@in/server/functions/messages.addReaction"
import { RealtimeRpcError } from "@in/server/realtime/errors"

describe("addReaction", () => {
  test("rejects arbitrary non-emoji strings before resolving the target chat", async () => {
    await expect(addReaction(
      {
        emoji: "not-an-emoji",
        messageId: 1n,
        peer: { type: { oneofKind: "chat", chat: { chatId: 1n } } },
      },
      { currentUserId: 1, currentSessionId: 1 },
    )).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })
})
