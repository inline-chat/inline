import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users, type DbNewUser, type DbUser } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { TUserInfo, encodeUserInfo } from "@in/server/api-types"
import { checkUsernameAvailable } from "@in/server/methods/checkUsername"
import type { HandlerContext } from "@in/server/controllers/helpers"

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
      let isAvailable = await checkUsernameAvailable(input.username, { userId: context.currentUserId })
      if (!isAvailable) {
        throw new InlineError(InlineError.ApiError.USERNAME_TAKEN)
      }
    }

    let props: DbNewUser = {}
    if ("firstName" in input) {
      if (input.firstName.length < 1) {
        throw new InlineError(InlineError.ApiError.FIRST_NAME_INVALID)
      }
      props.firstName = input.firstName ?? null
    }
    if ("lastName" in input) props.lastName = input.lastName ?? null
    if ("username" in input) {
      if (input.username.length < 2) {
        throw new InlineError(InlineError.ApiError.USERNAME_INVALID)
      }
      props.username = input.username ?? null
    }

    let user = await db.update(users).set(props).where(eq(users.id, context.currentUserId)).returning()
    if (!user[0]) {
      Log.shared.error("Failed to set profile", { userId: context.currentUserId })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    return { user: encodeUserInfo(user[0]) }
  } catch (error) {
    Log.shared.error("Failed to set profile", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

/// HELPER FUNCTIONS ///
