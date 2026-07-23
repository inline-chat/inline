import type { DeleteReactionInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { protocolId, type ChatID, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import type { AuthStore } from "../../auth"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"
import { TransactionId } from "./transaction-id"
import {
  applyReactionIntent,
  clearReactionIntent,
} from "./reaction-intent"

export type DeleteReactionContext = {
  emoji: string
  chatId: ChatID
  messageId: MessageID
  peerId?: InputPeer
  intentId?: string
}

export class DeleteReactionTransaction implements Transaction<DeleteReactionContext> {
  readonly method = Method.DELETE_REACTION
  readonly kind = Mutation({ transient: true })
  readonly context: DeleteReactionContext

  constructor(context: DeleteReactionContext) {
    this.context = {
      ...context,
      intentId: context.intentId ?? TransactionId.generate(),
    }
  }

  input(context: DeleteReactionContext) {
    const payload: DeleteReactionInput = {
      emoji: context.emoji,
      messageId: protocolId(context.messageId),
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "deleteReaction", deleteReaction: payload }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "deleteReaction") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.deleteReaction.updates)
    clearReactionIntent(db, this.intentContext())
  }

  optimistic(db: Db, auth: AuthStore) {
    applyReactionIntent(db, auth, this.intentContext(), "delete")
  }

  failed(_error: unknown, db: Db) {
    clearReactionIntent(db, this.intentContext())
  }

  cancelled(db: Db) {
    clearReactionIntent(db, this.intentContext())
  }

  private intentContext() {
    return {
      ...this.context,
      intentId: this.context.intentId!,
    }
  }
}

export const deleteReaction = (context: DeleteReactionContext) => new DeleteReactionTransaction(context)
