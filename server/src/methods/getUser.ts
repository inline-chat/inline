import { db } from "@in/server/db"
import { and, eq, or } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { encodeUserInfo, TUserInfo } from "../models"

export const Input = Type.Object({
  id: Type.String(),
})

export const Response = Type.Object({
  user: TUserInfo,
})

export const handler = async (input: Static<typeof Input>, _: HandlerContext): Promise<Static<typeof Response>> => {
  try {
    const id = parseInt(input.id)
    if (isNaN(id)) {
      throw new InlineError(ErrorCodes.INVALID_INPUT, "Invalid user ID")
    }
    const result = await db.select().from(users).where(eq(users.id, id))
    return { user: encodeUserInfo(result[0]) }
  } catch (error) {
    Log.shared.error("Failed to get user", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to get user")
  }
}