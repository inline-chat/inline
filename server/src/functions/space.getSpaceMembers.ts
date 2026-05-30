import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { members } from "@in/server/db/schema"
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

  const privacy = await getSpacePrivacyContext(spaceId, context.currentUserId)
  const min = privacy.isPublicSpace && !privacy.canManageMembers

  const members_ = await db._query.members.findMany({
    where: eq(members.spaceId, spaceId),
  })

  const activeUserIds = await UsersModel.getActiveUserIds(members_.map((m) => m.userId))
  const activeUserIdSet = new Set(activeUserIds)
  const activeMembers = members_.filter((member) => activeUserIdSet.has(member.userId))
  const usersWithPhotos = await UsersModel.getUsersWithPhotos(activeUserIds)

  return {
    members: activeMembers.map((member) => Encoders.member(member)),
    users: usersWithPhotos.map((u) => Encoders.user({ user: u.user, photoFile: u.photoFile, min })),
  }
}
