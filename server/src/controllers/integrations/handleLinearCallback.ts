import * as arctic from "arctic"
import { encryptLinearTokens } from "@in/server/libs/helpers"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema/integrations"
import { Log } from "@in/server/utils/log"
import { linearOauth } from "@in/server/libs/linear"

export const handleLinearCallback = async ({
  code,
  userId,
  spaceId,
}: {
  code: string
  userId: number
  spaceId: string
}) => {
  try {
    const tokens = await linearOauth?.validateAuthorizationCode(code)
    if (!tokens) {
      return {
        ok: false,
        error: "Invalid authorization",
      }
    }
    const encryptedToken = encryptLinearTokens(tokens)

    const numericSpaceId = Number(spaceId)
    if (isNaN(numericSpaceId)) {
      return {
        ok: false,
        error: "Invalid spaceId",
      }
    }

    try {
      await db
        .insert(integrations)
        .values({
          userId,
          spaceId: numericSpaceId,
          provider: "linear",
          accessTokenEncrypted: encryptedToken.encrypted,
          accessTokenIv: encryptedToken.iv,
          accessTokenTag: encryptedToken.authTag,
        })
        .onConflictDoUpdate({
          target: [integrations.spaceId, integrations.provider],
          set: {
            userId,
            accessTokenEncrypted: encryptedToken.encrypted,
            accessTokenIv: encryptedToken.iv,
            accessTokenTag: encryptedToken.authTag,
            date: new Date(),
          },
        })
    } catch (e) {
      if (e instanceof Error) {
        Log.shared.error("Failed to upsert Linear integration", e, { userId, spaceId: numericSpaceId })
      } else {
        Log.shared.error("Failed to upsert Linear integration", { userId, spaceId: numericSpaceId, error: e })
      }
      return {
        ok: false,
        error: "Failed to save Linear integration",
      }
    }

    return {
      ok: true,
    }
  } catch (e) {
    Log.shared.error("Linear callback failed", e)

    if (e instanceof arctic.OAuth2RequestError) {
      return {
        ok: false,
        error: "Invalid authorization",
      }
    }
    if (e instanceof arctic.ArcticFetchError) {
      return {
        ok: false,
        error: "Network error",
      }
    }
    return {
      ok: false,
      error: "Unknown error",
    }
  }
}
