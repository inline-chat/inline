import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users, type DbNewUser, type DbUser } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { TUserInfo, encodeUserInfo } from "@in/server/models"
import { checkUsernameAvailable } from "@in/server/methods/checkUsername"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"

export const Input = Type.Object({
  firstName: Type.Optional(Type.String()),
  lastName: Type.Optional(Type.String()),
  username: Type.Optional(Type.String()),
})

type Input = Static<typeof Input>

export const Response = Type.Object({
  user: TUserInfo,
})

export const handler = async (input: Input, context: HandlerContext): Promise<Static<typeof Response>> => {
  try {
    if (input.username) {
      // check username is available if it's set
      let isAvailable = await checkUsernameAvailable(input.username)
      if (!isAvailable) {
        throw new InlineError(ErrorCodes.INAVLID_ARGS, "Username is already taken")
      }
    }

    let props: DbNewUser = {}
    if ("firstName" in input) props.firstName = input.firstName ?? null
    if ("lastName" in input) props.lastName = input.lastName ?? null
    if ("username" in input) props.username = input.username ?? null

    let user = await db.update(users).set(props).where(eq(users.id, context.currentUserId)).returning()

    return { user: encodeUserInfo(user[0]) }
  } catch (error) {
    Log.shared.error("Failed to set profile", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to set profile")
  }
}

/// HELPER FUNCTIONS ///
