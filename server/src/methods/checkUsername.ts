import { db } from "@in/server/db"
import { and, eq, not } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"

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
  const normalizedUsername = username.toLowerCase().trim()
  const result = await db._query.users.findFirst({
    where: and(
      eq(users.username, normalizedUsername),
      // If the user ID is provided, we don't want to check against the current user
      not(eq(users.id, context.userId ?? 0)),
    ),
    columns: { username: true },
  })

  return result === undefined
}
