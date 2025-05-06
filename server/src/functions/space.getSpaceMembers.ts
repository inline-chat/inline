import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { members } from "@in/server/db/schema"
import { UsersModel } from "@in/server/db/models/users"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"
import type { GetSpaceMembersInput, GetSpaceMembersResult } from "@in/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"

export const getSpaceMembers = async (
  input: GetSpaceMembersInput,
  context: FunctionContext,
): Promise<GetSpaceMembersResult> => {
  const spaceId = Number(input.spaceId)
  if (isNaN(spaceId) || spaceId <= 0) {
    throw RealtimeRpcError.BadRequest
  }

  const members_ = await db.query.members.findMany({
    where: eq(members.spaceId, spaceId),
  })

  const userIds = members_.map((m) => m.userId)
  const usersWithPhotos = await UsersModel.getUsersWithPhotos(userIds)

  return {
    members: members_.map((member) => Encoders.member(member)),
    users: usersWithPhotos.map((u) => Encoders.user({ user: u.user, min: true })),
  }
}
