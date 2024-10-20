import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import {
  members,
  users,
  type DbMember,
  type DbSpace,
} from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeMemberInfo,
  encodeSpaceInfo,
  TMemberInfo,
  TSpaceInfo,
} from "@in/server/models"

export const Input = Type.Object({
  username: Type.String(),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

type RawOutput = {
  available: boolean
}

export const Response = Type.Object({
  available: Type.Boolean(),
})

export const encode = (output: RawOutput): Static<typeof Response> => {
  return {
    available: output.available,
  }
}

export const handler = async (
  input: Input,
  context: Context,
): Promise<RawOutput> => {
  try {
    const result = await db
      .select()
      .from(users)
      .where(eq(users.username, input.username))

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
