import { describe, expect, it, spyOn } from "bun:test"
import { Method } from "@inline-chat/protocol/core"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"

describe("RPC authentication boundary", () => {
  it("rejects private reads and mutations before dispatch or database work", async () => {
    for (const method of [Method.SEND_MESSAGE, Method.GET_CHAT_HISTORY, Method.GET_SESSIONS, Method.DELETE_MESSAGES]) {
      await expect(handleRpcCall({ method, input: { oneofKind: undefined } }, {
        userId: 0, sessionId: 0, connectionId: "unauthenticated-test", sendRaw() {}, sendRpcReply() {},
      })).rejects.toMatchObject({ code: RealtimeRpcError.Unauthenticated().code, codeNumber: 401 })
    }
  })

  it("does not re-query an authenticated session before dispatch", async () => {
    const select = spyOn(db, "select")
    try {
      await expect(handleRpcCall({ method: Method.GET_ME, input: { oneofKind: undefined } }, {
        userId: 91_001, sessionId: 92_001, connectionId: "authenticated-no-query", sendRaw() {}, sendRpcReply() {},
      })).rejects.toMatchObject({ code: RealtimeRpcError.BadRequest().code, codeNumber: 400 })

      expect(select).not.toHaveBeenCalled()
    } finally {
      select.mockRestore()
    }
  })
})
