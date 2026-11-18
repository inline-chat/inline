import { Method, type InputPeer, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { applyUpdates } from "../updates"
import { dialogForPeer } from "./dialog-for-peer"
import { Mutation, type Transaction } from "./transaction"

export type ReadDialogContext = { peerId: InputPeer }

/**
 * "Mark as Read" from a chat list: `READ_MESSAGES` without `max_id` (the
 * server reads to its latest message) and with `read_activity` (unread
 * mentions and reactions too). Reading is a max, so a retry is harmless. Not
 * in the realtime outbox's registry: the core host keeps it durable itself.
 */
export class ReadDialogTransaction implements Transaction<ReadDialogContext> {
  readonly method = Method.READ_MESSAGES
  readonly kind = Mutation({ retryAfterTransportLoss: true, retryAfterAck: true })

  constructor(readonly context: ReadDialogContext) {}

  input(context: ReadDialogContext): RpcCall["input"] {
    return { oneofKind: "readMessages", readMessages: { peerId: context.peerId, readActivity: true } }
  }

  optimistic(db: Db) {
    const dialog = dialogForPeer(db, this.context.peerId)
    if (!dialog) return
    const chat = db.get(db.ref(DbObjectKind.Chat, dialog.chatId))
    db.replace({
      ...dialog,
      ...(chat?.lastMsgId != null ? { readMaxId: chat.lastMsgId } : {}),
      unreadCount: 0,
      unreadMark: false,
      unreadMentionsCount: 0,
      unreadReactionsCount: 0,
      unreadMentionIds: [],
      unreadReactionIds: [],
    })
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "readMessages") throw new Error("invalid")
    applyUpdates(db, result.readMessages.updates)
  }
}

export const readDialog = (context: ReadDialogContext) => new ReadDialogTransaction(context)
