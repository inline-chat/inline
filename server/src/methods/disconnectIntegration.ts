import { Type, type Static } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema"
import { Authorize } from "@in/server/utils/authorize"
import { revokeConnectorConnection } from "@in/server/functions/connectors"
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

  const integrationRows = await db
    .select()
    .from(integrations)
    .where(and(eq(integrations.spaceId, spaceId), eq(integrations.provider, input.provider)))

  await db
    .delete(integrations)
    .where(and(eq(integrations.spaceId, spaceId), eq(integrations.provider, input.provider)))

  await Promise.all(integrationRows.map(async (integration) => {
    const result = await revokeConnectorConnection(input.provider, integration)
      .catch((error) => {
        Log.shared.warn("Legacy connector token revocation failed", {
          provider: input.provider,
          spaceId,
          error: error instanceof Error ? error.name : "UnknownError",
        })
        return { ok: false, status: undefined }
      })
    if (!result.ok) {
      Log.shared.warn("Legacy connector token revocation failed", {
        provider: input.provider,
        spaceId,
        status: result.status,
      })
    }
  }))

  return { ok: true }
}
