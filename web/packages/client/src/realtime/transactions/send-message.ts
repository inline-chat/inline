import type { InputPeer, MessageEntities, RpcCall, RpcResult, SendMessageInput } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { ChatID, MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind, messageKey, MessageSendingStatus } from "../../database/models"
import type { AuthStore } from "../../auth"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"
import { generateTempId, randomPositiveInt64, toBigInt } from "./helpers"

export type SendMessageContext = {
  text?: string
  peerId?: InputPeer
  chatId: ChatID
  replyToMsgId?: MessageID
  isSticker?: boolean
  entities?: MessageEntities
  randomId?: bigint
  temporaryMessageId?: MessageID
  temporarySendDate?: number
}

export class SendMessageTransaction implements Transaction<SendMessageContext> {
  readonly method = Method.SEND_MESSAGE
  readonly kind = Mutation({
    retryAfterTransportLoss: true,
    retryAfterAck: true,
  })
  readonly persistence = {
    type: "send_message",
    replayPolicy: "idempotent" as const,
  }
  readonly context: SendMessageContext

  constructor(context: SendMessageContext) {
    this.context = {
      ...context,
      randomId: context.randomId ?? randomPositiveInt64(),
      temporaryMessageId: context.temporaryMessageId ?? generateTempId(),
      temporarySendDate:
        context.temporarySendDate ?? Math.floor(Date.now() / 1000),
    }
  }

  input(context: SendMessageContext) {
    const payload: SendMessageInput = {
      peerId: context.peerId,
      randomId: context.randomId,
      message: context.text ?? undefined,
      replyToMsgId: toBigInt(context.replyToMsgId),
      temporarySendDate: toBigInt(context.temporarySendDate),
      isSticker: context.isSticker,
      entities: context.entities,
    }

    const input: RpcCall["input"] = { oneofKind: "sendMessage", sendMessage: payload }
    return input
  }

  optimistic(db: Db, auth: AuthStore) {
    const currentUserId = auth.getState().currentUserId
    if (currentUserId == null) return

    const messageId = this.context.temporaryMessageId ?? generateTempId()
    const sendDate =
      this.context.temporarySendDate ?? Math.floor(Date.now() / 1000)

    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(this.context.chatId, messageId),
      messageId,
      randomId: this.context.randomId,
      fromId: currentUserId,
      chatId: this.context.chatId,
      message: this.context.text,
      out: true,
      date: sendDate,
      replyToMsgId: this.context.replyToMsgId,
      isSticker: this.context.isSticker,
      entities: this.context.entities,
      status: MessageSendingStatus.Sending,
    })

    const chatRef = db.ref(DbObjectKind.Chat, this.context.chatId)
    const chat = db.get(chatRef)
    if (chat) {
      db.update({ ...chat, lastMsgId: messageId, date: sendDate })
    }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "sendMessage") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.sendMessage.updates)
  }

  async failed(_error: unknown, db: Db, _auth: AuthStore): Promise<void> {
    const messageId = this.context.temporaryMessageId
    if (messageId == null) return
    const ref = db.ref(DbObjectKind.Message, messageKey(this.context.chatId, messageId))
    const message = db.get(ref)
    if (message) {
      db.update({
        ...message,
        status: MessageSendingStatus.Failed,
      })
    }
  }

  async cancelled(db: Db, _auth: AuthStore): Promise<void> {
    const messageId = this.context.temporaryMessageId
    if (messageId == null) return
    db.delete(db.ref(DbObjectKind.Message, messageKey(this.context.chatId, messageId)))
  }
}

export const sendMessage = (context: SendMessageContext) => new SendMessageTransaction(context)
