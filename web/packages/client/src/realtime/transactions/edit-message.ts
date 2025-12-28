import type { EditMessageInput, InputPeer, MessageEntities, RpcCall, RpcResult } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import type { AuthStore } from "../../auth"
import { DbObjectKind } from "../../database/models"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type EditMessageContext = {
  messageId: number
  peerId?: InputPeer
  text: string
  entities?: MessageEntities
}

export class EditMessageTransaction implements Transaction<EditMessageContext> {
  readonly method = Method.EDIT_MESSAGE
  readonly kind = Mutation()
  readonly context: EditMessageContext

  constructor(context: EditMessageContext) {
    this.context = context
  }

  input(context: EditMessageContext) {
    const payload: EditMessageInput = {
      messageId: BigInt(context.messageId),
      peerId: context.peerId,
      text: context.text,
      entities: context.entities,
    }

    const input: RpcCall["input"] = { oneofKind: "editMessage", editMessage: payload }
    return input
  }

  async optimistic(db: Db, _auth: AuthStore) {
    const ref = db.ref(DbObjectKind.Message, this.context.messageId)
    const existing = db.get(ref)
    if (!existing) return

    db.update({
      ...existing,
      message: this.context.text,
      editDate: Math.floor(Date.now() / 1000),
    })
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "editMessage") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.editMessage.updates)
  }
}

export const editMessage = (context: EditMessageContext) => new EditMessageTransaction(context)
