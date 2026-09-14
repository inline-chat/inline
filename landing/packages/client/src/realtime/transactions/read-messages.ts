import type {
  InputPeer,
  ReadMessagesInput,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import {
  compareInlineIds,
  protocolId,
  type MessageID,
} from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { applyUpdates } from "../updates"
import { dialogForPeer } from "./dialog-for-peer"
import { Mutation, type Transaction } from "./transaction"

export type ReadMessagesContext = {
  peerId: InputPeer
  maxId?: MessageID
}

/**
 * Advances a dialog's read boundary. The server applies max(previous, maxId),
 * making this safe to retry after every transport ambiguity and from the
 * durable outbox.
 */
export class ReadMessagesTransaction
  implements Transaction<ReadMessagesContext>
{
  readonly method = Method.READ_MESSAGES
  readonly kind = Mutation({
    retryAfterTransportLoss: true,
    retryAfterAck: true,
  })
  readonly persistence = {
    type: "read_messages",
    replayPolicy: "idempotent" as const,
  }
  readonly context: ReadMessagesContext

  constructor(context: ReadMessagesContext) {
    this.context = context
  }

  input(context: ReadMessagesContext) {
    const payload: ReadMessagesInput = {
      peerId: context.peerId,
      maxId:
        context.maxId == null
          ? undefined
          : protocolId(context.maxId),
    }
    const input: RpcCall["input"] = {
      oneofKind: "readMessages",
      readMessages: payload,
    }
    return input
  }

  optimistic(db: Db) {
    const dialog = dialogForPeer(db, this.context.peerId)
    if (!dialog) return

    const maxId = this.context.maxId
    const readMaxId =
      maxId != null &&
      (dialog.readMaxId == null ||
        compareInlineIds(maxId, dialog.readMaxId) > 0)
        ? maxId
        : dialog.readMaxId
    const chat = db.get(
      db.ref(DbObjectKind.Chat, dialog.chatId),
    )
    const reachedKnownEnd =
      maxId == null ||
      chat?.lastMsgId == null ||
      compareInlineIds(maxId, chat.lastMsgId) >= 0

    db.replace({
      ...dialog,
      readMaxId,
      unreadCount: reachedKnownEnd ? 0 : dialog.unreadCount,
      unreadMark: false,
    })
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "readMessages") {
      throw new Error("invalid")
    }
    applyUpdates(db, result.readMessages.updates)
  }
}

export const readMessages = (context: ReadMessagesContext) =>
  new ReadMessagesTransaction(context)
