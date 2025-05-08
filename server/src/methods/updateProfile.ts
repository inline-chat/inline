import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users, type DbNewUser, type DbUser } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { TUserInfo, encodeUserInfo } from "@in/server/api-types"
import { checkUsernameAvailable } from "@in/server/methods/checkUsername"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { validateIanaTimezone } from "@in/server/utils/validate"

export const Input = Type.Object({
  firstName: Type.Optional(Type.String()),
  lastName: Type.Optional(Type.String()),
  username: Type.Optional(Type.String()),
  timeZone: Type.Optional(Type.String()),
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
      if (input.firstName && input.firstName.length < 1) {
        throw new InlineError(InlineError.ApiError.FIRST_NAME_INVALID)
      }
      if (input.firstName) {
        props.firstName = input.firstName
      }
    }
    if ("lastName" in input) {
      if (input.lastName) {
        props.lastName = input.lastName
      }
    }
    if ("username" in input) {
      if (input.username && input.username.length < 2) {
        throw new InlineError(InlineError.ApiError.USERNAME_INVALID)
      }
      if (input.username) {
        props.username = input.username
      }
    }
    if ("timeZone" in input) {
      if (input.timeZone && !validateIanaTimezone(input.timeZone)) {
        Log.shared.error("Invalid timeZone", { timeZone: input.timeZone })
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }
      if (input.timeZone) {
        Log.shared.info("Setting timeZone", { timeZone: input.timeZone })
        props.timeZone = input.timeZone
      }
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
