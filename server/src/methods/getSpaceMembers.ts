import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { members } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeMemberInfo,
  encodeMinUserInfo,
  TMemberInfo,
  TMinUserInfo,
} from "@in/server/api-types"
import { TInputId } from "@in/server/types/methods"
import { UsersModel } from "@in/server/db/models/users"
import { Authorize } from "@in/server/utils/authorize"
import { SpaceModel } from "@in/server/db/models/spaces"

export const Input = Type.Object({
  spaceId: TInputId,
  // TODO: needs pagination
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  members: Type.Array(TMemberInfo),
  users: Type.Array(TMinUserInfo),
  // chats, last messages, dialogs?
})

type Response = Static<typeof Response>

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const spaceId = Number(input.spaceId)

  // Validate
  if (isNaN(spaceId)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const [space] = await Promise.all([
    SpaceModel.getSpaceById(spaceId),
    Authorize.spaceMember(spaceId, currentUserId),
  ])

  if (!space || space.deleted !== null) {
    throw new InlineError(InlineError.ApiError.SPACE_INVALID)
  }

  const members_ = await db._query.members.findMany({
    where: eq(members.spaceId, spaceId),
  })

  const userIds = members_.map((m) => m.userId)
  const usersWithPhotos = await UsersModel.getUsersWithPhotos(userIds)

  return {
    users: usersWithPhotos.map((u) => encodeMinUserInfo(u.user, { photoFile: u.photoFile ?? undefined })),
    members: members_.map((member) => encodeMemberInfo(member)),
  }
}
