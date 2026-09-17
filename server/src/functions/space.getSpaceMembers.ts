import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { members, userNotDeleted, users } from "@in/server/db/schema"
import { UsersModel } from "@in/server/db/models/users"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"
import type { GetSpaceMembersInput, GetSpaceMembersResult } from "@inline-chat/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { getSpacePrivacyContext } from "@in/server/modules/privacy/spacePrivacy"

export const getSpaceMembers = async (
  input: GetSpaceMembersInput,
  context: FunctionContext,
): Promise<GetSpaceMembersResult> => {
  const spaceId = Number(input.spaceId)
  if (isNaN(spaceId) || spaceId <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  return db.transaction(
    async (tx) => {
      const privacy = await getSpacePrivacyContext(spaceId, context.currentUserId, { tx })
      const min = privacy.isPublicSpace && !privacy.canManageMembers
      const activeMembers = await tx
        .select({ member: members })
        .from(members)
        .innerJoin(users, and(eq(users.id, members.userId), userNotDeleted()))
        .where(eq(members.spaceId, spaceId))
        .then((rows) => rows.map((row) => row.member))
      const usersWithPhotos = await UsersModel.getUsersWithPhotos(
        activeMembers.map((member) => member.userId),
        { tx },
      )

      return {
        members: activeMembers.map((member) => Encoders.member(member)),
        users: usersWithPhotos.map((u) => Encoders.user({ user: u.user, photoFile: u.photoFile, min })),
        seq: privacy.space.updateSeq ?? 0,
      }
    },
    { isolationLevel: "repeatable read", accessMode: "read only" },
  )
}
