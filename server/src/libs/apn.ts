import APN from "apn"
import { Log } from "@in/server/utils/log"

// Configure APN provider
let apnProvider: APN.Provider | undefined

export const getApnProvider = () => {
  if (process.env["NODE_ENV"] === "test") {
    return undefined
  }

  if (!apnProvider) {
    const rawKey = process.env["APN_KEY"]
    const keyId = process.env["APN_KEY_ID"]
    const teamId = process.env["APN_TEAM_ID"]

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
        production: process.env["NODE_ENV"] === "production",
      })
    } catch (error) {
      Log.shared.error("Failed to initialize APN provider", { error })
      return undefined
    }
  }
  return apnProvider
}

// Shutdown provider TODO: call on server close
// apnProvider.shutdown()
