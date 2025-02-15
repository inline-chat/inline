import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { encodeFullUserInfo, encodeUserInfo, TUserInfo } from "@in/server/api-types"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"
import { Type, type Static } from "@sinclair/typebox"
import { UsersModel } from "@in/server/db/models/users"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({})

export const Response = Type.Object({
  user: TUserInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const user = await UsersModel.getUserWithPhoto(currentUserId)

  return {
    user: encodeFullUserInfo(user),
  }
}
