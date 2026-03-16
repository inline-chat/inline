import { Type, type Static } from "@sinclair/typebox"
import {
  getDatabases,
  getNotionClient,
  persistCanonicalNotionParentId,
  resolveSelectedNotionParent,
} from "../../modules/notion/notion"
import { NOTION_SETUP_ERROR_MESSAGES } from "../../modules/notion/errors"
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
  _context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const notion = await getNotionClient(input.spaceId)
  if (notion.databaseId) {
    try {
      const selectedParent = await resolveSelectedNotionParent(input.spaceId, notion.databaseId, notion.client)
      if (selectedParent.wasLegacyDatabaseSelection) {
        await persistCanonicalNotionParentId(input.spaceId, notion.databaseId, selectedParent.dataSourceId)
      }
    } catch (error) {
      if (
        error instanceof Error &&
        error.message !== NOTION_SETUP_ERROR_MESSAGES.legacyDatabaseSelectionAmbiguous &&
        error.message !== NOTION_SETUP_ERROR_MESSAGES.parentNotFound
      ) {
        throw error
      }
    }
  }
  const databases = await getDatabases(input.spaceId, 100, notion.client)

  let returnValue = databases.map((db) => ({
    id: db.id,
    title: db.title,
    icon: db.icon ?? undefined,
  }))

  return returnValue
}
