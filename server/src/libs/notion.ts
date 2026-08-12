import * as arctic from "arctic"
import { Log } from "@in/server/utils/log"
import { decryptLinearTokens, encryptLinearTokens } from "@in/server/libs/helpers"
import { storeConnectorToken } from "@in/server/modules/integrations/connectionStore"
import { connectorOAuthRedirectUri } from "@in/server/modules/integrations/connectorOAuthRedirectUri"
import { connectorOAuthCredentials } from "@in/server/modules/integrations/connectorOAuthCredentials"
import { exchangeConnectorAuthorizationCode } from "@in/server/modules/integrations/oauthTokenExchange"

export let notionOauth: arctic.Notion | undefined

const resolveNotionOauthConfig = () => {
  const credentials = connectorOAuthCredentials("notion")
  return {
    clientId: credentials?.clientId,
    clientSecret: credentials?.clientSecret,
    redirectUri: connectorOAuthRedirectUri("notion"),
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
    isProd: process.env.NODE_ENV === "production",
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

export const revokeNotionToken = async (
  accessToken: string,
): Promise<{ ok: boolean; status?: number }> => {
  if (!notionOauthConfig.clientId || !notionOauthConfig.clientSecret) {
    return { ok: false }
  }
  const authorization = Buffer.from(
    `${notionOauthConfig.clientId}:${notionOauthConfig.clientSecret}`,
    "utf8",
  ).toString("base64")
  try {
    const response = await fetch("https://api.notion.com/v1/oauth/revoke", {
      method: "POST",
      headers: {
        Authorization: `Basic ${authorization}`,
        "Content-Type": "application/json",
        "Notion-Version": "2026-03-11",
      },
      body: JSON.stringify({ token: accessToken }),
      signal: AbortSignal.timeout(3_000),
    })
    return {
      ok: response.ok,
      status: response.status,
    }
  } catch (error) {
    Log.shared.warn("Notion token revoke request failed", { error })
    return { ok: false }
  }
}

async function exchangeNotionAuthorizationCode(code: string) {
  if (!notionOauthConfig.clientId || !notionOauthConfig.clientSecret) return null
  return exchangeConnectorAuthorizationCode({
    provider: "notion",
    code,
    redirectUri: notionOauthConfig.redirectUri,
    credentials: {
      clientId: notionOauthConfig.clientId,
      clientSecret: notionOauthConfig.clientSecret,
    },
  })
}

export const handleNotionCallback = async ({
  code,
  userId,
  spaceId,
}: {
  code: string
  userId: number
  spaceId: number | null
}) => {
  if (!notionOauth) {
    return {
      ok: false as const,
      error: "Notion OAuth is not configured on the server",
    }
  }

  try {
    const tokens = await exchangeNotionAuthorizationCode(code)

    if (!tokens) {
      return {
        ok: false,
        error: "Invalid authorization",
      }
    }
    const encryptedToken = encryptLinearTokens(tokens)

    try {
      const replacedTokens = await storeConnectorToken({
        userId,
        spaceId,
        provider: "notion",
        token: encryptedToken,
      })
      await Promise.all(replacedTokens.map(async (token) => {
        try {
          const parsed = decryptLinearTokens(token)
          const accessToken = parsed?.data?.access_token
          if (typeof accessToken === "string") {
            const result = await revokeNotionToken(accessToken)
            if (!result.ok) {
              Log.shared.warn("Failed to revoke displaced Notion token", {
                status: result.status,
              })
            }
          }
        } catch (error) {
          Log.shared.warn("Failed to revoke displaced Notion token", { error })
        }
      }))
      return {
        ok: true,
      }
    } catch (e) {
      Log.shared.error("Failed to create Notion integration", e)
      const accessToken = tokens.data["access_token"]
      if (typeof accessToken === "string") {
        const result = await revokeNotionToken(accessToken)
        if (!result.ok) {
          Log.shared.warn("Failed to revoke unsaved Notion token", {
            status: result.status,
          })
        }
      }
      return {
        ok: false,
        error: "Failed to save integration",
      }
    }
  } catch (e) {
    Log.shared.error("Notion callback failed", e)

    return {
      ok: false,
      error: "Network error",
    }
  }
}
