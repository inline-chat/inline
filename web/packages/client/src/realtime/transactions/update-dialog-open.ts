import type {
  InputPeer,
  RpcCall,
  RpcResult,
  UpdateDialogOpenInput,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { chatId } from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { dialogForPeer } from "./dialog-for-peer"
import {
  chatCreatedBlocker,
  Mutation,
  type Transaction,
} from "./transaction"
import {
  upsertChat,
  upsertDialog,
  upsertUser,
} from "./mappers"
import {
  applyDialogIntentResult,
  failDialogIntent,
  hasOtherDialogIntent,
  nextDialogIntentId,
  registerDialogIntent,
  snapshotDialogIntent,
  type DialogIntentSnapshot,
} from "./dialog-intent"

const openIntentFields = [
  "open",
  "order",
  "archived",
  "chatListHidden",
] as const

export type UpdateDialogOpenContext = {
  peerId: InputPeer
  open: boolean
  order?: string
  intentId?: number
  previousState?: DialogIntentSnapshot | null
  optimisticState?: DialogIntentSnapshot
  optimisticOrder?: string
  requiresChatCreated?: boolean
}

export class UpdateDialogOpenTransaction
  implements Transaction<UpdateDialogOpenContext>
{
  readonly method = Method.UPDATE_DIALOG_OPEN
  readonly kind = Mutation({
    retryAfterTransportLoss: true,
    retryAfterAck: true,
  })
  readonly persistence = {
    type: "update_dialog_open",
    replayPolicy: "idempotent" as const,
  }
  readonly context: UpdateDialogOpenContext

  constructor(context: UpdateDialogOpenContext) {
    this.context = {
      ...context,
      intentId: context.intentId ?? nextDialogIntentId(),
    }
  }

  get blockers() {
    if (
      this.context.requiresChatCreated !== true ||
      this.context.peerId.type.oneofKind !== "chat"
    ) {
      return []
    }
    return [
      chatCreatedBlocker(
        chatId(this.context.peerId.type.chat.chatId),
      ),
    ]
  }

  input(context: UpdateDialogOpenContext) {
    const payload: UpdateDialogOpenInput = {
      peerId: context.peerId,
      open: context.open,
      order: context.order,
    }
    const input: RpcCall["input"] = {
      oneofKind: "updateDialogOpen",
      updateDialogOpen: payload,
    }
    return input
  }

  prepare(db: Db) {
    if (
      Object.prototype.hasOwnProperty.call(
        this.context,
        "previousState",
      )
    ) {
      return
    }
    const dialog = dialogForPeer(db, this.context.peerId)
    this.context.previousState = dialog
      ? snapshotDialogIntent(dialog, openIntentFields)
      : null
    this.context.optimisticOrder = this.context.open
      ? dialog?.order ??
        this.context.order ??
        `~local:${this.context.intentId}`
      : undefined
    if (dialog) {
      this.context.optimisticState = snapshotDialogIntent(
        {
          ...dialog,
          open: this.context.open,
          archived: this.context.open ? false : dialog.archived,
          chatListHidden: this.context.open
            ? undefined
            : dialog.chatListHidden,
          order: this.context.open
            ? this.context.optimisticOrder
            : undefined,
        },
        openIntentFields,
      )
    }
  }

  optimistic(db: Db) {
    this.prepare(db)
    registerDialogIntent(
      db,
      this.context.peerId,
      this.context.intentId!,
      openIntentFields,
    )
    const dialog = dialogForPeer(db, this.context.peerId)
    if (!dialog) return

    db.replace({
      ...dialog,
      open: this.context.open,
      archived: this.context.open ? false : dialog.archived,
      chatListHidden: this.context.open
        ? undefined
        : dialog.chatListHidden,
      order: this.context.open
        ? this.context.optimisticOrder
        : undefined,
    })
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "updateDialogOpen") {
      throw new Error("invalid")
    }

    const response = result.updateDialogOpen
    if (response.user) upsertUser(db, response.user)
    if (response.chat) upsertChat(db, response.chat)

    if (response.deletedChat) {
      const hasOtherIntent = hasOtherDialogIntent(
        db,
        this.context.peerId,
        this.context.intentId!,
      )
      applyDialogIntentResult(
        db,
        this.context.peerId,
        this.context.intentId!,
        openIntentFields,
        () => undefined,
      )
      if (hasOtherIntent || this.context.peerId.type.oneofKind !== "chat") return
      const deletedChatId = chatId(this.context.peerId.type.chat.chatId)
      db.clearMessagesForChat(deletedChatId)
      const dialog = dialogForPeer(db, this.context.peerId)
      if (dialog) db.delete(db.ref(DbObjectKind.Dialog, dialog.id))
      db.delete(db.ref(DbObjectKind.Chat, deletedChatId))
      return
    }

    if (!response.chat || !response.dialog) {
      throw new Error("invalid")
    }
    applyDialogIntentResult(
      db,
      this.context.peerId,
      this.context.intentId!,
      openIntentFields,
      () => upsertDialog(db, response.dialog!),
    )
  }

  failed(_error: unknown, db: Db) {
    failDialogIntent(
      db,
      this.context.peerId,
      this.context.intentId!,
      openIntentFields,
      this.context.previousState,
      this.context.optimisticState,
    )
  }
}

export const updateDialogOpen = (
  context: Omit<
    UpdateDialogOpenContext,
    "intentId" | "previousState" | "optimisticState" | "optimisticOrder"
  >,
) => new UpdateDialogOpenTransaction(context)
