import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { HandlerContext } from "../../realtime/types"
import { createBot } from "../../functions/createBot"
import { handleRpcCall } from "../../realtime/handlers/_rpc"
import { Method } from "@inline-chat/protocol/core"

describe("bot command rpc handlers", () => {
  setupTestLifecycle()

  let creator: any
  let handlerContext: HandlerContext

  beforeEach(async () => {
    creator = await testUtils.createUser("botcommands-handler@example.com")

    handlerContext = {
      userId: creator.id,
      sessionId: defaultTestContext.sessionId,
      connectionId: "bot-commands-handler-test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }
  })

  test("handleRpcCall dispatches setBotCommands and getBotCommands", async () => {
    const created = await createBot({ name: "RPC Commands Bot", username: "rpccommandstestbot" }, {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    })

    const botUserId = created.bot?.id ?? 0n

    const setResult = await handleRpcCall(
      {
        method: Method.SET_BOT_COMMANDS,
        input: {
          oneofKind: "setBotCommands",
          setBotCommands: {
            botUserId,
            commands: [{ command: "start", description: "Start the bot" }],
          },
        },
      },
      handlerContext,
    )

    expect(setResult.oneofKind).toBe("setBotCommands")

    const getResult = await handleRpcCall(
      {
        method: Method.GET_BOT_COMMANDS,
        input: {
          oneofKind: "getBotCommands",
          getBotCommands: {
            botUserId,
          },
        },
      },
      handlerContext,
    )

    expect(getResult.oneofKind).toBe("getBotCommands")
    if (getResult.oneofKind === "getBotCommands") {
      expect(getResult.getBotCommands.commands.map((command) => command.command)).toEqual(["start"])
    }
  })
})
