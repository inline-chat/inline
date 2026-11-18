import type { EditMessageInput, InputPeer, MessageEntities, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { protocolId, type ChatID, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type EditMessageContext = {
  chatId: ChatID
  messageId: MessageID
  peerId?: InputPeer
  text: string
  entities?: MessageEntities
}

export class EditMessageTransaction implements Transaction<EditMessageContext> {
  readonly method = Method.EDIT_MESSAGE
  // EDIT_MESSAGE has no operation identity in the current protocol. It must
  // not be crash-replayed or retried after an ambiguous transport handoff.
  readonly kind = Mutation({ transient: true })
  readonly context: EditMessageContext

  constructor(context: EditMessageContext) {
    this.context = context
  }

  input(context: EditMessageContext) {
    const payload: EditMessageInput = {
      messageId: protocolId(context.messageId),
      peerId: context.peerId,
      text: context.text,
      entities: context.entities,
    }

    const input: RpcCall["input"] = { oneofKind: "editMessage", editMessage: payload }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "editMessage") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.editMessage.updates)
  }
}

export const editMessage = (context: EditMessageContext) => new EditMessageTransaction(context)
