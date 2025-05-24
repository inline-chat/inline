import { getCachedUserSettings } from "@in/server/modules/cache/userSettings"
import type { FunctionContext } from "@in/server/functions/_types"

export interface GetUserSettingsInput {}

export interface GetUserSettingsResult {
  general: import("@in/server/db/models/userSettings/types").UserSettingsGeneral | null
}

export const getUserSettings = async (
  input: GetUserSettingsInput,
  context: FunctionContext,
): Promise<GetUserSettingsResult> => {
  const general = await getCachedUserSettings(context.currentUserId)

  return {
    general,
  }
}
