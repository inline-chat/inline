import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { chats, members, spaces } from "@in/server/db/schema"
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
import { TInputId } from "@in/server/types/methods"

export const Input = Type.Object({
  id: TInputId,
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  space: TSpaceInfo,
  members: Type.Array(TMemberInfo),
  chats: Type.Array(TChatInfo),
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  try {
    const spaceId = Number(input.id)
    if (isNaN(spaceId)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }
    const result = await db
      .select()
      .from(spaces)
      .where(eq(spaces.id, spaceId))
      .innerJoin(members, eq(spaces.id, members.spaceId))
      .innerJoin(chats, eq(spaces.id, chats.spaceId))

    if (!result[0]) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    return {
      space: encodeSpaceInfo(result[0].spaces),
      members: result.map((r) => encodeMemberInfo(r.members)),
      chats: result.map((r) => encodeChatInfo(r.chats, { currentUserId: context.currentUserId })),
    }
  } catch (error) {
    Log.shared.error("Failed to get space", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
