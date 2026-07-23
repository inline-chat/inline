import type { InputPeer, MarkAsUnreadInput, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { dialogForPeer } from "./dialog-for-peer"
import { Mutation, type Transaction } from "./transaction"

export type MarkAsUnreadContext = {
  peerId?: InputPeer
}

export class MarkAsUnreadTransaction implements Transaction<MarkAsUnreadContext> {
  readonly method = Method.MARK_AS_UNREAD
  readonly kind = Mutation({
    retryAfterTransportLoss: true,
    retryAfterAck: true,
  })
  readonly persistence = {
    type: "mark_as_unread",
    replayPolicy: "idempotent" as const,
  }
  readonly context: MarkAsUnreadContext

  constructor(context: MarkAsUnreadContext) {
    this.context = context
  }

  input(context: MarkAsUnreadContext) {
    const payload: MarkAsUnreadInput = {
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "markAsUnread", markAsUnread: payload }
    return input
  }

  optimistic(db: Db) {
    if (!this.context.peerId) return
    const dialog = dialogForPeer(db, this.context.peerId)
    if (dialog) db.replace({ ...dialog, unreadMark: true })
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "markAsUnread") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.markAsUnread.updates)
  }
}

export const markAsUnread = (context: MarkAsUnreadContext) => new MarkAsUnreadTransaction(context)
