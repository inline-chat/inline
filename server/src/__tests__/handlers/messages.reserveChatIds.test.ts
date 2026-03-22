import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { HandlerContext } from "../../realtime/types"
import { handleRpcCall } from "../../realtime/handlers/_rpc"
import { Method } from "@inline-chat/protocol/core"

describe("messages.reserveChatIds", () => {
  setupTestLifecycle()

  test("handleRpcCall reserves the requested number of chat ids", async () => {
    const user = await testUtils.createUser("reserve-chat-ids@example.com")

    const handlerContext: HandlerContext = {
      userId: user.id,
      sessionId: defaultTestContext.sessionId,
      connectionId: "reserve-chat-ids-test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const result = await handleRpcCall(
      {
        method: Method.RESERVE_CHAT_IDS,
        input: {
          oneofKind: "reserveChatIds",
          reserveChatIds: {
            count: 2,
          },
        },
      },
      handlerContext,
    )

    expect(result.oneofKind).toBe("reserveChatIds")
    if (result.oneofKind === "reserveChatIds") {
      expect(result.reserveChatIds.reservations).toHaveLength(2)
      expect(new Set(result.reserveChatIds.reservations.map((reservation) => reservation.chatId.toString())).size).toBe(2)
      for (const reservation of result.reserveChatIds.reservations) {
        expect(reservation.expiresAt).toBeGreaterThan(BigInt(0))
      }
    }
  })
})
