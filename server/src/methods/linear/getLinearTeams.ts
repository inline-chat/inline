import { Type, type Static } from "@sinclair/typebox"
import { listLinearTeams } from "@in/server/libs/linear"
import { Authorize } from "@in/server/utils/authorize"
import type { HandlerContext } from "@in/server/controllers/helpers"

export const Input = Type.Object({
  spaceId: Type.Number(),
})

export const Response = Type.Array(
  Type.Object({
    id: Type.String(),
    name: Type.String(),
    key: Type.String(),
  }),
)

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  await Authorize.spaceMember(input.spaceId, context.currentUserId)

  const teams = await listLinearTeams({ spaceId: input.spaceId })

  return teams.map((team) => ({
    id: team.id,
    name: team.name,
    key: team.key,
  }))
}

