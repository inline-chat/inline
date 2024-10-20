import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import {
  chats,
  members,
  spaces,
  type DbChat,
  type DbMember,
  type DbSpace,
} from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeChatInfo,
  encodeMemberInfo,
  encodeSpaceInfo,
  TChatInfo,
  TMemberInfo,
  TSpaceInfo,
} from "@in/server/models"

export const Input = Type.Object({
  id: Type.String(),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

type RawOutput = {
  space: DbSpace
  members: DbMember[]
  chats: DbChat[]
}

export const Response = Type.Object({
  space: TSpaceInfo,
  members: Type.Array(TMemberInfo),
  chats: Type.Array(TChatInfo),
})

export const encode = (output: RawOutput): Static<typeof Response> => {
  return {
    space: encodeSpaceInfo(output.space),
    members: output.members.map(encodeMemberInfo),
    chats: output.chats.map(encodeChatInfo),
  }
}

export const handler = async (
  input: Input,
  context: Context,
): Promise<RawOutput> => {
  try {
    const spaceId = parseInt(input.id, 10)
    if (isNaN(spaceId)) {
      throw new InlineError(ErrorCodes.INVALID_INPUT, "Invalid space ID")
    }
    const result = await db
      .select()
      .from(spaces)
      .where(eq(spaces.id, spaceId))
      .innerJoin(members, eq(spaces.id, members.spaceId))
      .innerJoin(chats, eq(spaces.id, chats.spaceId))

    return {
      space: result[0].spaces,
      members: result.map((r) => r.members),
      chats: result.map((r) => r.chats),
    }
  } catch (error) {
    Log.shared.error("Failed to get space", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to get space")
  }
}
