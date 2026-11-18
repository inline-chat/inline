import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { ChatID } from "@inline/ids"
import type { Db } from "../../database"
import { chatParticipantGroupKey, chatParticipantKey, DbObjectKind } from "../../database/models"
import type { ChatParticipantTarget } from "./add-chat-participant"
import { Mutation, type Transaction } from "./transaction"

export type RemoveChatParticipantContext = { chatId: ChatID } & ChatParticipantTarget

/**
 * `REMOVE_CHAT_PARTICIPANT` for one person or one user group. The target
 * state is "not a participant", so it is retried after a lost acknowledgement;
 * the server refuses a second removal ("not a participant"), which then
 * settles as a refusal although the person is gone. Not in the realtime
 * outbox's registry: the core host keeps it durable (`host/participants.ts`).
 *
 * Optimistic: the grant row goes. A refusal does not put it back (the server
 * may have removed it after all); it marks the chat's roster incomplete so the
 * next reader fetches the authoritative list.
 */
export class RemoveChatParticipantTransaction implements Transaction<RemoveChatParticipantContext> {
  readonly method = Method.REMOVE_CHAT_PARTICIPANT
  readonly kind = Mutation({ retryAfterTransportLoss: true, retryAfterAck: true })

  constructor(readonly context: RemoveChatParticipantContext) {}

  input(context: RemoveChatParticipantContext): RpcCall["input"] {
    return {
      oneofKind: "removeChatParticipant",
      removeChatParticipant: {
        chatId: BigInt(context.chatId),
        ...(context.userId != null ? { userId: BigInt(context.userId) } : {}),
        ...(context.groupId != null ? { groupId: BigInt(context.groupId) } : {}),
      },
    }
  }

  optimistic(db: Db) {
    const { chatId } = this.context
    const ref =
      this.context.userId != null
        ? db.ref(DbObjectKind.ChatParticipant, chatParticipantKey(chatId, this.context.userId))
        : db.ref(DbObjectKind.ChatParticipantGroup, chatParticipantGroupKey(chatId, this.context.groupId!))
    if (db.get(ref)) db.delete(ref)
  }

  apply(result: RpcResult["result"] | undefined) {
    if (!result || result.oneofKind !== "removeChatParticipant") throw new Error("invalid")
    // The removal is already on the device; the chat bucket's
    // `participantDelete` follows through sync.
  }

  failed(_error: unknown, db: Db) {
    const chat = db.get(db.ref(DbObjectKind.Chat, this.context.chatId))
    if (chat && chat.participantRosterComplete !== false) {
      db.replace({ ...chat, participantRosterComplete: false })
    }
  }
}

export const removeChatParticipant = (context: RemoveChatParticipantContext) =>
  new RemoveChatParticipantTransaction(context)
