import * as arctic from "arctic"
import { Log } from "@in/server/utils/log"
import { encryptLinearTokens } from "@in/server/libs/helpers"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema/integrations"

export let notionOauth: arctic.Notion | undefined

const isProd = process.env.NODE_ENV === "production"

const resolveNotionOauthConfig = () => {
  if (isProd) {
    return {
      clientId: process.env.NOTION_CLIENT_ID,
      clientSecret: process.env.NOTION_CLIENT_SECRET,
      redirectUri: "https://api.inline.chat/integrations/notion/callback",
    }
  }

  return {
    clientId: process.env.NOTION_CLIENT_ID_DEV ?? process.env.NOTION_CLIENT_ID,
    clientSecret: process.env.NOTION_CLIENT_SECRET_DEV ?? process.env.NOTION_CLIENT_SECRET,
    redirectUri: "http://localhost:8000/integrations/notion/callback",
  }
}

const notionOauthConfig = resolveNotionOauthConfig()
if (notionOauthConfig.clientId && notionOauthConfig.clientSecret) {
  notionOauth = new arctic.Notion(
    notionOauthConfig.clientId,
    notionOauthConfig.clientSecret,
    notionOauthConfig.redirectUri,
  )
} else {
  Log.shared.warn("Notion OAuth is not configured", {
    nodeEnv: process.env.NODE_ENV ?? "unknown",
    isProd,
    hasNotionClientId: Boolean(process.env.NOTION_CLIENT_ID),
    hasNotionClientSecret: Boolean(process.env.NOTION_CLIENT_SECRET),
    hasNotionClientIdDev: Boolean(process.env.NOTION_CLIENT_ID_DEV),
    hasNotionClientSecretDev: Boolean(process.env.NOTION_CLIENT_SECRET_DEV),
  })
}

export const getNotionAuthUrl = (state: string) => {
  if (!notionOauth) {
    return {
      url: undefined,
      error: "Notion OAuth is not configured on the server",
    }
  }

  try {
    const url = notionOauth.createAuthorizationURL(state)
    return { url, error: undefined as string | undefined }
  } catch (error) {
    Log.shared.error("Failed to create Notion OAuth authorization URL", error)
    return {
      url: undefined,
      error: "Failed to create Notion OAuth authorization URL",
    }
  }
}

export const handleNotionCallback = async ({
  code,
  userId,
  spaceId,
}: {
  code: string
  userId: number
  spaceId: string
}) => {
  if (!notionOauth) {
    return {
      ok: false as const,
      error: "Notion OAuth is not configured on the server",
    }
  }

  try {
    const tokens = await notionOauth.validateAuthorizationCode(code)

    if (!tokens) {
      return {
        ok: false,
        error: "Invalid authorization",
      }
    }
    const encryptedToken = encryptLinearTokens(tokens)

    try {
      const integration = await db
        .insert(integrations)
        .values({
          userId,
          spaceId: Number(spaceId),
          provider: "notion",
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
        .returning()

      if (!integration) {
        return {
          ok: false,
          error: "Failed to save integration",
        }
      }
      return {
        ok: true,
        integration,
      }
    } catch (e) {
      Log.shared.error("Failed to create Notion integration", e)
      return {
        ok: false,
        error: "Failed to save integration",
      }
    }
  } catch (e) {
    Log.shared.error("Notion callback failed", e)

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
