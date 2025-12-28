import type { GetChatInput, InputPeer, RpcCall, RpcResult } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import { upsertChat, upsertDialog } from "./mappers"
import { Query, type Transaction } from "./transaction"

export type GetChatContext = {
  peerId?: InputPeer
}

export class GetChatTransaction implements Transaction<GetChatContext> {
  readonly method = Method.GET_CHAT
  readonly kind = Query()
  readonly context: GetChatContext

  constructor(context: GetChatContext) {
    this.context = context
  }

  input(context: GetChatContext) {
    const payload: GetChatInput = {
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "getChat", getChat: payload }
    return input
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChat") {
      throw new Error("invalid")
    }

    if (result.getChat.chat) {
      upsertChat(db, result.getChat.chat)
    }
    if (result.getChat.dialog) {
      upsertDialog(db, result.getChat.dialog)
    }
  }
}

export const getChat = (context: GetChatContext) => new GetChatTransaction(context)
