import { Method, type InputPeer, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import type { DialogNotificationMode } from "../../database/models"
import { applyUpdates } from "../updates"
import { protocolDialogNotificationMode } from "../updates/dialog-state"
import { prepareDialogField, rollbackDialogField, setDialogField, type DialogFieldContext } from "./dialog-field"
import { Mutation, type Transaction } from "./transaction"

export type UpdateDialogNotificationSettingsContext = DialogFieldContext<"notificationMode"> & {
  peerId: InputPeer
  /** Absent: the chat follows the account's settings. */
  mode?: DialogNotificationMode
}

/**
 * `UPDATE_DIALOG_NOTIFICATION_SETTINGS`. Setting the same mode twice is
 * harmless, so a lost acknowledgement retries. Not in the realtime outbox's
 * registry: the core host keeps it durable itself (`host/durable.ts`).
 */
export class UpdateDialogNotificationSettingsTransaction
  implements Transaction<UpdateDialogNotificationSettingsContext>
{
  readonly method = Method.UPDATE_DIALOG_NOTIFICATION_SETTINGS
  readonly kind = Mutation({ retryAfterTransportLoss: true, retryAfterAck: true })

  constructor(readonly context: UpdateDialogNotificationSettingsContext) {}

  input(context: UpdateDialogNotificationSettingsContext): RpcCall["input"] {
    const notificationSettings = protocolDialogNotificationMode(context.mode)
    return {
      oneofKind: "updateDialogNotificationSettings",
      updateDialogNotificationSettings: {
        peerId: context.peerId,
        ...(notificationSettings ? { notificationSettings } : {}),
      },
    }
  }

  prepare(db: Db) {
    prepareDialogField(db, this.context, "notificationMode")
  }

  optimistic(db: Db) {
    this.prepare(db)
    setDialogField(db, this.context.peerId, "notificationMode", this.context.mode)
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "updateDialogNotificationSettings") throw new Error("invalid")
    applyUpdates(db, result.updateDialogNotificationSettings.updates)
  }

  failed(_error: unknown, db: Db) {
    rollbackDialogField(db, this.context, "notificationMode", this.context.mode)
  }
}

export const updateDialogNotificationSettings = (context: UpdateDialogNotificationSettingsContext) =>
  new UpdateDialogNotificationSettingsTransaction(context)
