import type { GetChatHistoryInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import {
  GetChatHistoryMode,
  Method,
} from "@inline-chat/protocol/core"
import type { MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { upsertMessage } from "./mappers"
import { Query, type Transaction } from "./transaction"
import { toBigInt } from "./helpers"

export type GetChatHistoryContext = {
  peerId?: InputPeer
  limit?: number
  mode?: GetChatHistoryMode
  beforeId?: MessageID
  afterId?: MessageID
  anchorId?: MessageID
  beforeLimit?: number
  afterLimit?: number
  includeAnchor?: boolean
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
      limit: context.limit,
      mode: context.mode,
      beforeId: toBigInt(context.beforeId),
      afterId: toBigInt(context.afterId),
      anchorId: toBigInt(context.anchorId),
      beforeLimit: context.beforeLimit,
      afterLimit: context.afterLimit,
      includeAnchor: context.includeAnchor,
    }

    const input: RpcCall["input"] = { oneofKind: "getChatHistory", getChatHistory: payload }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
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

export { GetChatHistoryMode }
