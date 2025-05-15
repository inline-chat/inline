import { eq } from "drizzle-orm"
import { db } from ".."
import { integrations } from "../schema"
import { decryptLinearTokens } from "@in/server/libs/helpers"

export class IntegrationsModel {
  static async getWithUserId(userId: number) {
    const integration = await db._query.integrations.findFirst({
      where: eq(integrations.userId, userId),
    })

    if (!integration) {
      throw new Error("No Linear integration found")
    }

    if (!integration.accessTokenEncrypted || !integration.accessTokenIv || !integration.accessTokenTag) {
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
