import type { ChatID, MessageID } from "@inline/ids"
import type { Db } from "../database"
import {
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type Message,
  type PendingTransaction,
} from "../database/models"
import { DbQueryPlanType } from "../database/types"
import { SendMessageTransaction } from "./transactions/send-message"
import { decodePendingTransaction } from "./transactions/transaction-registry"

export class MessageResendUnavailable extends Error {
  constructor(message: string) {
    super(message)
    this.name = "MessageResendUnavailable"
  }
}

export type FailedMessageResend = {
  message: Message
  outbox: PendingTransaction
  transaction: SendMessageTransaction
}

/**
 * Resolve one failed local message back to its sole durable send transaction.
 * Message IDs are chat-scoped and randomId is the server idempotency identity;
 * all three identities must agree before a resend is allowed.
 */
export const failedMessageResend = (
  db: Db,
  chatId: ChatID,
  messageId: MessageID,
): FailedMessageResend => {
  const message = db.get(
    db.ref(
      DbObjectKind.Message,
      messageKey(chatId, messageId),
    ),
  )
  if (
    !message ||
    !message.out ||
    message.status !== MessageSendingStatus.Failed ||
    message.randomId == null
  ) {
    throw new MessageResendUnavailable(
      "Inline failed message is no longer available to resend",
    )
  }

  const matches = db
    .queryCollection<
      DbObjectKind.PendingTransaction,
      PendingTransaction,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
      (record) => record.status === "failed" && record.type === "send_message",
    )
    .flatMap((outbox) => {
      const transaction = decodePendingTransaction(outbox)
      if (!(transaction instanceof SendMessageTransaction)) return []
      const context = transaction.context
      return context.chatId === chatId &&
        context.temporaryMessageId === messageId &&
        context.randomId === message.randomId
        ? [{ message, outbox, transaction }]
        : []
    })

  if (matches.length !== 1) {
    throw new MessageResendUnavailable(
      matches.length === 0
        ? "Inline failed message has no durable send to resend"
        : "Inline failed message has ambiguous durable sends",
    )
  }
  return matches[0]!
}

/** Must run inside the database commit that makes the resend durable. */
export const stageFailedMessageResend = (
  db: Db,
  resend: FailedMessageResend,
) => {
  const current = failedMessageResend(
    db,
    resend.message.chatId,
    resend.message.messageId,
  )
  if (current.outbox.id !== resend.outbox.id) {
    throw new MessageResendUnavailable(
      "Inline failed message changed before it could be resent",
    )
  }
  db.replace({
    ...current.outbox,
    status: "pending",
  })
  db.replace({
    ...current.message,
    status: MessageSendingStatus.Sending,
  })
}
