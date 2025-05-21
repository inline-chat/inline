import { Type, type Static } from "@sinclair/typebox"
import { getDatabases } from "../../modules/notion/notion"
import { Log } from "../../utils/log"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { integrations } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"

export const Input = Type.Object({
  spaceId: Type.String(),
  databaseId: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const { spaceId, databaseId } = input

  console.log("🔍 Saving notion database id", { spaceId, databaseId })

  let result = await db
    .update(integrations)
    .set({ notionDatabaseId: databaseId })
    .where(and(eq(integrations.spaceId, Number(spaceId)), eq(integrations.provider, "notion")))
    .returning()

  if (result.length === 0) {
    throw new Error("No integration found")
  }
  console.log("🔍 Saved notion database id", { result })
}
