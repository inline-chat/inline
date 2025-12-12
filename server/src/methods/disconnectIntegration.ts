import { Type, type Static } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema"
import { Authorize } from "@in/server/utils/authorize"
import { decryptLinearTokens } from "@in/server/libs/helpers"
import { revokeLinearToken } from "@in/server/libs/linear"
import { Log } from "@in/server/utils/log"

export const Input = Type.Object({
  spaceId: Type.Number(),
  provider: Type.Union([Type.Literal("notion"), Type.Literal("linear")]),
})

export const Response = Type.Object({
  ok: Type.Boolean(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = Number(input.spaceId)
  await Authorize.spaceAdmin(spaceId, context.currentUserId)

  const integration = await db._query.integrations.findFirst({
    where: and(eq(integrations.spaceId, spaceId), eq(integrations.provider, input.provider)),
  })

  if (input.provider === "linear" && integration) {
    if (integration.accessTokenEncrypted && integration.accessTokenIv && integration.accessTokenTag) {
      const parsed = decryptLinearTokens({
        encrypted: integration.accessTokenEncrypted,
        iv: integration.accessTokenIv,
        authTag: integration.accessTokenTag,
      })

      const accessToken = parsed?.data?.access_token as string | undefined
      const refreshToken = parsed?.data?.refresh_token as string | undefined

      const revokeResult = await revokeLinearToken({
        accessToken,
        refreshToken,
      })

      if (!revokeResult.ok) {
        Log.shared.warn("Failed to revoke Linear token during disconnect", {
          spaceId,
          status: revokeResult.status,
        })
        // Token revoke is best-effort. Even if it fails, proceed with disconnecting and delete the record.
      }
    } else {
      Log.shared.warn("Linear integration missing token encryption data during disconnect", { spaceId })
    }
  }

  await db
    .delete(integrations)
    .where(and(eq(integrations.spaceId, spaceId), eq(integrations.provider, input.provider)))

  return { ok: true }
}
