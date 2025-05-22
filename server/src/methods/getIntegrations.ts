import { and, eq, or, inArray } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrations, members, spaces } from "@in/server/db/schema"
import { type Static, Type } from "@sinclair/typebox"
import { TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"
import type { HandlerContext } from "@in/server/controllers/helpers"

export const Input = Type.Object({
  userId: TInputId,
  spaceId: Type.Optional(TInputId),
})

export const Response = Type.Object({
  hasLinearConnected: Type.Boolean(),
  hasNotionConnected: Type.Boolean(),
  notionSpaces: Type.Optional(
    Type.Array(
      Type.Object({
        spaceId: Type.Integer(),
        spaceName: Type.String(),
      }),
    ),
  ),
})

type Input = Static<typeof Input>
type Response = Static<typeof Response>

export const handler = async (input: Input, context: HandlerContext): Promise<Response> => {
  let userId = Number(input.userId)
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  let hasLinearConnected = false
  let hasNotionConnected = false
  let notionSpaces: Array<{ spaceId: number; spaceName: string }> | undefined

  // Check Linear integrations (user-specific)
  const userIntegrations = await db.select().from(integrations).where(eq(integrations.userId, userId))
  hasLinearConnected = userIntegrations.some((integration) => integration.provider === "linear")

  // Check Notion integrations (space-specific)
  if (input.spaceId) {
    const spaceId = Number(input.spaceId)
    if (!isNaN(spaceId)) {
      // Check if user is a member of the space
      await Authorize.spaceMember(spaceId, context.currentUserId)

      const spaceIntegrations = await db.select().from(integrations).where(eq(integrations.spaceId, spaceId))
      hasNotionConnected = spaceIntegrations.some((integration) => integration.provider === "notion")
    }
  } else {
    // If no specific spaceId provided, check if user is member of any space with Notion integration
    // Get all spaces the user is a member of
    const userSpaces = await db
      .select({ spaceId: members.spaceId })
      .from(members)
      .where(eq(members.userId, context.currentUserId))

    if (userSpaces.length > 0) {
      const spaceIds = userSpaces.map((space) => space.spaceId)

      // Get spaces with Notion integrations
      const spacesWithNotion = await db
        .select({
          spaceId: integrations.spaceId,
          spaceName: spaces.name,
        })
        .from(integrations)
        .innerJoin(spaces, eq(integrations.spaceId, spaces.id))
        .where(and(inArray(integrations.spaceId, spaceIds), eq(integrations.provider, "notion")))

      hasNotionConnected = spacesWithNotion.length > 0
      if (hasNotionConnected) {
        notionSpaces = spacesWithNotion.map((space) => ({
          spaceId: space.spaceId!,
          spaceName: space.spaceName,
        }))
      }
    }
  }

  return {
    hasLinearConnected,
    hasNotionConnected,
    notionSpaces,
  }
}
