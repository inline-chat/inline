import type { AddReactionInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
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

export type AddReactionContext = {
  emoji: string
  chatId: ChatID
  messageId: MessageID
  peerId?: InputPeer
  intentId?: string
}

export class AddReactionTransaction implements Transaction<AddReactionContext> {
  readonly method = Method.ADD_REACTION
  readonly kind = Mutation({ transient: true })
  readonly context: AddReactionContext

  constructor(context: AddReactionContext) {
    this.context = {
      ...context,
      intentId: context.intentId ?? TransactionId.generate(),
    }
  }

  input(context: AddReactionContext) {
    const payload: AddReactionInput = {
      emoji: context.emoji,
      messageId: protocolId(context.messageId),
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "addReaction", addReaction: payload }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "addReaction") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.addReaction.updates)
    clearReactionIntent(db, this.intentContext())
  }

  optimistic(db: Db, auth: AuthStore) {
    applyReactionIntent(db, auth, this.intentContext(), "add")
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

export const addReaction = (context: AddReactionContext) => new AddReactionTransaction(context)
