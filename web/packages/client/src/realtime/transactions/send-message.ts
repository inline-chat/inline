import type { InputPeer, MessageEntities, RpcCall, RpcResult, SendMessageInput } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import type { AuthStore } from "../../auth"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"
import { generateTempId, randomBigInt64, toBigInt } from "./helpers"

export type SendMessageContext = {
  text?: string
  peerId?: InputPeer
  chatId: number
  replyToMsgId?: number
  isSticker?: boolean
  entities?: MessageEntities
  randomId?: bigint
  temporaryMessageId?: number
}

export class SendMessageTransaction implements Transaction<SendMessageContext> {
  readonly method = Method.SEND_MESSAGE
  readonly kind = Mutation()
  readonly context: SendMessageContext

  constructor(context: SendMessageContext) {
    this.context = {
      ...context,
      randomId: context.randomId ?? randomBigInt64(),
      temporaryMessageId: context.temporaryMessageId ?? generateTempId(),
    }
  }

  input(context: SendMessageContext) {
    const payload: SendMessageInput = {
      peerId: context.peerId,
      randomId: context.randomId,
      message: context.text ?? undefined,
      replyToMsgId: toBigInt(context.replyToMsgId),
      temporarySendDate: BigInt(Math.floor(Date.now() / 1000)),
      isSticker: context.isSticker,
      entities: context.entities,
    }

    const input: RpcCall["input"] = { oneofKind: "sendMessage", sendMessage: payload }
    return input
  }

  async optimistic(db: Db, auth: AuthStore) {
    const currentUserId = auth.getState().currentUserId
    if (currentUserId == null) return

    const messageId = this.context.temporaryMessageId ?? generateTempId()

    db.insert({
      kind: DbObjectKind.Message,
      id: messageId,
      randomId: this.context.randomId,
      fromId: currentUserId,
      chatId: this.context.chatId,
      message: this.context.text,
      out: true,
      date: Math.floor(Date.now() / 1000),
      replyToMsgId: this.context.replyToMsgId,
      isSticker: this.context.isSticker,
    })

    const chatRef = db.ref(DbObjectKind.Chat, this.context.chatId)
    const chat = db.get(chatRef)
    if (chat) {
      db.update({ ...chat, lastMsgId: messageId })
    }

    // TODO: reflect optimistic sending status and compose actions if needed.
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "sendMessage") {
      throw new Error("invalid")
    }

    applyUpdates(db, result.sendMessage.updates)
  }

  async failed(_error: unknown, _db: Db, _auth: AuthStore): Promise<void> {
    // TODO: mark optimistic message as failed when we track status in the DB.
  }

  async cancelled(db: Db, _auth: AuthStore): Promise<void> {
    const messageId = this.context.temporaryMessageId
    if (messageId == null) return
    db.delete(db.ref(DbObjectKind.Message, messageId))
  }
}

export const sendMessage = (context: SendMessageContext) => new SendMessageTransaction(context)
