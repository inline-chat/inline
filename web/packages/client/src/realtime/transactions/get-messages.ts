import type { GetMessagesInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { toBigInt } from "./helpers"
import { upsertMessage } from "./mappers"
import { Query, type Transaction } from "./transaction"

export type GetMessagesContext = {
  peerId?: InputPeer
  messageIds: MessageID[]
}

export class GetMessagesTransaction implements Transaction<GetMessagesContext> {
  readonly method = Method.GET_MESSAGES
  readonly kind = Query()
  readonly context: GetMessagesContext

  constructor(context: GetMessagesContext) {
    this.context = context
  }

  input(context: GetMessagesContext) {
    const payload: GetMessagesInput = {
      peerId: context.peerId,
      messageIds: context.messageIds.map((id) => toBigInt(id)!),
    }

    const input: RpcCall["input"] = { oneofKind: "getMessages", getMessages: payload }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getMessages") {
      throw new Error("invalid")
    }

    db.batch(() => {
      for (const message of result.getMessages.messages) {
        upsertMessage(db, message)
      }
    })
  }
}

export const getMessages = (context: GetMessagesContext) => new GetMessagesTransaction(context)
