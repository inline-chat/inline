import { db } from "@in/server/db"
import { and, eq, not } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"

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
    const result = await db
      .select()
      .from(users)
      .where(and(eq(users.username, input.username), not(eq(users.id, context.currentUserId))))

    return { available: result.length === 0 }
  } catch (error) {
    Log.shared.error("Failed to check username", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to check username")
  }
}

/// HELPER FUNCTIONS ///
export const checkUsernameAvailable = async (username: string) => {
  const normalizedUsername = username.toLowerCase().trim()
  const result = await db.query.users.findFirst({
    where: eq(users.username, normalizedUsername),
    columns: { username: true },
  })

  return result === undefined
}
