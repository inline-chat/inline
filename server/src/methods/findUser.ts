import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { encodeUserInfo, TUserInfo } from "../models"

export const Input = Type.Object({
  username: Type.String(),
})

export const Response = Type.Object({
  users: Type.Array(TUserInfo),
})

export const handler = async (input: Static<typeof Input>, _: HandlerContext): Promise<Static<typeof Response>> => {
  try {
    const result = await db.select().from(users).where(eq(users.username, input.username))
    return { users: result.map(encodeUserInfo) }
  } catch (error) {
    Log.shared.error("Failed to find user", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to find user")
  }
}
