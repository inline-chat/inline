import type { InputPeer, MarkAsUnreadInput, RpcCall, RpcResult } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type MarkAsUnreadContext = {
  peerId?: InputPeer
}

export class MarkAsUnreadTransaction implements Transaction<MarkAsUnreadContext> {
  readonly method = Method.MARK_AS_UNREAD
  readonly kind = Mutation()
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

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "markAsUnread") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.markAsUnread.updates)
  }
}

export const markAsUnread = (context: MarkAsUnreadContext) => new MarkAsUnreadTransaction(context)
