import {
  Method,
  type InputPeer,
  type PinMessageInput,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import {
  chatId,
  protocolId,
  type MessageID,
} from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind, type Chat } from "../../database/models"
import { applyUpdates } from "../updates"
import { dialogForPeer } from "./dialog-for-peer"
import { Mutation, type Transaction } from "./transaction"

export type PinMessageContext = {
  peerId: InputPeer
  messageId: MessageID
  unpin: boolean
  previousPinnedMessageIds?: MessageID[] | null
  optimisticPinnedMessageIds?: MessageID[]
}

const sameIds = (
  left: readonly MessageID[] | undefined,
  right: readonly MessageID[] | undefined,
) => {
  const first = left ?? []
  const second = right ?? []
  return (
    first.length === second.length &&
    first.every((id, index) => id === second[index])
  )
}

const chatForPeer = (db: Db, peerId: InputPeer): Chat | undefined => {
  const exactChatId =
    peerId.type.oneofKind === "chat"
      ? chatId(peerId.type.chat.chatId)
      : dialogForPeer(db, peerId)?.chatId
  return exactChatId == null
    ? undefined
    : db.get(db.ref(DbObjectKind.Chat, exactChatId))
}

/** Web counterpart of InlineKit's `PinMessageTransaction`.
 *
 * Unpin is replay-safe: removing the same exact message again cannot reorder
 * another pin. Pin is deliberately not durable/retried across ambiguity,
 * because the server refreshes `pinnedAt`; replaying an older Pin after a
 * newer pin could incorrectly move the older message back to the front. */
export class PinMessageTransaction
  implements Transaction<PinMessageContext>
{
  readonly method = Method.PIN_MESSAGE
  readonly kind
  readonly persistence
  readonly context: PinMessageContext

  constructor(context: PinMessageContext) {
    this.context = context
    this.kind = Mutation(
      context.unpin
        ? {
            retryAfterTransportLoss: true,
            retryAfterAck: true,
          }
        : {},
    )
    this.persistence = context.unpin
      ? {
          type: "pin_message",
          replayPolicy: "idempotent" as const,
        }
      : undefined
  }

  input(context: PinMessageContext) {
    const payload: PinMessageInput = {
      peerId: context.peerId,
      messageId: protocolId(context.messageId),
      unpin: context.unpin,
    }
    const input: RpcCall["input"] = {
      oneofKind: "pinMessage",
      pinMessage: payload,
    }
    return input
  }

  prepare(db: Db) {
    if (
      Object.prototype.hasOwnProperty.call(
        this.context,
        "previousPinnedMessageIds",
      )
    ) {
      return
    }
    const chat = chatForPeer(db, this.context.peerId)
    if (!chat) {
      this.context.previousPinnedMessageIds = null
      return
    }
    const previous = [...(chat.pinnedMessageIds ?? [])]
    this.context.previousPinnedMessageIds = previous
    this.context.optimisticPinnedMessageIds = this.context.unpin
      ? previous.filter((id) => id !== this.context.messageId)
      : [
          this.context.messageId,
          ...previous.filter((id) => id !== this.context.messageId),
        ]
  }

  optimistic(db: Db) {
    this.prepare(db)
    if (this.context.previousPinnedMessageIds === null) return
    const chat = chatForPeer(db, this.context.peerId)
    if (!chat || !this.context.optimisticPinnedMessageIds) return
    db.replace({
      ...chat,
      pinnedMessageIds: [...this.context.optimisticPinnedMessageIds],
    })
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "pinMessage") {
      throw new Error("invalid")
    }
    applyUpdates(db, result.pinMessage.updates)
  }

  failed(_error: unknown, db: Db) {
    this.restoreIfCurrent(db)
  }

  cancelled(db: Db) {
    this.restoreIfCurrent(db)
  }

  private restoreIfCurrent(db: Db) {
    const previous = this.context.previousPinnedMessageIds
    const optimistic = this.context.optimisticPinnedMessageIds
    if (previous == null || !optimistic) return
    const chat = chatForPeer(db, this.context.peerId)
    if (!chat || !sameIds(chat.pinnedMessageIds, optimistic)) return
    db.replace({ ...chat, pinnedMessageIds: [...previous] })
  }
}

export const pinMessage = (context: PinMessageContext) =>
  new PinMessageTransaction(context)
