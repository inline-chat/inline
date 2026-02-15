import APN from "apn"
import { Log } from "@in/server/utils/log"
import { APN_KEY, APN_KEY_ID, APN_TEAM_ID, isProd, isTest } from "@in/server/env"

// Configure APN provider
let apnProvider: APN.Provider | undefined

export const getApnProvider = () => {
  if (isTest) {
    return undefined
  }

  if (!apnProvider) {
    const rawKey = APN_KEY
    const keyId = APN_KEY_ID
    const teamId = APN_TEAM_ID

    if (!rawKey || !keyId || !teamId) {
      Log.shared.warn("APN credentials are missing", {
        hasKey: !!rawKey,
        hasKeyId: !!keyId,
        hasTeamId: !!teamId,
      })
      return undefined
    }

    const key =
      rawKey.includes("BEGIN PRIVATE KEY") ? rawKey.replace(/\\n/g, "\n") : Buffer.from(rawKey, "base64").toString("utf-8")

    try {
      apnProvider = new APN.Provider({
        token: {
          key,
          keyId,
          teamId,
        },
        production: isProd,
      })
    } catch (error) {
      Log.shared.error("Failed to initialize APN provider", { error })
      return undefined
    }
  }
  return apnProvider
}

export const shutdownApnProvider = (): void => {
  if (!apnProvider) {
    return
  }

  try {
    apnProvider.shutdown()
  } catch (error) {
    Log.shared.error("Failed to shutdown APN provider", { error })
  } finally {
    apnProvider = undefined
  }
}
