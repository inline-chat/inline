import { InlineError } from "@in/server/types/errors"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { encodeMinUserInfo, TMinUserInfo } from "../api-types"
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

  return { user: encodeMinUserInfo(user) }
}
