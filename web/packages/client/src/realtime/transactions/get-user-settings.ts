import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { applyUserSettings } from "../updates/settings"
import { Query, type Transaction } from "./transaction"

/** `GET_USER_SETTINGS`: the account's settings. */
export class GetUserSettingsTransaction
  implements Transaction<Record<string, never>>
{
  readonly method = Method.GET_USER_SETTINGS
  readonly kind = Query()
  readonly context: Record<string, never> = {}

  input(): RpcCall["input"] {
    return { oneofKind: "getUserSettings", getUserSettings: {} }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getUserSettings") {
      throw new Error("invalid")
    }
    const settings = result.getUserSettings.userSettings
    if (settings) applyUserSettings(db, settings)
  }
}

export const getUserSettings = () => new GetUserSettingsTransaction()
