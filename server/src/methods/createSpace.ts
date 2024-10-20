import { db } from "@in/server/db"
import {
  chats,
  DbChat,
  DbMember,
  DbSpace,
  members,
  spaces,
} from "@in/server/db/schema"
import {
  encodeChatInfo,
  encodeMemberInfo,
  encodeSpaceInfo,
} from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

type Input = {
  name: string
  handle?: string
}

type Context = {
  currentUserId: number
}

type Output = {
  space: DbSpace
  member: DbMember
  chats: DbChat[]
}

export const createSpace = async (
  input: Input,
  context: Context,
): Promise<Output> => {
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

    // Create the main chat
    let mainChat = (
      await db
        .insert(chats)
        .values({
          spaceId: space.id,
          type: "thread",
          title: "Main",
          spacePublic: true,
          description: "Main chat for everyone in the space",
          threadNumber: 1,
        })
        .returning()
    )[0]

    return { space, member, chats: [mainChat] }
  } catch (error) {
    Log.shared.error("Failed to create space", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to create space")
  }
}

export const encodeCreateSpace = (output: Output) => {
  return {
    space: encodeSpaceInfo(output.space),
    member: encodeMemberInfo(output.member),
    chats: output.chats.map(encodeChatInfo),
  }
}
