import { db } from "@in/server/db"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { normalizeUsername } from "@in/server/utils/normalize"
import { getPublicHandleAvailability } from "@in/server/modules/spaces/spaceHandle"

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
  const availability = await getPublicHandleAvailability(db, normalizedUsername, { userId: context.userId })
  return availability === "current" || availability === "available"
}
