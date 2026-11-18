import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { ChatID, UserID } from "@inline/ids"
import type { Db } from "../../database"
import {
  chatParticipantGroupKey,
  chatParticipantKey,
  DbObjectKind,
  type UserGroupID,
} from "../../database/models"
import { putUserGroup, saveParticipant, saveParticipantGroup } from "../updates/membership"
import { upsertUser } from "./mappers"
import { Mutation, type Transaction } from "./transaction"

/** Exactly one of `userId` and `groupId`. */
export type ChatParticipantTarget = { userId: UserID; groupId?: never } | { groupId: UserGroupID; userId?: never }

export type AddChatParticipantContext = {
  chatId: ChatID
  /** Seconds since the epoch: the optimistic grant's date. */
  date: number
  /** Whether the grant was already on the device before this add (rollback keeps it). */
  existed?: boolean
} & ChatParticipantTarget

const grantRef = (db: Db, context: AddChatParticipantContext) =>
  context.userId != null
    ? db.ref(DbObjectKind.ChatParticipant, chatParticipantKey(context.chatId, context.userId))
    : db.ref(DbObjectKind.ChatParticipantGroup, chatParticipantGroupKey(context.chatId, context.groupId!))

/**
 * `ADD_CHAT_PARTICIPANT` for one person or one user group. The server adds
 * idempotently (an existing participant is answered as it is), so a retry
 * after a lost acknowledgement is harmless. Not in the realtime outbox's
 * registry: the core host keeps it durable itself (`host/participants.ts`).
 *
 * Optimistic: the grant row, when the chat and the person (or group) are on
 * the device; a refusal removes it again unless it was there before.
 */
export class AddChatParticipantTransaction implements Transaction<AddChatParticipantContext> {
  readonly method = Method.ADD_CHAT_PARTICIPANT
  readonly kind = Mutation({ retryAfterTransportLoss: true, retryAfterAck: true })

  constructor(readonly context: AddChatParticipantContext) {}

  input(context: AddChatParticipantContext): RpcCall["input"] {
    return {
      oneofKind: "addChatParticipant",
      addChatParticipant: {
        chatId: BigInt(context.chatId),
        ...(context.userId != null ? { userId: BigInt(context.userId) } : {}),
        ...(context.groupId != null ? { groupId: BigInt(context.groupId) } : {}),
      },
    }
  }

  prepare(db: Db) {
    if (this.context.existed === undefined) {
      this.context.existed = db.get(grantRef(db, this.context)) != null
    }
  }

  optimistic(db: Db) {
    const { chatId, date } = this.context
    if (!db.get(db.ref(DbObjectKind.Chat, chatId)) || db.get(grantRef(db, this.context))) return
    if (this.context.userId != null) {
      const userId = this.context.userId
      if (!db.get(db.ref(DbObjectKind.User, userId))) return
      db.replace({
        kind: DbObjectKind.ChatParticipant,
        id: chatParticipantKey(chatId, userId),
        chatId,
        userId,
        date,
      })
    } else {
      const groupId = this.context.groupId!
      if (!db.get(db.ref(DbObjectKind.UserGroup, groupId))) return
      db.replace({
        kind: DbObjectKind.ChatParticipantGroup,
        id: chatParticipantGroupKey(chatId, groupId),
        chatId,
        groupId,
        date,
      })
    }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "addChatParticipant") throw new Error("invalid")
    const { participant, groupParticipant, group, users } = result.addChatParticipant
    db.batch(() => {
      for (const user of users) upsertUser(db, user)
      if (group) putUserGroup(db, group)
      if (participant) saveParticipant(db, this.context.chatId, participant)
      if (groupParticipant) saveParticipantGroup(db, this.context.chatId, groupParticipant)
    })
  }

  failed(_error: unknown, db: Db) {
    if (this.context.existed) return
    const ref = grantRef(db, this.context)
    if (db.get(ref)) db.delete(ref)
  }
}

export const addChatParticipant = (context: AddChatParticipantContext) => new AddChatParticipantTransaction(context)
