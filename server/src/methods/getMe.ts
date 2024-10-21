import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { encodeUserInfo, TUserInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"
import { Type, type Static } from "@sinclair/typebox"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({})

export const Response = Type.Object({
  user: TUserInfo,
})

export const handler = async (
  _: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  try {
    let user = await db.select().from(users).where(eq(users.id, currentUserId))

    return { user: encodeUserInfo(user[0]) }
  } catch (error) {
    Log.shared.error("Failed to get me", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR)
  }
}
