import { Type, type Static } from "@sinclair/typebox"
import { integrations } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { Authorize } from "@in/server/utils/authorize"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { listLinearTeams } from "@in/server/libs/linear"
import { rejectBotConnectorAccess } from "@in/server/modules/integrations/providerActionContext"

export const Input = Type.Object({
  spaceId: Type.String(),
  teamId: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
  dependencies: { listTeams: typeof listLinearTeams } = { listTeams: listLinearTeams },
): Promise<Static<typeof Response>> => {
  const spaceId = Number(input.spaceId)
  if (isNaN(spaceId)) {
    throw new Error("Invalid spaceId")
  }

  await rejectBotConnectorAccess(context.currentUserId)
  await Authorize.spaceAdmin(spaceId, context.currentUserId)
  const teams = await dependencies.listTeams({ spaceId })
  if (!teams.some((team) => team.id === input.teamId)) {
    throw new Error("Linear team is not available to this connection")
  }

  const result = await db
    .update(integrations)
    .set({ linearTeamId: input.teamId })
    .where(and(eq(integrations.spaceId, spaceId), eq(integrations.provider, "linear")))
    .returning()

  if (result.length === 0) {
    throw new Error("No Linear integration found for space")
  }
}
