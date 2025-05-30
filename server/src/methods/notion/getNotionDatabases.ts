import { Type, type Static } from "@sinclair/typebox"
import { getDatabases, getNotionClient } from "../../modules/notion/notion"
import { Log } from "../../utils/log"
import type { HandlerContext } from "@in/server/controllers/helpers"

export const Input = Type.Object({
  spaceId: Type.Number(),
})

export const Response = Type.Array(
  Type.Object({
    id: Type.String(),
    title: Type.String(),
    icon: Type.Optional(Type.String()),
  }),
)

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const notion = await getNotionClient(input.spaceId)
  const databases = await getDatabases(input.spaceId, 100, notion.client)

  let returnValue = databases.map((db) => ({
    id: db.id,
    title: db.title,
    icon: db.icon ?? undefined,
  }))

  return returnValue
}
