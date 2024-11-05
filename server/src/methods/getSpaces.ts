import { db } from "@in/server/db"
import { and, eq, isNull } from "drizzle-orm"
import { members, spaces } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { encodeMemberInfo, encodeSpaceInfo, TMemberInfo, TSpaceInfo } from "@in/server/models"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"

export const Input = Type.Object({})

export const Response = Type.Object({
  /** All spaces we are part of */
  spaces: Type.Array(TSpaceInfo),

  /** Our own memberships */
  members: Type.Array(TMemberInfo),
})

export const handler = async (_: undefined, context: HandlerContext): Promise<Static<typeof Response>> => {
  try {
    const result = await db
      .select()
      .from(members)
      .where(eq(members.userId, context.currentUserId))
      .innerJoin(
        spaces,
        and(
          // Join on space id
          eq(members.spaceId, spaces.id),
          // Only get memberships for ourself
          eq(members.userId, context.currentUserId),
          // Filter deleted
          isNull(spaces.deleted),
        ),
      )

    const output = {
      spaces: result.map((r) => r.spaces),
      members: result.map((r) => r.members),
    }

    return {
      spaces: output.spaces.map((s) => encodeSpaceInfo(s, { currentUserId: context.currentUserId })),
      members: output.members.map(encodeMemberInfo),
    }
  } catch (error) {
    Log.shared.error("Failed to get spaces", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
