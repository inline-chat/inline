import { db } from "@in/server/db"
import { DbUser, spaces, users } from "@in/server/db/schema"
import { encodeUserInfo, TUserInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"

type Input = {}

type Context = {
  currentUserId: number
}

type Output = {
  user: DbUser
}

export const getMe = async (
  _: Input,
  { currentUserId }: Context,
): Promise<Output> => {
  try {
    let user = await db.select().from(users).where(eq(users.id, currentUserId))

    return { user: user[0] }
  } catch (error) {
    Log.shared.error("Failed to get me", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR)
  }
}

export const encodeGetMe = ({ user }: Output): { user: TUserInfo } => {
  console.log("user", user)
  return { user: encodeUserInfo(user) }
}
