import { Type, type Static } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { integrations } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { Authorize } from "@in/server/utils/authorize"
import { getDatabases, getNotionClient } from "@in/server/modules/notion/notion"
import { rejectBotConnectorAccess } from "@in/server/modules/integrations/providerActionContext"

export const Input = Type.Object({
  spaceId: Type.String(),
  databaseId: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
  dependencies: {
    listDatabases(spaceId: number): Promise<Array<{ id: string }>>
  } = {
    async listDatabases(spaceId) {
      const notion = await getNotionClient(spaceId)
      return getDatabases(spaceId, 100, notion.client)
    },
  },
): Promise<Static<typeof Response>> => {
  const { spaceId, databaseId } = input
  const spaceIdNum = Number(spaceId)
  if (isNaN(spaceIdNum)) {
    throw new Error("Invalid spaceId")
  }

  await rejectBotConnectorAccess(context.currentUserId)
  await Authorize.spaceAdmin(spaceIdNum, context.currentUserId)
  const databases = await dependencies.listDatabases(spaceIdNum)
  if (!databases.some((database) => database.id === databaseId)) {
    throw new Error("Notion source is not available to this connection")
  }

  let result = await db
    .update(integrations)
    .set({ notionDatabaseId: databaseId })
    .where(and(eq(integrations.spaceId, spaceIdNum), eq(integrations.provider, "notion")))
    .returning()

  if (result.length === 0) {
    throw new Error("No integration found")
  }
}
