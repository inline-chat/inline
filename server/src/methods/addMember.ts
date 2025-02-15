import type { HandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import { encodeMemberInfo, TMemberInfo } from "../api-types"
import { InlineError } from "../types/errors"
import { TInputId } from "../types/methods"
import { members, spaces } from "../db/schema"
import { eq } from "drizzle-orm"

export const Input = Type.Object({
  spaceId: TInputId,
  userId: TInputId,
})

export const Response = Type.Object({
  member: TMemberInfo,
})

export const handler = async (input: Static<typeof Input>, _: HandlerContext): Promise<Static<typeof Response>> => {
  try {
    const spaceId = Number(input.spaceId)
    if (isNaN(spaceId)) {
      console.log("spaceId is not a number")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    const userId = Number(input.userId)
    if (isNaN(userId)) {
      console.log("userId is not a number")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    const [member] = await db
      .insert(members)
      .values({
        spaceId: spaceId,
        userId: userId,
        role: "member",
        date: new Date(),
      })
      .returning()

    if (!member) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    return {
      member: encodeMemberInfo(member),
    }
  } catch (error) {
    Log.shared.error("Failed to add member", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
