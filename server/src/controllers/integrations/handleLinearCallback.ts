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

    try {
      await db.insert(integrations).values({
        userId,
        spaceId: Number(spaceId),
        provider: "linear",
        accessTokenEncrypted: encryptedToken.encrypted,
        accessTokenIv: encryptedToken.iv,
        accessTokenTag: encryptedToken.authTag,
      })
    } catch (e) {
      Log.shared.error("Failed to create integration", e)
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
