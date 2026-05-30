import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { lower, users } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { isReservedUsername } from "@in/server/modules/users/reservedUsernames"
import { normalizeUsername } from "@in/server/utils/normalize"

export const Input = Type.Object({
  username: Type.String(),
})

export const Response = Type.Object({
  available: Type.Boolean(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    const available = await checkUsernameAvailable(input.username, { userId: context.currentUserId })
    return { available }
  } catch (error) {
    Log.shared.error("Failed to check username", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

/// HELPER FUNCTIONS ///
export const checkUsernameAvailable = async (username: string, context: { userId?: number }) => {
  const normalizedUsername = normalizeUsername(username).toLowerCase()
  const result = await db._query.users.findFirst({
    where: eq(lower(users.username), normalizedUsername),
    columns: { id: true },
  })

  if (result) {
    return result.id === context.userId
  }

  return !isReservedUsername(normalizedUsername)
}
