import { Method } from "@inline-chat/protocol/core"
import {
  AddReactionTransaction,
  type AddReactionContext,
} from "./add-reaction"
import {
  CreateChatTransaction,
  type CreateChatContext,
} from "./create-chat"
import {
  DeleteMessagesTransaction,
  type DeleteMessagesContext,
} from "./delete-messages"
import {
  DeleteReactionTransaction,
  type DeleteReactionContext,
} from "./delete-reaction"
import {
  EditMessageTransaction,
  type EditMessageContext,
} from "./edit-message"
import {
  GetChatHistoryTransaction,
  type GetChatHistoryContext,
} from "./get-chat-history"
import {
  GetChatTransaction,
  type GetChatContext,
} from "./get-chat"
import { GetChatsTransaction } from "./get-chats"
import { GetMeTransaction } from "./get-me"
import {
  GetMessagesTransaction,
  type GetMessagesContext,
} from "./get-messages"
import {
  MarkAsUnreadTransaction,
  type MarkAsUnreadContext,
} from "./mark-as-unread"
import {
  PinMessageTransaction,
  type PinMessageContext,
} from "./pin-message"
import {
  ReadMessagesTransaction,
  type ReadMessagesContext,
} from "./read-messages"
import {
  SendMessageTransaction,
  type SendMessageContext,
} from "./send-message"
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

export type CoreTransactionEnvelope = {
  method: Method
  context: unknown
}

export class UnsupportedCoreTransaction extends Error {
  constructor(method: Method) {
    super(
      `Transaction ${Method[method] ?? method} is not available through InlineCoreProtocol`,
    )
    this.name = "UnsupportedCoreTransaction"
  }
}

const supportedMethod = (method: Method) => {
  switch (method) {
    case Method.GET_ME:
    case Method.GET_CHATS:
    case Method.GET_CHAT:
    case Method.GET_CHAT_HISTORY:
    case Method.GET_MESSAGES:
    case Method.SHOW_IN_CHAT_LIST:
    case Method.UPDATE_DIALOG_OPEN:
    case Method.UPDATE_DIALOG_ORDER:
    case Method.UPDATE_DIALOG_FOLLOW_MODE:
    case Method.SEND_MESSAGE:
    case Method.EDIT_MESSAGE:
    case Method.DELETE_MESSAGES:
    case Method.MARK_AS_UNREAD:
    case Method.READ_MESSAGES:
    case Method.CREATE_CHAT:
    case Method.ADD_REACTION:
    case Method.DELETE_REACTION:
    case Method.PIN_MESSAGE:
      return true
    default:
      return false
  }
}

export const encodeCoreTransaction = (
  transaction: Transaction,
): CoreTransactionEnvelope => {
  if (!supportedMethod(transaction.method)) {
    throw new UnsupportedCoreTransaction(transaction.method)
  }
  return {
    method: transaction.method,
    context: transaction.context,
  }
}

export const decodeCoreTransaction = (
  envelope: CoreTransactionEnvelope,
): Transaction => {
  switch (envelope.method) {
    case Method.GET_ME:
      return new GetMeTransaction()
    case Method.GET_CHATS:
      return new GetChatsTransaction()
    case Method.GET_CHAT:
      return new GetChatTransaction(
        envelope.context as GetChatContext,
      )
    case Method.GET_CHAT_HISTORY:
      return new GetChatHistoryTransaction(
        envelope.context as GetChatHistoryContext,
      )
    case Method.GET_MESSAGES:
      return new GetMessagesTransaction(
        envelope.context as GetMessagesContext,
      )
    case Method.SHOW_IN_CHAT_LIST:
      return new ShowInChatListTransaction(
        envelope.context as ShowInChatListContext,
      )
    case Method.UPDATE_DIALOG_OPEN:
      return new UpdateDialogOpenTransaction(
        envelope.context as UpdateDialogOpenContext,
      )
    case Method.UPDATE_DIALOG_ORDER:
      return new UpdateDialogOrderTransaction(
        envelope.context as UpdateDialogOrderContext,
      )
    case Method.UPDATE_DIALOG_FOLLOW_MODE:
      return new UpdateDialogFollowModeTransaction(
        envelope.context as UpdateDialogFollowModeContext,
      )
    case Method.SEND_MESSAGE:
      return new SendMessageTransaction(
        envelope.context as SendMessageContext,
      )
    case Method.EDIT_MESSAGE:
      return new EditMessageTransaction(
        envelope.context as EditMessageContext,
      )
    case Method.DELETE_MESSAGES:
      return new DeleteMessagesTransaction(
        envelope.context as DeleteMessagesContext,
      )
    case Method.MARK_AS_UNREAD:
      return new MarkAsUnreadTransaction(
        envelope.context as MarkAsUnreadContext,
      )
    case Method.READ_MESSAGES:
      return new ReadMessagesTransaction(
        envelope.context as ReadMessagesContext,
      )
    case Method.CREATE_CHAT:
      return new CreateChatTransaction(
        envelope.context as CreateChatContext,
      )
    case Method.ADD_REACTION:
      return new AddReactionTransaction(
        envelope.context as AddReactionContext,
      )
    case Method.DELETE_REACTION:
      return new DeleteReactionTransaction(
        envelope.context as DeleteReactionContext,
      )
    case Method.PIN_MESSAGE:
      return new PinMessageTransaction(
        envelope.context as PinMessageContext,
      )
    default:
      throw new UnsupportedCoreTransaction(envelope.method)
  }
}
