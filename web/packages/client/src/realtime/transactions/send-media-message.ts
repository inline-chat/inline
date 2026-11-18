import type { InputMedia, InputPeer, MessageEntities, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { ChatID, MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { toBigInt } from "./helpers"
import { Mutation, type Transaction } from "./transaction"

export type SendMediaMessageContext = {
  chatId: ChatID
  peerId: InputPeer
  randomId: bigint
  temporaryMessageId: MessageID
  temporarySendDate: number
  media: InputMedia
  text?: string
  entities?: MessageEntities
  replyToMsgId?: MessageID
}

/**
 * `SEND_MESSAGE` with uploaded media. The server deduplicates by random ID,
 * so a resend after a lost acknowledgement, a dropped connection or a
 * restart lands once. No optimistic step and no outbox row: the core host
 * commits the optimistic row and keeps the send durable in its own record
 * (`host/attachments.ts`) until the upload it waits for is done.
 */
export class SendMediaMessageTransaction implements Transaction<SendMediaMessageContext> {
  readonly method = Method.SEND_MESSAGE
  readonly kind = Mutation({ retryAfterTransportLoss: true, retryAfterAck: true })
  readonly messageWindowIntent

  constructor(readonly context: SendMediaMessageContext) {
    this.messageWindowIntent = { type: "promote-latest" as const, chatId: context.chatId }
  }

  input(context: SendMediaMessageContext): RpcCall["input"] {
    return {
      oneofKind: "sendMessage",
      sendMessage: {
        peerId: context.peerId,
        randomId: context.randomId,
        ...(context.text ? { message: context.text } : {}),
        ...(context.replyToMsgId ? { replyToMsgId: toBigInt(context.replyToMsgId) } : {}),
        temporarySendDate: BigInt(context.temporarySendDate),
        media: context.media,
        ...(context.entities ? { entities: context.entities } : {}),
      },
    }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "sendMessage") throw new Error("invalid")
    applyUpdates(db, result.sendMessage.updates)
  }
}

export const sendMediaMessage = (context: SendMediaMessageContext) => new SendMediaMessageTransaction(context)
