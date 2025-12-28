import type { DeleteReactionInput, InputPeer, RpcCall, RpcResult } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type DeleteReactionContext = {
  emoji: string
  messageId: number
  peerId?: InputPeer
}

export class DeleteReactionTransaction implements Transaction<DeleteReactionContext> {
  readonly method = Method.DELETE_REACTION
  readonly kind = Mutation()
  readonly context: DeleteReactionContext

  constructor(context: DeleteReactionContext) {
    this.context = context
  }

  input(context: DeleteReactionContext) {
    const payload: DeleteReactionInput = {
      emoji: context.emoji,
      messageId: BigInt(context.messageId),
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "deleteReaction", deleteReaction: payload }
    return input
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "deleteReaction") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.deleteReaction.updates)
  }
}

export const deleteReaction = (context: DeleteReactionContext) => new DeleteReactionTransaction(context)
