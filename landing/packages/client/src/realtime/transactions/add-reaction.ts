import type { AddReactionInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type AddReactionContext = {
  emoji: string
  messageId: number
  peerId?: InputPeer
}

export class AddReactionTransaction implements Transaction<AddReactionContext> {
  readonly method = Method.ADD_REACTION
  readonly kind = Mutation()
  readonly context: AddReactionContext

  constructor(context: AddReactionContext) {
    this.context = context
  }

  input(context: AddReactionContext) {
    const payload: AddReactionInput = {
      emoji: context.emoji,
      messageId: BigInt(context.messageId),
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "addReaction", addReaction: payload }
    return input
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "addReaction") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.addReaction.updates)
  }
}

export const addReaction = (context: AddReactionContext) => new AddReactionTransaction(context)
