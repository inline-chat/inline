import type {
  InputPeer,
  RpcCall,
  RpcResult,
  UpdateDialogOrderInput,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { dialogForPeer } from "./dialog-for-peer"
import {
  applyDialogIntentResult,
  failDialogIntent,
  nextDialogIntentId,
  registerDialogIntent,
  snapshotDialogIntent,
  type DialogIntentField,
  type DialogIntentSnapshot,
} from "./dialog-intent"
import { upsertChat, upsertDialog, upsertUser } from "./mappers"
import { Mutation, type Transaction } from "./transaction"

export type UpdateDialogOrderContext = {
  peerId: InputPeer
  order?: string
  pinnedOrder?: string
  pinned?: boolean
  intentId?: number
  previousState?: DialogIntentSnapshot | null
  optimisticState?: DialogIntentSnapshot
  optimisticOrder?: string
  optimisticPinnedOrder?: string
}

/** InlineKit UpdateDialogOrderTransaction, including pin lane transitions. */
export class UpdateDialogOrderTransaction
  implements Transaction<UpdateDialogOrderContext>
{
  readonly method = Method.UPDATE_DIALOG_ORDER
  readonly kind = Mutation({
    retryAfterTransportLoss: true,
    retryAfterAck: true,
  })
  readonly persistence = {
    type: "update_dialog_order",
    replayPolicy: "idempotent" as const,
  }
  readonly context: UpdateDialogOrderContext

  constructor(context: UpdateDialogOrderContext) {
    this.context = {
      ...context,
      intentId: context.intentId ?? nextDialogIntentId(),
    }
  }

  private intentFields(): readonly DialogIntentField[] {
    const fields: DialogIntentField[] = []
    if (this.context.order != null) fields.push("order")
    if (this.context.pinnedOrder != null) fields.push("pinnedOrder")
    if (this.context.pinned != null) fields.push("pinned")
    if (this.context.pinned === true) {
      fields.push("open", "order", "pinnedOrder", "archived", "chatListHidden")
    } else if (this.context.pinned === false && this.context.order != null) {
      fields.push("open", "archived", "chatListHidden")
    }
    return Array.from(new Set(fields))
  }

  private optimisticDialog(dialog: NonNullable<ReturnType<typeof dialogForPeer>>) {
    return {
      ...dialog,
      ...(this.context.order != null ? { order: this.context.order } : {}),
      ...(this.context.pinnedOrder != null
        ? { pinnedOrder: this.context.pinnedOrder }
        : {}),
      ...(this.context.pinned == null
        ? {}
        : {
            pinned: this.context.pinned,
            ...(this.context.pinned
              ? {
                  open: true,
                  order: this.context.optimisticOrder,
                  pinnedOrder: this.context.optimisticPinnedOrder,
                  archived: false,
                  chatListHidden: undefined,
                }
              : {}),
          }),
    }
  }

  input(context: UpdateDialogOrderContext) {
    const payload: UpdateDialogOrderInput = {
      peerId: context.peerId,
      order: context.order,
      pinnedOrder: context.pinnedOrder,
      pinned: context.pinned,
    }
    const input: RpcCall["input"] = {
      oneofKind: "updateDialogOrder",
      updateDialogOrder: payload,
    }
    return input
  }

  prepare(db: Db) {
    if (Object.prototype.hasOwnProperty.call(this.context, "previousState")) return
    const dialog = dialogForPeer(db, this.context.peerId)
    this.context.previousState = dialog
      ? snapshotDialogIntent(dialog, this.intentFields())
      : null
    if (this.context.pinned === true) {
      this.context.optimisticOrder =
        this.context.order ?? dialog?.order ?? `~local:pin:${this.context.intentId}`
      this.context.optimisticPinnedOrder =
        this.context.pinnedOrder ??
        dialog?.pinnedOrder ??
        `~local:pinned:${this.context.intentId}`
    }
    if (dialog) {
      this.context.optimisticState = snapshotDialogIntent(
        this.optimisticDialog(dialog),
        this.intentFields(),
      )
    }
  }

  optimistic(db: Db) {
    this.prepare(db)
    registerDialogIntent(
      db,
      this.context.peerId,
      this.context.intentId!,
      this.intentFields(),
    )
    const dialog = dialogForPeer(db, this.context.peerId)
    if (!dialog) return

    db.replace(this.optimisticDialog(dialog))
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "updateDialogOrder") {
      throw new Error("invalid")
    }
    const response = result.updateDialogOrder
    if (!response.chat || !response.dialog) throw new Error("invalid")
    if (response.user) upsertUser(db, response.user)
    upsertChat(db, response.chat)
    applyDialogIntentResult(
      db,
      this.context.peerId,
      this.context.intentId!,
      this.intentFields(),
      () => upsertDialog(db, response.dialog!),
    )
  }

  failed(_error: unknown, db: Db) {
    failDialogIntent(
      db,
      this.context.peerId,
      this.context.intentId!,
      this.intentFields(),
      this.context.previousState,
      this.context.optimisticState,
    )
  }
}

export const updateDialogOrder = (
  context: Omit<
    UpdateDialogOrderContext,
    | "intentId"
    | "previousState"
    | "optimisticState"
    | "optimisticOrder"
    | "optimisticPinnedOrder"
  >,
) => new UpdateDialogOrderTransaction(context)
