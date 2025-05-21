import { and, eq } from "drizzle-orm"
import { db } from ".."
import { integrations } from "../schema"
import { decryptLinearTokens } from "@in/server/libs/helpers"
import { Log } from "@in/server/utils/log"
export class IntegrationsModel {
  static async getWithUserId(userId: number) {
    const integration = await db._query.integrations.findFirst({
      where: eq(integrations.userId, userId),
    })

    if (!integration) {
      throw new Error("No Linear integration found")
    }

    if (!integration.accessTokenEncrypted || !integration.accessTokenIv || !integration.accessTokenTag) {
      Log.shared.error("Missing encryption data", { integrationId: integration.id })
      throw new Error("Missing encryption data")
    }

    const parsedToken = decryptLinearTokens({
      encrypted: integration.accessTokenEncrypted,
      iv: integration.accessTokenIv,
      authTag: integration.accessTokenTag,
    })

    return {
      accessToken: parsedToken.data.access_token,
    }
  }

  static async getAuthTokenWithSpaceId(spaceId: number, provider: string) {
    const integration = await db._query.integrations.findFirst({
      where: and(eq(integrations.spaceId, spaceId), eq(integrations.provider, provider)),
    })

    if (!integration) {
      Log.shared.error("No integration found", { spaceId, provider })
      throw new Error("No integration found")
    }

    if (!integration.accessTokenEncrypted || !integration.accessTokenIv || !integration.accessTokenTag) {
      Log.shared.error("Missing encryption data", { spaceId, provider })
      throw new Error("Missing encryption data")
    }

    const parsedToken = decryptLinearTokens({
      encrypted: integration.accessTokenEncrypted,
      iv: integration.accessTokenIv,
      authTag: integration.accessTokenTag,
    })

    return {
      accessToken: parsedToken.data.access_token,
    }
  }
}
