import type { CreateChatInput, InputChatParticipant, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import {
  parseInlineId,
  type ChatID,
  type SpaceID,
} from "@inline/ids"
import type { AuthStore } from "../../auth"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import {
  getDialogId,
  upsertChat,
  upsertDialog,
} from "./mappers"
import {
  chatCreatedBlocker,
  Mutation,
  type Transaction,
  type TransactionKind,
} from "./transaction"
import { toBigInt } from "./helpers"

export type CreateChatContext = {
  title?: string
  spaceId?: SpaceID
  description?: string
  emoji?: string
  isPublic: boolean
  participants?: InputChatParticipant[]
  reservedChatId?: ChatID
  /** Set only inside the atomic outbox recipe before context is persisted. */
  reservationClaimed?: boolean
}

export class CreateChatTransaction implements Transaction<CreateChatContext> {
  readonly method = Method.CREATE_CHAT
  readonly kind: TransactionKind
  readonly persistence?: {
    type: "create_chat"
    replayPolicy: "idempotent"
  }
  readonly context: CreateChatContext

  constructor(
    context: CreateChatContext,
    options: { restored?: boolean } = {},
  ) {
    this.context = options.restored
      ? context
      : { ...context, reservationClaimed: undefined }
    if (this.context.reservedChatId != null) {
      this.kind = Mutation({
        retryAfterTransportLoss: true,
        retryAfterAck: true,
      })
      this.persistence = {
        type: "create_chat",
        replayPolicy: "idempotent",
      }
    } else {
      this.kind = Mutation()
    }
  }

  input(context: CreateChatContext) {
    const title = context.title?.trim()
    const payload: CreateChatInput = {
      title: title || undefined,
      spaceId: toBigInt(context.spaceId),
      description: context.description,
      emoji: context.emoji,
      isPublic: context.isPublic,
      participants: context.participants ?? [],
      ...(context.reservedChatId != null
        ? { reservedChatId: toBigInt(context.reservedChatId) }
        : {}),
    }

    const input: RpcCall["input"] = { oneofKind: "createChat", createChat: payload }
    return input
  }

  get satisfiedBlockersOnSuccess() {
    return this.context.reservedChatId == null
      ? []
      : [chatCreatedBlocker(this.context.reservedChatId)]
  }

  prepare(db: Db) {
    const reservedChatId = this.context.reservedChatId
    if (reservedChatId == null || this.context.reservationClaimed === true) {
      return
    }
    const reservation = db.get(
      db.ref(DbObjectKind.ReservedChatID, reservedChatId),
    )
    const nowSeconds = Math.floor(Date.now() / 1_000)
    if (
      !reservation ||
      reservation.chatId !== reservedChatId ||
      reservation.expiresAt <= nowSeconds
    ) {
      throw new Error("Reserved chat ID is unavailable or expired")
    }
    db.delete(db.ref(DbObjectKind.ReservedChatID, reservedChatId))
    this.context.reservationClaimed = true
  }

  optimistic(db: Db, auth: AuthStore) {
    const reservedChatId = this.context.reservedChatId
    if (reservedChatId == null) return
    const title = this.context.title?.trim() || undefined
    const currentUserId = auth.getState().currentUserId ?? undefined
    db.replace({
      kind: DbObjectKind.Chat,
      id: reservedChatId,
      title,
      spaceId: this.context.spaceId,
      description: this.context.description,
      emoji: this.context.emoji,
      isPublic: this.context.isPublic,
      date: Math.floor(Date.now() / 1_000),
      createdBy: currentUserId,
      untitled: title == null ? true : undefined,
      createState: "pending",
    })
    const dialogId = getDialogId({ peerThreadId: reservedChatId })
    if (db.get(db.ref(DbObjectKind.Dialog, dialogId))) return
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId,
      chatId: reservedChatId,
      peerThreadId: reservedChatId,
      spaceId: this.context.spaceId,
      open: false,
    })
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "createChat") {
      throw new Error("invalid")
    }

    const { chat, dialog } = result.createChat
    if (
      !chat ||
      !dialog ||
      dialog.chatId !== chat.id ||
      dialog.peer?.type.oneofKind !== "chat" ||
      dialog.peer.type.chat.chatId !== chat.id
    ) {
      throw new Error("invalid")
    }

    const exactChatId = parseInlineId<"chat">(chat.id, {
      positive: true,
    })
    if (exactChatId == null) throw new Error("invalid")
    if (
      this.context.reservedChatId != null &&
      exactChatId !== this.context.reservedChatId
    ) {
      throw new Error("invalid")
    }

    upsertChat(db, chat)
    upsertDialog(db, dialog)
    if (this.context.reservedChatId != null) {
      const stored = db.get(db.ref(DbObjectKind.Chat, exactChatId))
      if (!stored) throw new Error("invalid")
      db.replace({ ...stored, createState: undefined })
    }
  }

  failed(_error: unknown, db: Db) {
    const reservedChatId = this.context.reservedChatId
    if (
      reservedChatId == null ||
      this.context.reservationClaimed !== true
    ) {
      return
    }
    const existing = db.get(db.ref(DbObjectKind.Chat, reservedChatId))
    if (!existing) return
    db.replace({ ...existing, createState: "failed" })
  }
}

export const createChat = (context: CreateChatContext) => new CreateChatTransaction(context)
