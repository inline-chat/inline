import type { DeleteMessagesInput, InputPeer, RpcCall, RpcResult } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import type { AuthStore } from "../../auth"
import { DbObjectKind } from "../../database/models"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type DeleteMessagesContext = {
  messageIds: number[]
  peerId?: InputPeer
}

export class DeleteMessagesTransaction implements Transaction<DeleteMessagesContext> {
  readonly method = Method.DELETE_MESSAGES
  readonly kind = Mutation()
  readonly context: DeleteMessagesContext

  constructor(context: DeleteMessagesContext) {
    this.context = context
  }

  input(context: DeleteMessagesContext) {
    const payload: DeleteMessagesInput = {
      messageIds: context.messageIds.map((id) => BigInt(id)),
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "deleteMessages", deleteMessages: payload }
    return input
  }

  async optimistic(db: Db, _auth: AuthStore) {
    for (const id of this.context.messageIds) {
      db.delete(db.ref(DbObjectKind.Message, id))
    }
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "deleteMessages") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.deleteMessages.updates)
  }
}

export const deleteMessages = (context: DeleteMessagesContext) => new DeleteMessagesTransaction(context)
