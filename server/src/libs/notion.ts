import * as arctic from "arctic"
import { Log } from "@in/server/utils/log"
import { encryptLinearTokens } from "@in/server/libs/helpers"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema/integrations"

export let notionOauth: arctic.Notion | undefined

if (process.env.NOTION_CLIENT_ID && process.env.NOTION_CLIENT_SECRET) {
  notionOauth = new arctic.Notion(
    process.env.NOTION_CLIENT_ID,
    process.env.NOTION_CLIENT_SECRET,
    "https://api.inline.chat/integrations/notion/callback",
  )
}

export const getNotionAuthUrl = (state: string) => {
  const url = notionOauth?.createAuthorizationURL(state)
  return { url }
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
  try {
    const tokens = await notionOauth?.validateAuthorizationCode(code)

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
