import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import {
  members,
  spaces,
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

export const Input = Type.Object({})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

type RawOutput = {
  spaces: DbSpace[]
  members: DbMember[]
}

export const Response = Type.Object({
  spaces: Type.Array(TSpaceInfo),
  members: Type.Array(TMemberInfo),
})

export const encode = (output: RawOutput): Static<typeof Response> => {
  return {
    spaces: output.spaces.map(encodeSpaceInfo),
    members: output.members.map(encodeMemberInfo),
  }
}

export const handler = async (
  input: Input,
  context: Context,
): Promise<RawOutput> => {
  try {
    const result = await db
      .select()
      .from(members)
      .where(eq(members.userId, context.currentUserId))
      .innerJoin(spaces, eq(members.spaceId, spaces.id))

    return {
      spaces: result.map((r) => r.spaces),
      members: result.map((r) => r.members),
    }
  } catch (error) {
    Log.shared.error("Failed to send email code", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to send email code")
  }
}

/// HELPER FUNCTIONS ///
