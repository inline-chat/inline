import {
  DialogFollowMode,
  Method,
  type InputPeer,
  type RpcCall,
  type RpcResult,
  type UpdateDialogFollowModeInput,
} from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
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

export type DialogFollowModeSelection =
  | "relevance"
  | "following"
  | "unfollowed"

export type UpdateDialogFollowModeContext = {
  peerId: InputPeer
  selection: DialogFollowModeSelection
  intentId?: number
  previousState?: DialogIntentSnapshot | null
  optimisticState?: DialogIntentSnapshot
  optimisticOrder?: string
}

export const protocolFollowMode = (
  selection: DialogFollowModeSelection,
) => {
  switch (selection) {
    case "relevance":
      return undefined
    case "following":
      return DialogFollowMode.FOLLOWING
    case "unfollowed":
      return DialogFollowMode.UNFOLLOWED
  }
}

/** Web counterpart of InlineKit UpdateDialogFollowModeTransaction. */
export class UpdateDialogFollowModeTransaction
  implements Transaction<UpdateDialogFollowModeContext>
{
  readonly method = Method.UPDATE_DIALOG_FOLLOW_MODE
  readonly kind = Mutation({
    retryAfterTransportLoss: true,
    retryAfterAck: true,
  })
  readonly persistence = {
    type: "update_dialog_follow_mode",
    replayPolicy: "idempotent" as const,
  }
  readonly context: UpdateDialogFollowModeContext

  constructor(context: UpdateDialogFollowModeContext) {
    this.context = {
      ...context,
      intentId: context.intentId ?? nextDialogIntentId(),
    }
  }

  private intentFields(): readonly DialogIntentField[] {
    return this.context.selection === "following"
      ? ["followMode", "open", "order", "archived", "chatListHidden"]
      : ["followMode"]
  }

  private optimisticDialog(dialog: NonNullable<ReturnType<typeof dialogForPeer>>) {
    const following = this.context.selection === "following"
    return {
      ...dialog,
      followMode: protocolFollowMode(this.context.selection),
      ...(following
        ? {
            open: true,
            order: this.context.optimisticOrder,
            archived: false,
            chatListHidden: undefined,
          }
        : {}),
    }
  }

  input(context: UpdateDialogFollowModeContext) {
    const payload: UpdateDialogFollowModeInput = {
      peerId: context.peerId,
      followMode: protocolFollowMode(context.selection),
    }
    const input: RpcCall["input"] = {
      oneofKind: "updateDialogFollowMode",
      updateDialogFollowMode: payload,
    }
    return input
  }

  prepare(db: Db) {
    if (Object.prototype.hasOwnProperty.call(this.context, "previousState")) return
    const dialog = dialogForPeer(db, this.context.peerId)
    this.context.previousState = dialog
      ? snapshotDialogIntent(dialog, this.intentFields())
      : null
    if (this.context.selection === "following") {
      this.context.optimisticOrder =
        dialog?.order ?? `~local:follow:${this.context.intentId}`
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
    if (!result || result.oneofKind !== "updateDialogFollowMode") {
      throw new Error("invalid")
    }
    for (const update of result.updateDialogFollowMode.updates) {
      if (update.update.oneofKind === "dialogFollowMode") {
        const followMode = update.update.dialogFollowMode.followMode
        applyDialogIntentResult(
          db,
          this.context.peerId,
          this.context.intentId!,
          ["followMode"],
          () => {
            const dialog = dialogForPeer(db, this.context.peerId)
            if (dialog) {
              db.replace({
                ...dialog,
                followMode,
              })
            } else {
              applyUpdates(db, [update])
            }
          },
        )
      } else if (update.update.oneofKind === "chatOpen") {
        const { user, chat, dialog } = update.update.chatOpen
        if (user) upsertUser(db, user)
        if (chat) upsertChat(db, chat)
        if (dialog) {
          applyDialogIntentResult(
            db,
            this.context.peerId,
            this.context.intentId!,
            this.intentFields(),
            () => upsertDialog(db, dialog),
          )
        } else {
          applyUpdates(db, [update])
        }
      } else {
        applyUpdates(db, [update])
      }
    }
    applyDialogIntentResult(
      db,
      this.context.peerId,
      this.context.intentId!,
      this.intentFields(),
      () => undefined,
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

export const updateDialogFollowMode = (
  context: Omit<
    UpdateDialogFollowModeContext,
    "intentId" | "previousState" | "optimisticState" | "optimisticOrder"
  >,
) => new UpdateDialogFollowModeTransaction(context)
