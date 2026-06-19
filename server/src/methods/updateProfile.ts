import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users, type DbNewUser } from "@in/server/db/schema"
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
  bio: Type.Optional(Type.String()),
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
    let props: DbNewUser = {}
    if (input.firstName !== undefined) {
      const firstName = input.firstName.trim()
      if (!firstName) {
        throw new InlineError(InlineError.ApiError.FIRST_NAME_INVALID)
      }
      props.firstName = firstName
    }
    if (input.lastName !== undefined) {
      const lastName = input.lastName.trim()
      props.lastName = lastName || null
    }
    if (input.bio !== undefined) {
      const bio = input.bio.trim()
      props.bio = bio || null
    }
    if (input.username !== undefined) {
      const username = normalizeUsername(input.username)
      if (username) {
        if (username.length < 2) {
          throw new InlineError(InlineError.ApiError.USERNAME_INVALID)
        }

        // check username is available if it's set
        let isAvailable = await checkUsernameAvailable(username, { userId: context.currentUserId })
        if (!isAvailable) {
          throw new InlineError(InlineError.ApiError.USERNAME_TAKEN)
        }
        props.username = username
      }
    }
    if (input.timeZone !== undefined) {
      const timeZone = input.timeZone.trim()
      if (timeZone && !validateIanaTimezone(timeZone)) {
        throw new InlineError(InlineError.ApiError.TIMEZONE_INVALID)
      }
      if (timeZone) {
        log.debug("Setting timeZone", { timeZone })
        props.timeZone = timeZone
      }
    }

    let user = await db.update(users).set(props).where(eq(users.id, context.currentUserId)).returning()
    if (!user[0]) {
      log.error("Failed to set profile", { userId: context.currentUserId })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    return { user: encodeUserInfo(user[0]) }
  } catch (error) {
    if (error instanceof InlineError) {
      throw error
    }
    log.error("Failed to set profile", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

/// HELPER FUNCTIONS ///
