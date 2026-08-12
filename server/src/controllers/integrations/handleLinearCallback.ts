import { decryptLinearTokens, encryptLinearTokens } from "@in/server/libs/helpers"
import { Log } from "@in/server/utils/log"
import { exchangeLinearAuthorizationCode, revokeLinearToken } from "@in/server/libs/linear"
import { storeConnectorToken } from "@in/server/modules/integrations/connectionStore"

export const handleLinearCallback = async ({
  code,
  userId,
  spaceId,
}: {
  code: string
  userId: number
  spaceId: number | null
}) => {
  try {
    const tokens = await exchangeLinearAuthorizationCode(code)
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
        provider: "linear",
        token: encryptedToken,
      })
      await Promise.all(replacedTokens.map(async (token) => {
        try {
          const parsed = decryptLinearTokens(token)
          const result = await revokeLinearToken({
            accessToken: parsed?.data?.access_token,
            refreshToken: parsed?.data?.refresh_token,
          })
          if (!result.ok) {
            Log.shared.warn("Failed to revoke displaced Linear token", {
              status: result.status,
            })
          }
        } catch (error) {
          Log.shared.warn("Failed to revoke displaced Linear token", { error })
        }
      }))
    } catch (e) {
      if (e instanceof Error) {
        Log.shared.error("Failed to upsert Linear integration", e, { userId, spaceId })
      } else {
        Log.shared.error("Failed to upsert Linear integration", { userId, spaceId, error: e })
      }
      const result = await revokeLinearToken({
        accessToken: stringTokenField(tokens.data, "access_token"),
        refreshToken: stringTokenField(tokens.data, "refresh_token"),
      })
      if (!result.ok) {
        Log.shared.warn("Failed to revoke unsaved Linear token", {
          status: result.status,
        })
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

    return {
      ok: false,
      error: "Network error",
    }
  }
}

function stringTokenField(
  data: Record<string, unknown>,
  field: "access_token" | "refresh_token",
): string | null {
  const value = data[field]
  return typeof value === "string" && value.length > 0 ? value : null
}
