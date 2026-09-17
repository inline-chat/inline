import { describe, expect, it } from "bun:test"
import { Method } from "@inline-chat/protocol/core"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { RealtimeRpcError } from "@in/server/realtime/errors"

describe("RPC authentication boundary", () => {
  it("rejects private reads and mutations before dispatch or database work", async () => {
    for (const method of [Method.SEND_MESSAGE, Method.GET_CHAT_HISTORY, Method.GET_SESSIONS, Method.DELETE_MESSAGES]) {
      await expect(handleRpcCall({ method, input: { oneofKind: undefined } }, {
        userId: 0, sessionId: 0, connectionId: "unauthenticated-test", sendRaw() {}, sendRpcReply() {},
      })).rejects.toMatchObject({ code: RealtimeRpcError.Unauthenticated().code, codeNumber: 401 })
    }
  })
})
