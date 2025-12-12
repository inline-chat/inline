import { Type, type Static } from "@sinclair/typebox"
import { integrations } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { Authorize } from "@in/server/utils/authorize"
import type { HandlerContext } from "@in/server/controllers/helpers"

export const Input = Type.Object({
  spaceId: Type.String(),
  teamId: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = Number(input.spaceId)
  if (isNaN(spaceId)) {
    throw new Error("Invalid spaceId")
  }

  await Authorize.spaceAdmin(spaceId, context.currentUserId)

  const result = await db
    .update(integrations)
    .set({ linearTeamId: input.teamId })
    .where(and(eq(integrations.spaceId, spaceId), eq(integrations.provider, "linear")))
    .returning()

  if (result.length === 0) {
    throw new Error("No Linear integration found for space")
  }
}
