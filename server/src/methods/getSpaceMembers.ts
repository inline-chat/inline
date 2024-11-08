import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { chats, members, spaces, users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeChatInfo,
  encodeMemberInfo,
  encodeSpaceInfo,
  encodeUserInfo,
  TChatInfo,
  TMemberInfo,
  TSpaceInfo,
  TUserInfo,
} from "@in/server/models"
import { TInputId } from "@in/server/types/methods"

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
  users: Type.Array(TUserInfo),
  // chats, last messages, dialogs?
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  const spaceId = Number(input.spaceId)

  // Validate
  if (isNaN(spaceId)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  // Get the space members
  const result = await db
    .select()
    .from(spaces)
    .where(eq(spaces.id, spaceId))
    .innerJoin(members, eq(spaces.id, members.spaceId))
    .innerJoin(users, eq(members.userId, users.id))

  if (!result[0]) {
    throw new InlineError(InlineError.ApiError.SPACE_INVALID)
  }

  return {
    members: result.map((r) => encodeMemberInfo(r.members)),
    users: result.map((r) => encodeUserInfo(r.users)),
  }
}
