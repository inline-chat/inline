import type { DeleteMessagesInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { protocolId, type ChatID, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type DeleteMessagesContext = {
  chatId: ChatID
  messageIds: MessageID[]
  peerId?: InputPeer
}

export class DeleteMessagesTransaction implements Transaction<DeleteMessagesContext> {
  readonly method = Method.DELETE_MESSAGES
  // DELETE_MESSAGES fails when the target is already absent, so replay after
  // an ambiguous response is not idempotent in the current server contract.
  readonly kind = Mutation({ transient: true })
  readonly context: DeleteMessagesContext

  constructor(context: DeleteMessagesContext) {
    this.context = context
  }

  input(context: DeleteMessagesContext) {
    const payload: DeleteMessagesInput = {
      messageIds: context.messageIds.map(protocolId),
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "deleteMessages", deleteMessages: payload }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "deleteMessages") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.deleteMessages.updates)
  }
}

export const deleteMessages = (context: DeleteMessagesContext) => new DeleteMessagesTransaction(context)
