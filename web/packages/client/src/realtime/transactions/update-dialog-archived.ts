import { Method, type InputPeer, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { prepareDialogField, rollbackDialogField, setDialogField, type DialogFieldContext } from "./dialog-field"
import { Mutation, type Transaction } from "./transaction"

export type UpdateDialogArchivedContext = DialogFieldContext<"archived"> & {
  peerId: InputPeer
  archived: boolean
}

/**
 * `UPDATE_DIALOG_ARCHIVED`: an explicit target state, so a retry is
 * harmless. Not in the realtime outbox's registry: the core host keeps it
 * durable itself (`host/durable.ts`).
 */
export class UpdateDialogArchivedTransaction implements Transaction<UpdateDialogArchivedContext> {
  readonly method = Method.UPDATE_DIALOG_ARCHIVED
  readonly kind = Mutation({ retryAfterTransportLoss: true, retryAfterAck: true })

  constructor(readonly context: UpdateDialogArchivedContext) {}

  input(context: UpdateDialogArchivedContext): RpcCall["input"] {
    return {
      oneofKind: "updateDialogArchived",
      updateDialogArchived: { peerId: context.peerId, archived: context.archived },
    }
  }

  prepare(db: Db) {
    prepareDialogField(db, this.context, "archived")
  }

  optimistic(db: Db) {
    this.prepare(db)
    setDialogField(db, this.context.peerId, "archived", this.context.archived)
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "updateDialogArchived") throw new Error("invalid")
    applyUpdates(db, result.updateDialogArchived.updates)
  }

  failed(_error: unknown, db: Db) {
    rollbackDialogField(db, this.context, "archived", this.context.archived)
  }
}

export const updateDialogArchived = (context: UpdateDialogArchivedContext) =>
  new UpdateDialogArchivedTransaction(context)
