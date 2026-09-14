import type { PendingTransaction } from "../../database/models"
import {
  CreateChatTransaction,
  type CreateChatContext,
} from "./create-chat"
import {
  SendMessageTransaction,
  type SendMessageContext,
} from "./send-message"
import {
  ReadMessagesTransaction,
  type ReadMessagesContext,
} from "./read-messages"
import {
  MarkAsUnreadTransaction,
  type MarkAsUnreadContext,
} from "./mark-as-unread"
import {
  PinMessageTransaction,
  type PinMessageContext,
} from "./pin-message"
import {
  ShowInChatListTransaction,
  type ShowInChatListContext,
} from "./show-in-chat-list"
import type { Transaction } from "./transaction"
import {
  UpdateDialogOpenTransaction,
  type UpdateDialogOpenContext,
} from "./update-dialog-open"
import {
  UpdateDialogOrderTransaction,
  type UpdateDialogOrderContext,
} from "./update-dialog-order"
import {
  UpdateDialogFollowModeTransaction,
  type UpdateDialogFollowModeContext,
} from "./update-dialog-follow-mode"

export const decodePendingTransaction = (
  record: PendingTransaction,
): Transaction | undefined => {
  if (!record.context || typeof record.context !== "object") return undefined
  if (
    record.replayPolicy != null &&
    record.replayPolicy !== "idempotent"
  ) {
    return undefined
  }

  // This switch is deliberately an allowlist. A legacy row without an
  // explicit replayPolicy is restored only when the server contract for that
  // exact mutation is known to be idempotent.
  switch (record.type) {
    case "create_chat":
      if (
        (record.context as CreateChatContext).reservedChatId == null ||
        (record.context as CreateChatContext).reservationClaimed !== true
      ) {
        return undefined
      }
      return new CreateChatTransaction(
        record.context as CreateChatContext,
        { restored: true },
      )
    case "send_message":
      return new SendMessageTransaction(record.context as SendMessageContext)
    case "show_in_chat_list":
      return new ShowInChatListTransaction(
        record.context as ShowInChatListContext,
      )
    case "update_dialog_open":
      return new UpdateDialogOpenTransaction(
        record.context as UpdateDialogOpenContext,
      )
    case "update_dialog_order":
      return new UpdateDialogOrderTransaction(
        record.context as UpdateDialogOrderContext,
      )
    case "update_dialog_follow_mode":
      return new UpdateDialogFollowModeTransaction(
        record.context as UpdateDialogFollowModeContext,
      )
    case "read_messages":
      return new ReadMessagesTransaction(
        record.context as ReadMessagesContext,
      )
    case "mark_as_unread":
      return new MarkAsUnreadTransaction(
        record.context as MarkAsUnreadContext,
      )
    case "pin_message": {
      const context = record.context as PinMessageContext
      // Pin refreshes server ordering and is not replay-safe. Only the exact
      // idempotent Unpin shape can ever be restored from the durable outbox.
      if (context.unpin !== true) return undefined
      return new PinMessageTransaction(context)
    }
    default:
      return undefined
  }
}
