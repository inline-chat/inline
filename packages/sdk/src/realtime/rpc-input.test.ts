import { describe, expect, it } from "vitest"
import { ChatListOrder, ChatListScope, Method, RpcCall } from "@inline-chat/protocol/core"
import { normalizeRpcInput, type RpcInput } from "./rpc-input.js"

const roundTrip = (method: Method, input: RpcInput) =>
  RpcCall.fromBinary(RpcCall.toBinary({ method, input: normalizeRpcInput(method, input) })).input

describe("normalizeRpcInput", () => {
  it("encodes an empty getChats with proto defaults", () => {
    const input = roundTrip(Method.GET_CHATS, { oneofKind: "getChats", getChats: {} })
    if (input.oneofKind !== "getChats") throw new Error("expected getChats")
    expect(input.getChats.order).toBe(ChatListOrder.RECENT)
    expect(input.getChats.scope).toBe(ChatListScope.DIALOGS)
    expect(input.getChats.limit).toBeUndefined()
    expect(input.getChats.includeSubthreads).toBeUndefined()
  })

  it("keeps given fields and optional presence", () => {
    const input = roundTrip(Method.GET_CHATS, {
      oneofKind: "getChats",
      getChats: { limit: 50, scope: ChatListScope.ACCESSIBLE, offset: { chatId: 9n } },
    })
    if (input.oneofKind !== "getChats") throw new Error("expected getChats")
    expect(input.getChats.limit).toBe(50)
    expect(input.getChats.scope).toBe(ChatListScope.ACCESSIBLE)
    expect(input.getChats.order).toBe(ChatListOrder.RECENT)
    expect(input.getChats.offset?.chatId).toBe(9n)
    expect(input.getChats.filter).toBeUndefined()
  })

  it("passes inputless methods through", () => {
    expect(normalizeRpcInput(Method.GET_ME, { oneofKind: undefined })).toEqual({ oneofKind: undefined })
  })
})
