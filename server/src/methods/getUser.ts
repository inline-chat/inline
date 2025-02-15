import { db } from "@in/server/db"
import { and, eq, or } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { encodeFullUserInfo, encodeMinUserInfo, encodeUserInfo, TMinUserInfo, TUserInfo } from "../api-types"
import { TInputId } from "@in/server/types/methods"
import { UsersModel } from "@in/server/db/models/users"

export const Input = Type.Object({
  id: TInputId,
})

export const Response = Type.Object({
  user: TMinUserInfo,
})

export const handler = async (input: Static<typeof Input>, _: HandlerContext): Promise<Static<typeof Response>> => {
  const id = Number(input.id)
  if (isNaN(id)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const user = await UsersModel.getUserWithPhoto(id)

  return { user: encodeFullUserInfo(user) }
}
