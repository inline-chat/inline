import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { DbObjectKind, type UserSettings } from "../../database/models"
import { applyUpdates } from "../updates/apply-updates"
import {
  patchUserSettings,
  protocolUserSettings,
  readUserSettings,
  userSettingsRef,
  type UserSettingsPatch,
} from "../updates/settings"
import { Mutation, type Transaction } from "./transaction"

export type UpdateUserSettingsContext = {
  patch: UserSettingsPatch
  /** The stored settings before the optimistic patch, for rollback. */
  previous?: UserSettings | null
}

/**
 * `UPDATE_USER_SETTINGS`. The server merges the patch and answers with an
 * `updateUserSettings` carrying the whole merged settings, which replaces
 * the optimistic value. Sending the same patch twice is harmless, so a lost
 * acknowledgement retries; it is not in the durable outbox.
 */
export class UpdateUserSettingsTransaction
  implements Transaction<UpdateUserSettingsContext>
{
  readonly method = Method.UPDATE_USER_SETTINGS
  readonly kind = Mutation({ retryAfterTransportLoss: true, retryAfterAck: true })

  constructor(readonly context: UpdateUserSettingsContext) {}

  input(context: UpdateUserSettingsContext): RpcCall["input"] {
    return {
      oneofKind: "updateUserSettings",
      updateUserSettings: { userSettings: protocolUserSettings(context.patch) },
    }
  }

  prepare(db: Db) {
    if (this.context.previous !== undefined) return
    this.context.previous = readUserSettings(db) ?? null
  }

  optimistic(db: Db) {
    this.prepare(db)
    db.replace(patchUserSettings(readUserSettings(db), this.context.patch))
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "updateUserSettings") {
      throw new Error("invalid")
    }
    applyUpdates(db, result.updateUserSettings.updates)
  }

  failed(_error: unknown, db: Db) {
    const previous = this.context.previous
    if (previous) db.replace(previous)
    else if (previous === null && db.get(userSettingsRef(db))) {
      db.delete(db.ref(DbObjectKind.UserSettings, 0))
    }
  }
}

export const updateUserSettings = (patch: UserSettingsPatch) =>
  new UpdateUserSettingsTransaction({ patch })
