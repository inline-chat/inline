import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { chats, members, spaces, users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeChatInfo,
  encodeMemberInfo,
  encodeMinUserInfo,
  encodeSpaceInfo,
  encodeUserInfo,
  TChatInfo,
  TMemberInfo,
  TMinUserInfo,
  TSpaceInfo,
  TUserInfo,
} from "@in/server/api-types"
import { TInputId } from "@in/server/types/methods"
import { UsersModel } from "@in/server/db/models/users"

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

  const members_ = await db.query.members.findMany({
    where: eq(members.spaceId, spaceId),
  })

  const userIds = members_.map((m) => m.userId)
  const usersWithPhotos = await UsersModel.getUsersWithPhotos(userIds)

  return {
    users: usersWithPhotos.map((u) => encodeMinUserInfo(u.user, { photoFile: u.photoFile ?? undefined })),
    members: members_.map((member) => encodeMemberInfo(member)),
  }
}
