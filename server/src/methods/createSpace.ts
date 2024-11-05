import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { db } from "@in/server/db"
import { chats, members, spaces } from "@in/server/db/schema"
import {
  encodeChatInfo,
  encodeMemberInfo,
  encodeSpaceInfo,
  TChatInfo,
  TMemberInfo,
  TSpaceInfo,
} from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"

export const Input = Type.Object({
  name: Type.String(),
  handle: Type.Optional(Type.String()),
})

export const Response = Type.Object({
  space: TSpaceInfo,
  member: TMemberInfo,
  chats: Type.Array(TChatInfo),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    // Create the space
    let space = (
      await db
        .insert(spaces)
        .values({
          name: input.name,
          handle: input.handle ?? null,
        })
        .returning()
    )[0]

    if (!space) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    // Create the space membership
    let member = (
      await db
        .insert(members)
        .values({
          spaceId: space.id,
          userId: context.currentUserId,
          role: "owner",
        })
        .returning()
    )[0]

    if (!member) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    // Create the main chat
    let mainChat = (
      await db
        .insert(chats)
        .values({
          spaceId: space.id,
          type: "thread",
          title: "Main",
          publicThread: true,
          description: "Main chat for everyone in the space",
          threadNumber: 1,
        })
        .returning()
    )[0]

    const output = { space, member, chats: [mainChat] }
    return {
      space: encodeSpaceInfo(output.space, { currentUserId: context.currentUserId }),
      member: encodeMemberInfo(output.member),
      chats: output.chats
        .map((c) => c && encodeChatInfo(c, { currentUserId: context.currentUserId }))
        .filter((c) => c !== undefined),
    }
  } catch (error) {
    Log.shared.error("Failed to create space", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
