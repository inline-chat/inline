import type {
  InputPeer,
  ReadMessagesInput,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import {
  compareInlineIds,
  messageId,
  protocolId,
  type MessageID,
} from "@inline/ids"
import type { Db } from "../../database"
import { certifiedReadMaxId } from "../../database/history-coverage"
import { DbObjectKind } from "../../database/models"
import { TransactionErrors, TransactionFailure } from "./transaction-errors"
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
  context: ReadMessagesContext

  constructor(context: ReadMessagesContext) {
    this.context = context
  }

  /**
   * Read state never advances across a hole (invariant 5, InlineKit's
   * `certifiedReadMaxID`). Once a chat has certified history, the requested
   * frontier is cut at the first uncertified ID after the current one; the
   * cut value is what is persisted and sent. A chat with no coverage yet
   * (an older replica, nothing paged) is read as asked.
   */
  beforeExecute(db: Db) {
    const maxId = this.context.maxId
    if (maxId == null) return
    const dialog = dialogForPeer(db, this.context.peerId)
    if (!dialog) return
    const ranges = db.historyCoverage(dialog.chatId)
    if (ranges.length === 0) return
    const current = dialog.readMaxId == null ? 0n : BigInt(dialog.readMaxId)
    const requested = BigInt(maxId)
    if (requested <= current) return
    const certified = certifiedReadMaxId(ranges, current, requested)
    if (certified != null) {
      this.context = { ...this.context, maxId: messageId(certified) }
      return
    }
    if (dialog.readMaxId == null) {
      throw new TransactionFailure(TransactionErrors.invalid())
    }
    // Nothing certified past the frontier: keep it where it is.
    this.context = { ...this.context, maxId: dialog.readMaxId }
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
