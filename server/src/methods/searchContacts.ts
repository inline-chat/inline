import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { encodeUserInfo, TUserInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { eq, sql } from "drizzle-orm"
import { Type, type Static } from "@sinclair/typebox"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  q: Type.String(),
  limit: Type.Optional(Type.Integer({ default: 10 })),
})

export const Response = Type.Object({
  users: Type.Array(TUserInfo),
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  try {
    let result = await db
      .select()
      .from(users)
      // case-insensitive version of the SQL LIKE
      .where(sql`${users.username} ilike ${"%" + input.q + "%"}`)
      .limit(input.limit ?? 10)

    return { users: result.map(encodeUserInfo) }
  } catch (error) {
    Log.shared.error("Failed to get me", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR)
  }
}
