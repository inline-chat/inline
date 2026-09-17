import { and, eq, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import { members, spaces, type DbMember, type DbSpace } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { Transaction } from "@in/server/db/types"

export type SpacePrivacyContext = {
  space: DbSpace
  member: DbMember
  isPublicSpace: boolean
  canManageMembers: boolean
}

export async function getSpacePrivacyContext(
  spaceId: number,
  userId: number,
  options?: { tx?: Transaction },
): Promise<SpacePrivacyContext> {
  const executor = options?.tx ?? db
  const [row] = await executor
    .select({
      space: spaces,
      member: members,
    })
    .from(spaces)
    .leftJoin(members, and(eq(members.spaceId, spaces.id), eq(members.userId, userId)))
    .where(and(eq(spaces.id, spaceId), isNull(spaces.deleted)))
    .limit(1)

  if (!row?.space) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }

  if (!row.member) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }

  return {
    space: row.space,
    member: row.member,
    isPublicSpace: row.space.isPublic === true,
    canManageMembers: row.member.role === "admin" || row.member.role === "owner",
  }
}
