import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users, type DbNewUser, type DbUser } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { TUserInfo, encodeUserInfo } from "@in/server/api-types"
import { checkUsernameAvailable } from "@in/server/methods/checkUsername"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { validateIanaTimezone } from "@in/server/utils/validate"
import { normalizeUsername } from "@in/server/utils/normalize"

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

const log = new Log("updateProfile")

export const handler = async (input: Input, context: HandlerContext): Promise<Static<typeof Response>> => {
  try {
    const username = input.username ? normalizeUsername(input.username) : input.username

    if (username) {
      // check username is available if it's set
      let isAvailable = await checkUsernameAvailable(username, { userId: context.currentUserId })
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
      if (username && username.length < 2) {
        throw new InlineError(InlineError.ApiError.USERNAME_INVALID)
      }
      if (username) {
        props.username = username
      }
    }
    if ("timeZone" in input) {
      if (input.timeZone && !validateIanaTimezone(input.timeZone)) {
        log.error("Invalid timeZone", { timeZone: input.timeZone })
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }
      if (input.timeZone) {
        log.debug("Setting timeZone", { timeZone: input.timeZone })
        props.timeZone = input.timeZone
      }
    }

    let user = await db.update(users).set(props).where(eq(users.id, context.currentUserId)).returning()
    if (!user[0]) {
      log.error("Failed to set profile", { userId: context.currentUserId })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    return { user: encodeUserInfo(user[0]) }
  } catch (error) {
    log.error("Failed to set profile", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

/// HELPER FUNCTIONS ///
