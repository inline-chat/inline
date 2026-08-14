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
import { BotAlerts } from "@in/server/modules/bot-events/alerts"
import {
  getPublicHandleAvailability,
  lockPublicHandleNamespace,
} from "@in/server/modules/spaces/spaceHandle"
import { syncTimeZoneForElectedAppleSession } from "@in/server/modules/users/timeZoneSync"

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
    let timeZone: string | undefined
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
      const requestedTimeZone = input.timeZone.trim()
      if (requestedTimeZone && !validateIanaTimezone(requestedTimeZone)) {
        throw new InlineError(InlineError.ApiError.TIMEZONE_INVALID)
      }
      if (requestedTimeZone) {
        timeZone = requestedTimeZone
      }
    }

    if (props.firstName) {
      props.pendingSetup = false
    }

    let { user, completedSignup } = await updateUserAndDetectSignupCompletion(context.currentUserId, props)
    if (!user) {
      log.error("Failed to set profile", { userId: context.currentUserId })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    if (timeZone) {
      const syncedUser = await syncTimeZoneForElectedAppleSession({
        userId: context.currentUserId,
        sessionId: context.currentSessionId,
        timeZone,
      })
      if (syncedUser) {
        user = syncedUser
        log.debug("Set timeZone from elected Apple session")
      }
    }

    if (completedSignup) {
      BotAlerts.signupCompleted({ user })
    }

    return { user: encodeUserInfo(user) }
  } catch (error) {
    if (error instanceof InlineError) {
      throw error
    }
    log.error("Failed to set profile", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

async function updateUserAndDetectSignupCompletion(
  userId: number,
  props: DbNewUser,
): Promise<{ user: DbUser | undefined; completedSignup: boolean }> {
  if (Object.keys(props).length === 0) {
    const [user] = await db.select().from(users).where(eq(users.id, userId)).limit(1)
    return { user, completedSignup: false }
  }

  if (props.pendingSetup !== false && typeof props.username !== "string") {
    const [user] = await db.update(users).set(props).where(eq(users.id, userId)).returning()
    return { user, completedSignup: false }
  }

  return db.transaction(async (tx) => {
    if (typeof props.username === "string") {
      await lockPublicHandleNamespace(tx, props.username)
      const availability = await getPublicHandleAvailability(tx, props.username, { userId })
      if (availability === "taken") {
        throw new InlineError(InlineError.ApiError.USERNAME_TAKEN)
      }
    }

    const [previousUser] = await tx
      .select({ pendingSetup: users.pendingSetup })
      .from(users)
      .where(eq(users.id, userId))
      .for("update")
      .limit(1)

    if (!previousUser) {
      return { user: undefined, completedSignup: false }
    }

    const [user] = await tx.update(users).set(props).where(eq(users.id, userId)).returning()
    return {
      user,
      completedSignup: previousUser.pendingSetup === true && user?.pendingSetup === false,
    }
  })
}

/// HELPER FUNCTIONS ///
