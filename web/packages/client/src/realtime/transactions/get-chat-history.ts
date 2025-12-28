import type { GetChatHistoryInput, InputPeer, RpcCall, RpcResult } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import { upsertMessage } from "./mappers"
import { Query, type Transaction } from "./transaction"
import { toBigInt } from "./helpers"

export type GetChatHistoryContext = {
  peerId?: InputPeer
  offsetId?: number
  limit?: number
}

export class GetChatHistoryTransaction implements Transaction<GetChatHistoryContext> {
  readonly method = Method.GET_CHAT_HISTORY
  readonly kind = Query()
  readonly context: GetChatHistoryContext

  constructor(context: GetChatHistoryContext) {
    this.context = context
  }

  input(context: GetChatHistoryContext) {
    const payload: GetChatHistoryInput = {
      peerId: context.peerId,
      offsetId: toBigInt(context.offsetId),
      limit: context.limit,
    }

    const input: RpcCall["input"] = { oneofKind: "getChatHistory", getChatHistory: payload }
    return input
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChatHistory") {
      throw new Error("invalid")
    }

    db.batch(() => {
      for (const message of result.getChatHistory.messages) {
        upsertMessage(db, message)
      }
    })
  }
}

export const getChatHistory = (context: GetChatHistoryContext) => new GetChatHistoryTransaction(context)
